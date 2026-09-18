import Foundation
import DiskCore
import CoreHaptics
import QuartzCore

/// Retour haptique piloté par les mêmes repères que l'audio.
///
/// Le Taptic Engine n'est pas un caisson de basses : ce qui passe bien, ce sont
/// les **transitoires**. On reprend donc le découpage mécanique du seek —
/// attaque à la mise en mouvement, grondement pendant le coast, choc à la
/// décélération, tic d'asservissement en fin de course — plutôt que d'envoyer
/// une bouillie continue.
///
/// Les distances courtes donnent un tic sec et léger, les longues courses un
/// choc plus sourd et plus fort : c'est la même loi d'excitation que pour le
/// son, la netteté remplaçant la balance des modes.
@MainActor
final class DiskHaptics {

    private var engine: CHHapticEngine?
    private var players: [CHHapticPatternPlayer] = []
    private var spindlePlayer: CHHapticAdvancedPatternPlayer?
    private var running = false

    /// Intensité générale, appliquée à tous les événements.
    var intensity: Float = 0.85
    /// Grondement continu de rotation. Discret par construction : il masquerait
    /// les transitoires s'il était au même niveau.
    var spindleEnabled = true
    var spindleIntensity: Float = 0.45

    let isSupported: Bool = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    // Diagnostic. Un motif haptique qui échoue est invisible et inaudible :
    // sans ces compteurs, une erreur de construction de motif se confond avec
    // un réglage trop faible.
    private(set) var patternsPlayed = 0
    private(set) var patternsFailed = 0
    private(set) var transientsPlayed = 0
    private(set) var lastFailure: String?

    // MARK: - Cycle de vie

    func prepare() {
        guard isSupported, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            // Sans cela le moteur s'éteint entre deux repères espacés et le
            // premier événement suivant arrive en retard.
            engine.isAutoShutdownEnabled = false

            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.running else { return }
                    try? self.engine?.start()
                    self.restartSpindleIfNeeded()
                }
            }
            engine.stoppedHandler = { _ in }

            self.engine = engine
        } catch {
            print("Core Haptics indisponible : \(error)")
        }
    }

    func start() {
        guard isSupported else { return }
        prepare()
        do {
            try engine?.start()
            running = true
        } catch {
            print("Démarrage du moteur haptique impossible : \(error)")
        }
    }

    func stop() {
        running = false
        try? spindlePlayer?.cancel()
        spindlePlayer = nil
        players.forEach { try? $0.cancel() }
        players.removeAll()
        engine?.stop(completionHandler: nil)
    }

    /// Annule ce qui est programmé sans arrêter le moteur — pour un saut dans
    /// la chronologie.
    func flush() {
        players.forEach { try? $0.cancel() }
        players.removeAll()
    }

    // MARK: - Programmation

    /// Déclenche un repère **maintenant**.
    ///
    /// Volontairement pas de programmation à l'avance sur `engine.currentTime` :
    /// cette horloge n'est fiable que tant que le moteur rend quelque chose, et
    /// un motif programmé pour dans 700 ms peut arriver en retard ou se perdre
    /// si le moteur s'est assoupi entre-temps. L'ordonnancement est fait côté
    /// appelant, à la cadence de sa boucle.
    func fire(_ cue: AudioCue) {
        guard isSupported, running else { return }

        let events: [CHHapticEvent]

        switch cue.kind {
        case .seek(let profile, let travelMix):
            events = seekEvents(profile: profile, travelMix: travelMix, at: 0)

        case .chatter(let run, let duration):
            events = chatterPattern(run: run, duration: duration)

        case .tick(let kind):
            let strength: Float = kind == .headSwitch ? 0.10 : 0.20
            events = [transient(at: 0, intensity: strength, sharpness: 0.95)]

        case .tickTrain(let ticks, let duration):
            // Une cadence de 120 Hz ne se sent pas tic par tic : c'est un
            // frémissement continu, piqué des seuls pas de piste.
            events = [continuous(at: 0, duration: duration, intensity: 0.08, sharpness: 0.9)]
                + ticks.filter { $0.kind == .trackStep }.prefix(24).map {
                    transient(at: $0.offset, intensity: 0.16, sharpness: 0.95)
                }

        case .unstick:
            events = [transient(at: 0, intensity: 0.7, sharpness: 0.6)]

        case .landing:
            events = [transient(at: 0, intensity: 0.35, sharpness: 0.5),
                      continuous(at: 0.01, duration: 0.10, intensity: 0.12, sharpness: 0.3)]

        case .spinUp, .spinDown:
            return
        }

        guard !events.isEmpty else { return }
        play(events: events)
    }

    private func play(events: [CHHapticEvent]) {
        guard let engine else { return }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            players.append(player)
            patternsPlayed += 1
            transientsPlayed += events.filter { $0.type == .hapticTransient }.count
            // Les lecteurs terminés ne se libèrent pas tout seuls : on borne.
            if players.count > 48 { players.removeFirst(players.count - 48) }
        } catch {
            patternsFailed += 1
            lastFailure = String(describing: error)
        }
    }

    func resetDiagnostics() {
        patternsPlayed = 0
        patternsFailed = 0
        transientsPlayed = 0
        lastFailure = nil
    }

    // MARK: - Motifs

    private func transient(at time: TimeInterval, intensity value: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: min(max(value * intensity, 0), 1)),
                CHHapticEventParameter(parameterID: .hapticSharpness,
                                       value: min(max(sharpness, 0), 1)),
            ],
            relativeTime: time
        )
    }

    private func continuous(at time: TimeInterval, duration: TimeInterval,
                           intensity value: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: min(max(value * intensity, 0), 1)),
                CHHapticEventParameter(parameterID: .hapticSharpness,
                                       value: min(max(sharpness, 0), 1)),
            ],
            relativeTime: time,
            duration: max(duration, 0.02)
        )
    }

    /// Loi d'excitation en fonction de la distance parcourue.
    ///
    /// **Compressive, comme celle de l'audio** (`0,32 + 0,68·d^0,35`). Une loi
    /// linéaire en distance est un piège : les phases les plus denses sont
    /// justement celles qui n'enchaînent que des courses courtes — chargement de
    /// pilotes, DLL groupées — donc `d` y vaut quelques centièmes. En linéaire
    /// tout s'y écrase au plancher et la sensation disparaît au moment précis où
    /// il se passe le plus de choses, pendant qu'un seek pleine course isolé
    /// cogne beaucoup trop fort.
    private func excitation(_ travelMix: Double, floor: Float, span: Float) -> Float {
        floor + span * pow(Float(min(max(travelMix, 0), 1)), 0.4)
    }

    /// Un seek isolé, calqué sur ses quatre phases mécaniques.
    private func seekEvents(profile: SeekProfile, travelMix: Double, at offset: TimeInterval) -> [CHHapticEvent] {
        let mix = Float(min(max(travelMix, 0), 1))
        var events: [CHHapticEvent] = []

        // Mise en mouvement : plus la course est longue, plus le choc est fort
        // et sourd. Une course d'une piste ne fait qu'un petit tic sec.
        events.append(transient(at: offset,
                                intensity: excitation(travelMix, floor: 0.30, span: 0.40),
                                sharpness: 0.92 - 0.42 * mix))

        // Coast : le bras file, courant quasi nul. Un grondement de fond, qui
        // n'existe que sur les seeks assez longs pour avoir un palier.
        if profile.hasCoast && profile.coast > 0.004 {
            events.append(continuous(at: offset + profile.speedup,
                                     duration: profile.coast,
                                     intensity: 0.06 + 0.16 * mix,
                                     sharpness: 0.12))
        }

        // Décélération : légèrement plus franche que l'accélération.
        events.append(transient(at: offset + profile.speedup + profile.coast,
                                intensity: excitation(travelMix, floor: 0.32, span: 0.42),
                                sharpness: 0.88 - 0.38 * mix))

        // Asservissement final : le petit tic de fin de course, toujours sec.
        events.append(transient(at: offset + profile.total - profile.settle,
                                intensity: excitation(travelMix, floor: 0.18, span: 0.20),
                                sharpness: 0.96))

        return events
    }

    /// Un train de seeks rapprochés.
    ///
    /// Reproduire chaque phase de chaque seek donnerait plusieurs centaines
    /// d'événements par seconde, que le moteur écrête et que la main perçoit
    /// comme une bouillie. On garde donc une texture continue modulée par la
    /// densité du train, plus quelques transitoires espacés pour le grain.
    private func chatterPattern(run: [ChatterSeek], duration: TimeInterval) -> [CHHapticEvent] {
        guard let last = run.last else { return [] }
        let span = max(last.offset + last.profile.total, duration)
        var events: [CHHapticEvent] = []

        let averageMix = Float(run.map(\.travelMix).reduce(0, +) / Double(run.count))

        // Densité du train, en seeks par seconde.
        let density = Double(run.count) / max(span, 0.001)

        // Le lit continu s'efface à mesure que la densité monte. C'est lui qui,
        // à 150 seeks par seconde, transformait le crépitement en ronflement
        // qu'on ne distinguait plus du grondement de rotation. Sur un train
        // clairsemé il garde du corps ; sur un train dense ce sont les chocs qui
        // portent la sensation. Netteté plus haute que celle de la rotation,
        // pour que les deux couches ne se confondent pas même à niveau égal.
        // Au-delà de ~25 seeks/s il n'y a plus de lit du tout. Les trains denses
        // s'enchaînant bord à bord, le garder revenait à faire tourner un
        // événement continu en permanence : le système finit par écrêter la
        // sortie haptique et tout s'éteint progressivement. Les transitoires,
        // impulsionnels, n'ont pas ce problème.
        let bedScale = Float(max(0, 1 - density / 25))
        if bedScale > 0.02 {
            events.append(continuous(at: 0, duration: span,
                                     intensity: (0.16 + 0.20 * averageMix) * bedScale,
                                     sharpness: 0.58))
        }

        // Aucune courbe de paramètre sur ce motif. `hapticIntensityControl` en
        // courbe s'applique à **tous** les événements du motif, transitoires
        // compris : l'enveloppe censée moduler le lit atténuait en réalité les
        // chocs, d'autant plus fort que le train était dense. C'est ce qui vidait
        // les phases chargées de toute sensation.

        // Grain : on ne rend surtout pas tous les seeks. Au-delà d'une quinzaine
        // de chocs par seconde la main ne les sépare plus, ils fusionnent en
        // vibration.
        //
        // Mais le *choix* compte autant que le nombre. Prendre les plus longues
        // courses puis imposer un espacement minimal produit, sur un train
        // dense, un peigne parfaitement régulier : à 150 seeks par seconde il y a
        // toujours un candidat pile à la limite d'espacement, et la sélection se
        // cale sur la grille au lieu de suivre la charge. Cela se sent comme un
        // métronome, pas comme un crépitement.
        //
        // On procède donc par éclaircissement aléatoire — un amincissement de
        // Poisson — pondéré par la longueur de la course : chaque seek a une
        // chance d'être retenu, d'autant plus grande que sa course est longue.
        // Les intervalles obtenus sont irréguliers par construction, ce qui est
        // précisément ce qui fait un crépitement. Le tirage est déterministe :
        // un même train donne toujours le même motif, indispensable pour
        // comparer deux réglages.
        let targetRate = 11.0
        let refractory = 0.042
        let maximumTransients = 16

        var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: run.count &* 2_654_435_761)
                                  ^ UInt64(truncatingIfNeeded: Int(span * 100_000)))
        let baseProbability = min(targetRate * span / Double(run.count), 1)

        var chosen: [ChatterSeek] = []
        var lastOffset = -Double.infinity
        for seek in run {
            guard chosen.count < maximumTransients else { break }
            guard seek.offset - lastOffset >= refractory else { continue }
            // Pondération : une course deux fois plus longue a nettement plus de
            // chances d'être retenue, sans pour autant écraser les courtes.
            let weight = 0.55 + 0.90 * pow(seek.travelMix, 0.4)
            guard rng.chance(min(baseProbability * weight, 1)) else { continue }
            lastOffset = seek.offset
            chosen.append(seek)
        }

        for seek in chosen {
            events.append(transient(at: seek.offset,
                                    intensity: excitation(seek.travelMix, floor: 0.36, span: 0.34),
                                    sharpness: 0.82))
        }

        return events
    }
    // MARK: - Rotation

    /// Grondement de plateau : une boucle continue dont on module l'intensité
    /// avec la vitesse de rotation.
    ///
    /// Deux pièges ici. D'une part `hapticIntensityControl` est un **facteur**
    /// appliqué à l'intensité de l'événement, pas une valeur absolue : partir
    /// d'un événement faible puis le multiplier par un contrôle faible donne un
    /// résultat sous le seuil de perception. L'événement est donc à pleine
    /// intensité et c'est le contrôle qui porte le réglage. D'autre part une
    /// vibration continue parfaitement constante s'efface en une seconde ou deux
    /// — d'où le flottement lent, qui reprend celui de la couche audio.
    func setSpindle(speed: Double) {
        guard isSupported, running else { return }

        let value = Float(min(max(speed, 0), 1))

        // Rien à jouer : on arrête le lecteur plutôt que de le laisser tourner à
        // niveau nul. Un événement continu qui tourne en permanence, même
        // inaudible, entre dans le budget de sortie haptique du système et
        // contribue à l'atténuation progressive de tout le reste.
        guard spindleEnabled, value > 0.05 else {
            try? spindlePlayer?.cancel()
            spindlePlayer = nil
            return
        }

        if spindlePlayer == nil { startSpindleLoop() }

        // L'intensité croît un peu plus vite que la vitesse, comme l'enveloppe
        // audio : à mi-régime le plateau ne gronde pas encore vraiment.
        // Flottement lent : une vibration continue parfaitement constante
        // s'efface en une seconde ou deux. Appliqué ici plutôt que par une
        // courbe de motif, pour garder une seule source de vérité sur
        // l'intensité — sans quoi le réglage n'a aucun effet.
        let clock = CACurrentMediaTime()
        let wobble = 0.82 + 0.18 * sin(2 * .pi * 1.3 * clock)
        let level = pow(value, 1.3) * spindleIntensity * intensity * Float(wobble)
        let parameter = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: min(max(level, 0), 1),
            relativeTime: 0
        )
        try? spindlePlayer?.sendParameters([parameter], atTime: CHHapticTimeImmediate)
    }

    /// Durée de la boucle. Courte pour que la courbe de flottement ait une
    /// résolution utile : une courbe est limitée à une poignée de points.
    private let spindleLoopDuration: TimeInterval = 2.0

    private func startSpindleLoop() {
        guard let engine else { return }
        do {
            // Événement à pleine intensité : le niveau réel est imposé ensuite
            // par `hapticIntensityControl`. Une netteté trop basse produit un
            // souffle diffus qu'on ne sent pas ; 0,3 donne un vrai grondement.
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.30),
                ],
                relativeTime: 0,
                duration: spindleLoopDuration
            )

            // Pas de courbe de paramètre ici : une courbe et un paramètre
            // dynamique visant tous deux `hapticIntensityControl` entrent en
            // conflit, et la courbe — rejouée à chaque tour de boucle — écrase
            // la valeur envoyée. Le flottement est donc appliqué directement
            // dans le niveau calculé à chaque tick.
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            player.loopEnd = spindleLoopDuration
            try player.start(atTime: CHHapticTimeImmediate)
            spindlePlayer = player
        } catch {
            print("Boucle haptique de rotation impossible : \(error)")
        }
    }

    private func restartSpindleIfNeeded() {
        guard spindlePlayer != nil else { return }
        spindlePlayer = nil
        startSpindleLoop()
    }
}
