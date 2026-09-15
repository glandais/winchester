import Foundation
import DiskCore
import AVFAudio

/// Mode structurel de l'ensemble bras + bobine mobile.
///
/// Jiang & Macioce, « Fundamentals of Hard Disk Drive Acoustics » :
/// *« these tonal frequencies are not affected by the seek speed as they remain
/// fixed in frequency even if the disk is operated at different seek rates »*.
/// D'où le principe de ce synthétiseur : **les fréquences ne bougent jamais**,
/// seule l'excitation change. Un seek long n'est pas un seek court transposé,
/// c'est le même résonateur attaqué autrement.
struct ActuatorMode {
    let frequency: Double
    let q: Double
    /// Gain appliqué pour un seek piste-à-piste.
    let shortGain: Double
    /// Gain appliqué pour un seek pleine course.
    let longGain: Double
}

/// Synthèse des transitoires de tête par banc de résonateurs excité par un
/// profil de courant.
final class SeekSynth {

    let sampleRate: Double
    let format: AVAudioFormat

    /// Les deux modes autour de 4,5 kHz (sway S1) et 5,5 kHz (S2) sont ceux
    /// identifiés dans la littérature ; les autres complètent le spectre pour
    /// obtenir un timbre plausible. Les valeurs de Q et de gain sont réglées à
    /// l'oreille : aucune source ne fournit un jeu de paramètres prêt à l'emploi.
    let modes: [ActuatorMode] = [
        ActuatorMode(frequency:  760, q:  6, shortGain: 0.22, longGain: 0.80),
        ActuatorMode(frequency: 1_450, q: 11, shortGain: 0.40, longGain: 0.92),
        ActuatorMode(frequency: 2_100, q: 18, shortGain: 0.58, longGain: 0.86),
        ActuatorMode(frequency: 3_300, q: 26, shortGain: 0.82, longGain: 0.58),
        ActuatorMode(frequency: 4_500, q: 34, shortGain: 1.00, longGain: 0.52),
        ActuatorMode(frequency: 5_500, q: 40, shortGain: 0.92, longGain: 0.38),
        ActuatorMode(frequency: 7_200, q: 30, shortGain: 0.56, longGain: 0.20),
    ]

    /// Résonance résiduelle laissée après la fin mécanique du seek.
    private let ringTail = 0.040

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    // MARK: - Excitation

    /// Amplitude d'excitation en fonction de la distance parcourue.
    ///
    /// La relation réelle n'est pas monotone — un profil de courant plus doux
    /// est moins bruyant à courant crête égal — donc cette courbe est un
    /// réglage à l'oreille, pas une loi tirée de la littérature.
    private func level(travelMix: Double) -> Double {
        0.32 + 0.68 * pow(min(max(travelMix, 0), 1), 0.35)
    }

    /// Écrit dans `buffer` le signal d'excitation d'un seek, à partir de `offset`.
    ///
    /// Les quatre phases de Ruemmler & Wilkes donnent l'ossature :
    /// - *speedup* : montée de courant, attaque franche
    /// - *coast* : courant quasi nul, seul le frottement d'air subsiste
    /// - *slowdown* : décélération, légèrement plus violente que l'accélération
    /// - *settle* : asservissement fin, d'où le petit tic terminal
    @discardableResult
    private func writeExcitation(profile: SeekProfile,
                                 travelMix: Double,
                                 into buffer: inout [Double],
                                 at offset: Int,
                                 noise: inout NoiseSource) -> Int {

        let amplitude = level(travelMix: travelMix)
        var index = offset

        func samples(_ seconds: Double) -> Int { max(Int(seconds * sampleRate), 0) }

        @inline(__always)
        func put(_ value: Double) {
            guard index >= 0 && index < buffer.count else { index += 1; return }
            buffer[index] += value
            index += 1
        }

        @inline(__always)
        func strike(_ strength: Double) {
            // Front de courant : quelques échantillons de large bande.
            for k in 0..<3 where index + k >= 0 && index + k < buffer.count {
                buffer[index + k] += strength * (1.0 - Double(k) / 3.0)
            }
        }

        // Speedup
        let nUp = samples(profile.speedup)
        strike(amplitude * 0.95)
        for i in 0..<nUp {
            let u = Double(i) / Double(max(nUp, 1))
            let shape = pow(sin(Double.pi * u), 1.2)
            put(noise.next() * shape * amplitude * 0.90)
        }

        // Coast — seulement sur les seeks longs.
        let nCoast = samples(profile.coast)
        for _ in 0..<nCoast {
            put(noise.next() * 0.11 * amplitude)
        }

        // Slowdown
        let nDown = samples(profile.slowdown)
        strike(amplitude * 1.05)
        for i in 0..<nDown {
            let u = Double(i) / Double(max(nDown, 1))
            let shape = pow(sin(Double.pi * u), 1.15)
            put(noise.next() * shape * amplitude * 1.05)
        }

        // Settle — le tic de fin de course.
        let nSettle = samples(profile.settle)
        strike(amplitude * 1.15)
        for i in 0..<nSettle {
            let u = Double(i) / Double(max(nSettle, 1))
            put(noise.next() * exp(-6 * u) * 0.55 * amplitude)
        }

        return index
    }

    // MARK: - Banc de résonateurs

    /// Passe l'excitation dans le banc de modes. Un seul passage, quel que soit
    /// le nombre de seeks contenus dans l'excitation : les résonateurs gardent
    /// leur état d'un seek au suivant, ce qui est à la fois plus juste
    /// physiquement et bien plus propre à l'oreille que de superposer des
    /// one-shots pré-rendus.
    private func resonate(_ excitation: [Double], travelMix: Double) -> [Double] {
        var output = [Double](repeating: 0, count: excitation.count)

        for mode in modes {
            var filter = Biquad.bandpass(frequency: mode.frequency, q: mode.q, sampleRate: sampleRate)
            let gain = mode.shortGain + (mode.longGain - mode.shortGain) * travelMix
            for i in 0..<excitation.count {
                output[i] += filter.process(excitation[i]) * gain
            }
        }

        // Composante large bande : le « clac » mécanique, qui n'est pas tonal.
        var broadband = Biquad.highpass(frequency: 1_200, q: 0.8, sampleRate: sampleRate)
        for i in 0..<excitation.count {
            output[i] += broadband.process(excitation[i]) * 0.24
        }

        // Adoucissement final + saturation douce.
        var smooth = Biquad.lowpass(frequency: 11_500, q: 0.707, sampleRate: sampleRate)
        for i in 0..<output.count {
            let y = smooth.process(output[i])
            output[i] = tanh(y * 1.5) / 1.5
        }

        // Fondus pour éviter les clics de bord de buffer.
        let fadeIn = min(24, output.count)
        for i in 0..<fadeIn { output[i] *= Double(i) / Double(fadeIn) }
        let fadeOut = min(256, output.count)
        for i in 0..<fadeOut {
            let j = output.count - 1 - i
            output[j] *= Double(i) / Double(fadeOut)
        }

        return output
    }

    // MARK: - Rendus

    /// Seek isolé.
    func renderSeek(profile: SeekProfile, travelMix: Double, variation: UInt32) -> AVAudioPCMBuffer? {
        let count = Int((profile.total + ringTail) * sampleRate) + 8
        var excitation = [Double](repeating: 0, count: count)
        var noise = NoiseSource(seed: variation &* 2_654_435_761 &+ 1)
        writeExcitation(profile: profile, travelMix: travelMix,
                        into: &excitation, at: 0, noise: &noise)
        return makeBuffer(resonate(excitation, travelMix: travelMix))
    }

    /// Train de seeks rapprochés.
    ///
    /// Adaptation directe de la règle de MAME : dès qu'un second pas survient
    /// avant la fin du précédent, on ne **relance pas** le one-shot — on bascule
    /// sur un rendu continu, et on ne replace le transitoire terminal qu'à la
    /// toute fin. Relancer le sample donnerait, selon l'implémenteur d'origine,
    /// quelque chose de « much too loud, and it sounds weird ».
    func renderChatter(run: [ChatterSeek],
                       variation: UInt32) -> AVAudioPCMBuffer? {
        guard let last = run.last else { return nil }
        let span = last.offset + last.profile.total + ringTail
        let count = Int(span * sampleRate) + 8
        guard count > 8 else { return nil }

        var excitation = [Double](repeating: 0, count: count)
        var noise = NoiseSource(seed: variation &* 40_503 &+ 7)

        for seek in run {
            writeExcitation(profile: seek.profile, travelMix: seek.travelMix,
                            into: &excitation, at: Int(seek.offset * sampleRate),
                            noise: &noise)
        }

        // Le « pop » de fin de train, appuyé.
        let endIndex = Int((last.offset + last.profile.total) * sampleRate)
        for k in 0..<4 where endIndex + k < count {
            excitation[endIndex + k] += 0.55 * (1 - Double(k) / 4)
        }

        let mix = run.map(\.travelMix).reduce(0, +) / Double(run.count)
        return makeBuffer(resonate(excitation, travelMix: mix))
    }

    enum Tick {
        case headSwitch
        case trackStep
    }

    /// Micro-transitoires : commutation de tête et pas de piste. Ce sont eux qui
    /// donnent son grain à une longue lecture séquentielle, autrement muette.
    func renderTick(_ tick: Tick, variation: UInt32) -> AVAudioPCMBuffer? {
        let duration = tick == .headSwitch ? 0.010 : 0.022
        let strength = tick == .headSwitch ? 0.16 : 0.38
        let count = Int(duration * sampleRate) + 4

        var excitation = [Double](repeating: 0, count: count)
        var noise = NoiseSource(seed: variation &* 97 &+ 13)
        for k in 0..<3 where k < count { excitation[k] += strength * (1 - Double(k) / 3) }
        for i in 0..<count {
            let u = Double(i) / Double(count)
            excitation[i] += noise.next() * exp(-14 * u) * strength * 0.5
        }

        // Timbre volontairement aigu : peu de masse en mouvement.
        return makeBuffer(resonate(excitation, travelMix: 0.05))
    }

    // MARK: - Conversion

    /// Léger décalage entre canaux pour élargir l'image sans réverbération.
    private func makeBuffer(_ mono: [Double]) -> AVAudioPCMBuffer? {
        guard !mono.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(mono.count)),
              let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(mono.count)
        let delay = Int(0.00035 * sampleRate)
        let left = channels[0]
        let right = channels[1]

        for i in 0..<mono.count {
            left[i] = Float(mono[i])
            let delayed = i >= delay ? mono[i - delay] : 0
            right[i] = Float(delayed * 0.88 + mono[i] * 0.12)
        }
        return buffer
    }
}
