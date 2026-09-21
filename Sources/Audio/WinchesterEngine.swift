import Foundation
import DiskCore
import AVFoundation
import QuartzCore
import Combine

/// Graphe audio du spike.
///
/// Il ne connaît pas la passe qu'il joue : il lui demande, soixante fois par
/// seconde, les repères des prochaines 700 ms, et elle les calcule à mesure.
///
///     SpindleVoice (AVAudioSourceNode, procédural) ──┐
///                                                    ├─► mainMixer ─► sortie
///     transitoires (AVAudioPlayerNode, buffers) ─────┘
///
/// La couche continue est rendue en temps réel ; les transitoires sont
/// pré-rendus en `AVAudioPCMBuffer` et programmés à une date absolue sur
/// l'horloge du player, ce qui donne une précision à l'échantillon sans avoir
/// à écrire un mélangeur maison dans le callback de rendu.
@MainActor
final class WinchesterEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isLoaded = false
    /// La lecture attend que la passe ait pris assez d'avance.
    @Published private(set) var isBuffering = false
    /// La passe est allée au bout : il n'y a plus qu'à la relancer.
    @Published private(set) var isFinished = false
    /// L'allure de l'écoute. Une passe neuve repart toujours à ×1.
    @Published private(set) var speed: PlaybackSpeed = .normal

    /// Ce qui a mis la lecture en pause sans qu'on le demande. Effacé à la
    /// reprise, et quand une autre passe est chargée.
    @Published private(set) var interruption: PlaybackInterruption?

    @Published var spindleLevel: Float = 0.20 { didSet { spindleMixer.outputVolume = spindleLevel } }
    @Published var transientLevel: Float = 1.0 { didSet { transientMixer.outputVolume = transientLevel } }
    @Published var masterLevel: Float = 0.85 { didSet { engine.mainMixerNode.outputVolume = masterLevel } }

    /// Retour haptique. Le Taptic Engine reçoit les mêmes repères que l'audio,
    /// d'où une synchronisation naturelle entre ce qu'on entend et ce qu'on sent.
    @Published var hapticsEnabled: Bool = true {
        didSet {
            guard hapticsEnabled != oldValue else { return }
            if hapticsEnabled, isPlaying { haptics.start() } else { haptics.stop() }
        }
    }
    @Published var hapticIntensity: Float = 0.85 { didSet { haptics.intensity = hapticIntensity } }
    /// Niveau du grondement de rotation, séparé de l'intensité des transitoires.
    @Published var spindleHapticLevel: Float = 0.45 {
        didSet { haptics.spindleIntensity = spindleHapticLevel }
    }
    @Published var spindleHaptics: Bool = true {
        didSet {
            haptics.spindleEnabled = spindleHaptics
        }
    }

    let haptics = DiskHaptics()
    var supportsHaptics: Bool { haptics.isSupported }

    /// Tous les réglages de « Son et vibrations » d'un bloc : c'est ce qu'on
    /// compare aux préréglages et ce qu'on enregistre.
    var mix: SoundMix {
        get {
            SoundMix(spindleLevel: spindleLevel, transientLevel: transientLevel, masterLevel: masterLevel,
                     hapticsEnabled: hapticsEnabled, hapticIntensity: hapticIntensity,
                     spindleHaptics: spindleHaptics, spindleHapticLevel: spindleHapticLevel)
        }
        set {
            spindleLevel = newValue.spindleLevel
            transientLevel = newValue.transientLevel
            masterLevel = newValue.masterLevel
            hapticsEnabled = newValue.hapticsEnabled
            hapticIntensity = newValue.hapticIntensity
            spindleHaptics = newValue.spindleHaptics
            spindleHapticLevel = newValue.spindleHapticLevel
        }
    }

    /// Diagnostic haptique, rafraîchi à chaque tick.
    @Published private(set) var hapticReport: String = "—"

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let spindleMixer = AVAudioMixerNode()
    private let transientMixer = AVAudioMixerNode()

    private let sampleRate: Double = 48_000
    private var format: AVAudioFormat!
    private var synth: SeekSynth!
    private var spindle: SpindleVoice!
    private var sourceNode: AVAudioSourceNode!

    /// La passe qu'on écoute. Faible : c'est le modèle qui la tient, et une
    /// passe abandonnée doit pouvoir partir sans attendre le moteur.
    private weak var feed: PassFeed?
    private var spinCues: [(time: Double, up: Bool, duration: Double)] = []
    private var hapticCues: [AudioCue] = []
    /// Transitoires déjà retirés de la passe et confiés au player, pas encore
    /// joués. Une pause les efface du player ; ils sont reprogrammés à la
    /// reprise, puisque la passe ne les rendra pas une seconde fois.
    private var scheduled: [AudioCue] = []

    /// Temps de passe correspondant à l'instant 0 de l'horloge du player, et
    /// allure à laquelle il s'écoule.
    private var clock = PlaybackClock()
    private var hostStart: Double = 0
    private var generation = 0

    private var pump: Timer?
    private var waiting: Timer?
    /// Le fondu de la minuterie d'arrêt, s'il est en cours.
    private var fade: Timer?
    private var seekCache: [Int: AVAudioPCMBuffer] = [:]
    private var tickCache: [Int: AVAudioPCMBuffer] = [:]

    /// Avance de programmation des transitoires, en secondes **réelles** — comme
    /// toutes les marges de ce fichier : `clock.passSpan` les porte en temps de
    /// passe.
    private let lookahead = 0.70
    private var observers: [NSObjectProtocol] = []

    // MARK: - Cycle de vie

    init(character: SpindleCharacter) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        synth = SeekSynth(sampleRate: sampleRate)
        spindle = SpindleVoice(sampleRate: sampleRate, character: character)
        sourceNode = spindle.makeSourceNode(format: format)

        engine.attach(sourceNode)
        engine.attach(player)
        engine.attach(spindleMixer)
        engine.attach(transientMixer)

        engine.connect(sourceNode, to: spindleMixer, format: format)
        engine.connect(player, to: transientMixer, format: format)
        engine.connect(spindleMixer, to: engine.mainMixerNode, format: format)
        engine.connect(transientMixer, to: engine.mainMixerNode, format: format)

        spindleMixer.outputVolume = spindleLevel
        transientMixer.outputVolume = transientLevel
        engine.mainMixerNode.outputVolume = masterLevel
        engine.prepare()

        haptics.intensity = hapticIntensity
        haptics.spindleEnabled = spindleHaptics
        haptics.spindleIntensity = spindleHapticLevel
        haptics.prepare()

        observeInterruptions()
    }

    // MARK: - Interruptions

    /// Un appel, une autre app qui prend la sortie, un casque débranché : le
    /// système arrête le graphe audio sans rien demander. Sans suivi, `isPlaying`
    /// restait vrai et l'horloge, faute de rendu, retombait sur l'heure de
    /// l'hôte : le temps écouté avançait en silence.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.interrupt(.otherAudio)
                case .ended: self?.endInterruption(shouldResume: options.contains(.shouldResume))
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Un casque qu'on retire met la lecture en pause, comme partout
            // ailleurs sur iOS : sinon la passe part dans le haut-parleur.
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.interrupt(.outputRemoved) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt(.outputChanged) }
        })
    }

    private func interrupt(_ reason: PlaybackInterruption.Reason) {
        guard isPlaying || isBuffering else { return }
        pause()
        interruption = PlaybackInterruption(reason: reason, time: currentTime)
    }

    /// L'autre app a rendu la main. On reprend si le système le propose — la fin
    /// d'un appel —, sinon la passe reste en pause et l'écran le dit.
    private func endInterruption(shouldResume: Bool) {
        guard interruption?.reason == .otherAudio, shouldResume else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        play()
    }

    static func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` pour que le son sorte même interrupteur silencieux activé :
            // une démo muette n'a aucun intérêt.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Session audio indisponible : \(error)")
        }
    }

    /// Branche une passe. `character` suit le disque simulé — régime, plateaux,
    /// palier : la couche de rotation est la seule à en dépendre, et elle se
    /// reconfigure sans qu'on ait à reconstruire le graphe.
    ///
    /// La passe repart toujours de son début : il n'y a plus de chronologie
    /// où sauter, seulement une passe qui se calcule à mesure qu'on l'écoute.
    func load(feed: PassFeed, character: SpindleCharacter,
              seek: SeekCharacter = SeekCharacter(seekBels: SeekCharacter.referenceBels)) {
        stop()
        interruption = nil
        spindle.character = character
        // La voix de la tête est immuable : un autre niveau, c'est un autre
        // synthétiseur, et des caches à refaire.
        if synth.headGain != seek.gain {
            synth = SeekSynth(sampleRate: sampleRate, headGain: seek.gain)
            seekCache.removeAll()
            tickCache.removeAll()
        }
        self.feed = feed
        speed = .normal
        clock.speed = 1
        feed.pace = 1
        isLoaded = true
        isFinished = false
    }

    // MARK: - Transport

    func play() {
        cancelFade()
        guard isLoaded, !isPlaying, !isFinished else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("Démarrage du moteur impossible : \(error)")
            return
        }
        // La passe n'a pas encore assez d'avance : on attend qu'elle en ait,
        // plutôt que de jouer un début troué.
        interruption = nil
        guard isReady(at: currentTime) else {
            waitForFeed()
            return
        }
        startPlayer()
        if hapticsEnabled { haptics.start() }
        isPlaying = true
        startPump()
    }

    func pause() {
        cancelFade()
        stopWaiting()
        guard isPlaying else { return }
        let t = currentTime
        // `stop` et non `pause` : l'horloge du player repart ainsi de zéro, et
        // `clock.offset` porte seul la correspondance avec la passe.
        player.stop()
        haptics.stop()
        pump?.invalidate()
        pump = nil
        isPlaying = false
        clock.offset = t
        currentTime = t
        generation += 1
    }

    /// Le player part de zéro, et ce qui lui avait été confié sans être joué
    /// lui est reconfié, daté à l'allure courante.
    private func startPlayer() {
        hostStart = CACurrentMediaTime()
        player.play()
        for cue in scheduled where cue.time >= clock.offset {
            schedule(cue, elapsed: 0)
        }
    }

    /// Change l'allure de l'écoute. En pleine lecture, c'est un ré-ancrage :
    /// le player s'arrête — ce qui efface les transitoires datés à l'ancienne
    /// allure — et repart aussitôt du temps de passe atteint. La rotation vit
    /// sur son propre nœud et ne s'en aperçoit pas.
    func setSpeed(_ newSpeed: PlaybackSpeed) {
        guard newSpeed != speed else { return }
        // L'horloge du player, pas `currentTime` : celui-ci date du dernier
        // tour de pompe, et ce retard rejouerait les transitoires d'entre-deux.
        let t = isPlaying ? clock.passTime(elapsed: playerSeconds()) : currentTime
        speed = newSpeed
        clock.speed = newSpeed.rawValue
        feed?.pace = newSpeed.rawValue
        guard isPlaying else { return }
        player.stop()
        clock.offset = t
        currentTime = t
        generation += 1
        startPlayer()
    }

    func toggle() {
        if isPlaying || isBuffering { pause() } else { play() }
    }

    func stop() {
        cancelFade()
        stopWaiting()
        pump?.invalidate()
        pump = nil
        generation += 1
        player.stop()
        haptics.stop()
        haptics.flush()
        isPlaying = false
        currentTime = 0
        clock.offset = 0
        spinCues = []
        hapticCues = []
        scheduled = []
        haptics.resetDiagnostics()
        spindle.snap(to: 0)
    }

    /// Baisse le son jusqu'au silence, puis met en pause : la minuterie d'arrêt
    /// ne coupe pas net une passe qu'on écoute pour s'endormir. Le niveau
    /// général n'est pas touché — seul le mélangeur descend, et remonte à la
    /// pause.
    func pauseFadingOut(over duration: Double = 8) {
        guard fade == nil else { return }
        guard isPlaying else {
            // Rien ne sonne encore : il n'y a rien à baisser.
            pause()
            return
        }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = (CACurrentMediaTime() - start) / duration
                if progress >= 1 || !self.isPlaying {
                    self.pause()
                } else {
                    self.engine.mainMixerNode.outputVolume = self.masterLevel * Float(1 - progress)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fade = timer
    }

    private func cancelFade() {
        guard let fade else { return }
        fade.invalidate()
        self.fade = nil
        engine.mainMixerNode.outputVolume = masterLevel
    }

    /// L'app passe en arrière-plan : un graphe audio qui tourne à vide la
    /// garderait éveillée pour rien. `play()` le relance.
    func suspendIfIdle() {
        guard !isPlaying, !isBuffering, engine.isRunning else { return }
        engine.pause()
    }

    // MARK: - Attente de la passe

    /// Les repères sont-ils complets assez loin devant cet instant ?
    private func isReady(at time: Double) -> Bool {
        guard let feed else { return false }
        feed.update(now: time)
        return feed.endTime != nil || feed.cueWatermark >= time + clock.passSpan(real: lookahead + 0.3)
    }

    private func waitForFeed() {
        guard waiting == nil else { return }
        isBuffering = true
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isReady(at: self.currentTime) else { return }
                self.stopWaiting()
                self.play()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waiting = timer
    }

    private func stopWaiting() {
        waiting?.invalidate()
        waiting = nil
        isBuffering = false
    }

    // MARK: - Horloge

    private func playerSeconds() -> Double {
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime),
           playerTime.sampleTime >= 0 {
            return Double(playerTime.sampleTime) / playerTime.sampleRate
        }
        return max(0, CACurrentMediaTime() - hostStart)
    }

    private func startPump() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
        tick()
    }

    private func tick() {
        guard isPlaying, let feed else { return }
        let elapsed = playerSeconds()
        let now = clock.passTime(elapsed: elapsed)
        // Un vingtième de seconde d'écoute : la tolérance de tout ce qui suit.
        let slack = clock.passSpan(real: 0.05)

        feed.update(now: now)
        if let end = feed.endTime, now >= end {
            currentTime = end
            pause()
            isFinished = true
            return
        }
        currentTime = now

        // Le producteur a pris du retard — un planificateur qui calcule
        // longtemps sans rien émettre. Mieux vaut suspendre que jouer un trou.
        if feed.endTime == nil && feed.cueWatermark < now + slack {
            pause()
            waitForFeed()
            return
        }

        // Transitoires : programmés en avance sur l'horloge du player. La
        // rotation et l'haptique, elles, attendent leur échéance.
        for cue in feed.takeCues(before: now + clock.passSpan(real: lookahead)) {
            switch cue.kind {
            case .spinUp(let duration):
                spinCues.append((cue.time, true, duration))
            case .spinDown(let duration):
                spinCues.append((cue.time, false, duration))
            default:
                schedule(cue, elapsed: elapsed)
                scheduled.append(cue)
                hapticCues.append(cue)
            }
        }
        var played = 0
        while played < scheduled.count && scheduled[played].time < now - slack { played += 1 }
        if played > 0 { scheduled.removeFirst(played) }

        // Rotation : traité à l'échéance, la précision à l'échantillon n'a
        // aucun intérêt sur une rampe de six secondes.
        // La rampe dure ce qu'elle dure à l'écran, où le plateau suit le temps
        // de passe : à ×4, quatre fois moins longtemps.
        while let cue = spinCues.first, cue.time <= now + slack {
            let duration = cue.duration / clock.speed
            if cue.up { spindle.spinUp(duration: duration) }
            else { spindle.spinDown(duration: duration) }
            spinCues.removeFirst()
        }

        if hapticsEnabled {
            haptics.setSpindle(speed: spindle.currentSpeed)
            fireDueHaptics(now: now)
            let failure = haptics.lastFailure.map { " · dernier échec : \($0)" } ?? ""
            hapticReport = "motifs \(haptics.patternsPlayed) · chocs \(haptics.transientsPlayed)"
                + " · échecs \(haptics.patternsFailed)" + failure
        } else {
            hapticCues.removeAll { $0.time <= now }
        }
    }

    /// Les repères haptiques sont déclenchés à l'échéance, pas programmés à
    /// l'avance comme l'audio : la précision d'une période de boucle (~16 ms)
    /// est sous le seuil de discrimination tactile, et cela évite de dépendre de
    /// l'horloge du moteur haptique.
    private func fireDueHaptics(now: Double) {
        var count = 0
        while count < hapticCues.count && hapticCues[count].time <= now + clock.passSpan(real: 0.008) {
            let cue = hapticCues[count]
            count += 1
            // Après un à-coup, on saute le retard plutôt que de le rejouer en rafale.
            guard cue.time >= now - clock.passSpan(real: 0.05) else { continue }
            haptics.fire(cue)
        }
        if count > 0 { hapticCues.removeFirst(count) }
    }

    private func schedule(_ cue: AudioCue, elapsed: Double) {
        let playerOffset = clock.playerOffset(of: cue.time)
        // Trop en retard : on laisse tomber plutôt que d'entasser du son décalé.
        guard playerOffset > elapsed - 0.05 else { return }
        let at = AVAudioTime(sampleTime: AVAudioFramePosition(playerOffset * sampleRate),
                             atRate: sampleRate)

        switch cue.kind {
        case .seek(let profile, let travelMix):
            if let buffer = cachedSeek(profile: profile, travelMix: travelMix) {
                player.scheduleBuffer(buffer, at: at, options: [])
            }

        case .tick(let kind):
            if let buffer = cachedTick(kind) {
                player.scheduleBuffer(buffer, at: at, options: [])
            }

        case .chatter(let run, _):
            // Rendu hors thread principal : un train d'une seconde représente
            // 48 000 échantillons à travers huit filtres.
            let synth = self.synth!
            renderAway(at: at) {
                synth.renderChatter(run: run, variation: UInt32(truncatingIfNeeded: run.count &* 7919))
            }

        case .tickTrain(let ticks, _):
            // Même coût, même traitement : une lecture séquentielle en produit
            // un par seconde.
            let synth = self.synth!
            renderAway(at: at) {
                synth.renderTickTrain(ticks, variation: UInt32(truncatingIfNeeded: ticks.count &* 7919))
            }

        case .unstick:
            if let buffer = cachedTick(key: 2, render: { $0.renderUnstick(variation: 3) }) {
                player.scheduleBuffer(buffer, at: at, options: [])
            }

        case .landing:
            if let buffer = cachedTick(key: 3, render: { $0.renderLanding(variation: 4) }) {
                player.scheduleBuffer(buffer, at: at, options: [])
            }

        case .spinUp, .spinDown:
            break
        }
    }

    /// Rend un tampon hors du fil principal, puis le programme s'il est encore
    /// attendu : une pause ou un changement de passe entre-temps l'écarte.
    private func renderAway(at time: AVAudioTime,
                            _ render: @escaping @Sendable () -> AVAudioPCMBuffer?) {
        let token = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let buffer = render() else { return }
            await MainActor.run {
                guard let self, self.generation == token, self.isPlaying else { return }
                self.player.scheduleBuffer(buffer, at: time, options: [])
            }
        }
    }

    // MARK: - Caches

    private func cachedSeek(profile: SeekProfile, travelMix: Double) -> AVAudioPCMBuffer? {
        // 40 classes de distance × 4 variantes : assez pour que l'oreille
        // n'entende pas la répétition, assez peu pour tout garder en mémoire.
        let bucket = min(Int(travelMix * 40), 39)
        let variation = profile.distance % 4
        let key = bucket * 4 + variation
        if let cached = seekCache[key] { return cached }
        let buffer = synth.renderSeek(profile: profile,
                                      travelMix: travelMix,
                                      variation: UInt32(key + 1))
        seekCache[key] = buffer
        return buffer
    }

    private func cachedTick(_ kind: SeekSynth.Tick) -> AVAudioPCMBuffer? {
        let key = kind == .headSwitch ? 0 : 1
        return cachedTick(key: key) { $0.renderTick(kind, variation: UInt32(key + 1)) }
    }

    private func cachedTick(key: Int, render: (SeekSynth) -> AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        if let cached = tickCache[key] { return cached }
        let buffer = render(synth)
        tickCache[key] = buffer
        return buffer
    }
}

/// Une pause que personne n'a demandée.
struct PlaybackInterruption: Equatable {
    enum Reason: Equatable {
        /// Un appel, une alarme, une autre app qui prend la sortie audio.
        case otherAudio
        /// Le casque ou l'enceinte a été retiré.
        case outputRemoved
        /// La sortie audio a changé et le graphe s'est arrêté.
        case outputChanged
    }

    let reason: Reason
    /// Le temps écouté au moment de la pause.
    let time: Double

    var label: String {
        switch reason {
        case .otherAudio:    return String(localized: "interruption.otherAudio", defaultValue: "a call or another app")
        case .outputRemoved: return String(localized: "interruption.outputRemoved", defaultValue: "audio output removed")
        case .outputChanged: return String(localized: "interruption.outputChanged", defaultValue: "audio output changed")
        }
    }
}

#if SCREENSHOTS
// MARK: - Mode capture

extension WinchesterEngine {

    /// Avance la passe jusqu'à `target` sans la jouer, pour que la capture la
    /// montre en plein travail et non à sa première seconde.
    ///
    /// L'écoute avance par demi-secondes, comme le ferait l'horloge : la carte
    /// et le cumul par phase supposent qu'on n'avance jamais d'une minute d'un
    /// coup. Le producteur ne prend que huit secondes d'avance ; quand il n'en
    /// a plus, on lui laisse le temps d'en reprendre. Les repères dépassés sont
    /// jetés sans être rendus. Ici seulement parce que l'horloge est privée.
    func fastForward(to target: Double) async {
        pause()
        var time = currentTime
        while time < target, let feed {
            feed.update(now: time)
            if let end = feed.endTime, time >= end { break }
            guard feed.endTime != nil || feed.cueWatermark >= time + 1 else {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            let next = min(target, time + 0.5)
            _ = feed.takeCues(before: next)
            time = next
        }
        feed?.update(now: time)
        clock.offset = time
        currentTime = time
        // La passe tourne déjà depuis longtemps : le plateau est à son régime.
        spindle.snap(to: 1)
    }
}
#endif
