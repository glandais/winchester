import Foundation
import AVFoundation
import QuartzCore
import Combine

/// Graphe audio du spike.
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
final class DiskNoiseEngine: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isLoaded = false

    @Published var spindleLevel: Float = 0.32 { didSet { spindleMixer.outputVolume = spindleLevel } }
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

    private var cues: [AudioCue] = []
    private var spinCues: [(time: Double, up: Bool, duration: Double)] = []
    private var nextCue = 0
    private var nextSpinCue = 0
    private var nextHapticCue = 0
    private var traceDuration: Double = 0

    /// Temps de trace correspondant à l'instant 0 de l'horloge du player.
    private var timelineOffset: Double = 0
    private var hostStart: Double = 0
    private var generation = 0

    private var pump: Timer?
    private var seekCache: [Int: AVAudioPCMBuffer] = [:]
    private var tickCache: [Int: AVAudioPCMBuffer] = [:]
    private let renderQueue = DispatchQueue(label: "fr.glandais.disknoise.render", qos: .userInitiated)

    private let lookahead = 0.70

    // MARK: - Cycle de vie

    init(rpm: Double) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        synth = SeekSynth(sampleRate: sampleRate)
        spindle = SpindleVoice(sampleRate: sampleRate, rpm: rpm)
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

    func load(cues: [AudioCue], duration: Double) {
        stop()
        var transientCues: [AudioCue] = []
        var spins: [(Double, Bool, Double)] = []
        for cue in cues {
            switch cue.kind {
            case .spinUp(let d): spins.append((cue.time, true, d))
            case .spinDown(let d): spins.append((cue.time, false, d))
            default: transientCues.append(cue)
            }
        }
        self.cues = transientCues
        self.spinCues = spins
        self.traceDuration = duration
        self.isLoaded = true
        seekTo(0)
    }

    // MARK: - Transport

    func play() {
        guard isLoaded, !isPlaying else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("Démarrage du moteur impossible : \(error)")
            return
        }
        hostStart = CACurrentMediaTime()
        player.play()
        if hapticsEnabled { haptics.start() }
        isPlaying = true
        startPump()
    }

    func pause() {
        guard isPlaying else { return }
        let t = currentTime
        player.pause()
        haptics.stop()
        pump?.invalidate()
        pump = nil
        isPlaying = false
        timelineOffset = t
        currentTime = t
        generation += 1
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        pump?.invalidate()
        pump = nil
        generation += 1
        player.stop()
        haptics.stop()
        isPlaying = false
        currentTime = 0
        timelineOffset = 0
        nextCue = 0
        nextSpinCue = 0
        nextHapticCue = 0
        haptics.resetDiagnostics()
        spindle.snap(to: 0)
    }

    /// Saut dans la chronologie. Le player est réinitialisé, ce qui remet son
    /// horloge à zéro : `timelineOffset` porte alors la correspondance.
    func seekTo(_ time: Double) {
        let wasPlaying = isPlaying
        pump?.invalidate()
        pump = nil
        generation += 1
        player.stop()
        haptics.flush()
        isPlaying = false

        let t = min(max(time, 0), traceDuration)
        timelineOffset = t
        currentTime = t
        nextCue = cues.firstIndex { $0.time >= t } ?? cues.count
        nextHapticCue = nextCue
        nextSpinCue = spinCues.firstIndex { $0.time >= t } ?? spinCues.count

        // Le plateau tourne-t-il déjà à cet instant ?
        let previousSpin = spinCues.prefix(nextSpinCue).last
        spindle.snap(to: (previousSpin?.up ?? false) ? 1 : 0)

        if wasPlaying { play() }
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
        guard isPlaying else { return }
        let elapsed = playerSeconds()
        let now = timelineOffset + elapsed
        currentTime = min(now, traceDuration)

        if now >= traceDuration {
            pause()
            return
        }

        // Rotation : traité à l'échéance, la précision à l'échantillon n'a
        // aucun intérêt sur une rampe de six secondes.
        while nextSpinCue < spinCues.count && spinCues[nextSpinCue].time <= now + 0.05 {
            let cue = spinCues[nextSpinCue]
            if cue.up { spindle.spinUp(duration: cue.duration) }
            else { spindle.spinDown(duration: cue.duration) }
            nextSpinCue += 1
        }

        if hapticsEnabled {
            haptics.setSpindle(speed: spindle.currentSpeed)
            fireDueHaptics(now: now)
            let failure = haptics.lastFailure.map { " · dernier échec : \($0)" } ?? ""
            hapticReport = "motifs \(haptics.patternsPlayed) · chocs \(haptics.transientsPlayed)"
                + " · échecs \(haptics.patternsFailed)" + failure
        }

        // Transitoires : programmés en avance sur l'horloge du player.
        while nextCue < cues.count && (cues[nextCue].time - timelineOffset) < elapsed + lookahead {
            let cue = cues[nextCue]
            nextCue += 1
            schedule(cue, elapsed: elapsed)
        }
    }

    /// Les repères haptiques sont déclenchés à l'échéance, pas programmés à
    /// l'avance comme l'audio : la précision d'une période de boucle (~16 ms)
    /// est sous le seuil de discrimination tactile, et cela évite de dépendre de
    /// l'horloge du moteur haptique.
    private func fireDueHaptics(now: Double) {
        while nextHapticCue < cues.count && cues[nextHapticCue].time <= now + 0.008 {
            let cue = cues[nextHapticCue]
            nextHapticCue += 1
            // Après un à-coup, on saute le retard plutôt que de le rejouer en rafale.
            guard cue.time >= now - 0.05 else { continue }
            haptics.fire(cue)
        }
    }

    private func schedule(_ cue: AudioCue, elapsed: Double) {
        let playerOffset = cue.time - timelineOffset
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
            let token = generation
            let synth = self.synth!
            renderQueue.async {
                let buffer = synth.renderChatter(run: run, variation: UInt32(truncatingIfNeeded: run.count &* 7919))
                guard let buffer else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isPlaying else { return }
                    self.player.scheduleBuffer(buffer, at: at, options: [])
                }
            }

        case .spinUp, .spinDown:
            break
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
        if let cached = tickCache[key] { return cached }
        let buffer = synth.renderTick(kind, variation: UInt32(key + 1))
        tickCache[key] = buffer
        return buffer
    }
}
