import Foundation
import AVFAudio

/// Couche continue : rotation du plateau et paliers.
///
/// Attention au piège documenté par la recherche : le ronronnement d'un disque
/// n'est **pas** une série harmonique calculable à partir du régime. Les deux
/// affirmations « la fondamentale vaut tr·min⁻¹/60 » et « les harmoniques
/// découlent du nombre de billes du roulement » ont été réfutées à l'unanimité,
/// et tous les projets qui fonctionnent (MAME, HDDSynth) bouclent un
/// enregistrement.
///
/// Faute d'échantillon dans ce spike, cette voix est procédurale : l'essentiel
/// de l'énergie est du bruit filtré par quelques résonances, et la composante
/// tonale à `tr·min⁻¹/60` reste volontairement discrète — elle donne le
/// battement une-fois-par-tour, pas le timbre. **C'est le maillon faible du
/// spike : à remplacer par un sample bouclé en CC0 dès qu'on en a un.**
final class SpindleVoice {

    private let sampleRate: Double
    /// Régime nominal. Modifiable pour passer d'un disque à l'autre sans
    /// reconstruire le graphe audio — même réserve que pour les consignes
    /// ci-dessous : un `Double` lu par le thread audio sans synchronisation.
    var rpm: Double

    // État du rendu — écrit par le thread audio.
    private var speed: Double = 0
    private var phase0: Double = 0
    private var phase1: Double = 0
    private var phase2: Double = 0
    private var flutterPhase: Double = 0

    private var noiseL = NoiseSource(seed: 0x9E37_79B9)
    private var noiseR = NoiseSource(seed: 0x85EB_CA6B)
    private var bankL: [Biquad] = []
    private var bankR: [Biquad] = []
    private var lastCoefficientSpeed: Double = -1

    // Consignes — écrites par le thread principal, lues par le thread audio.
    // Accès non synchronisé, acceptable pour un spike : ce sont des Double
    // isolés dont une lecture déchirée n'aurait aucune conséquence audible.
    private var target: Double = 0
    private var timeConstant: Double = 1.0

    /// Fréquences centrales au régime nominal. Elles sont glissées vers le bas
    /// à basse vitesse, ce qui produit la montée caractéristique du spin-up.
    private let baseFrequencies: [Double] = [185, 520, 1_450]
    private let bandQ: [Double] = [7.0, 4.5, 2.2]
    private let bandGain: [Double] = [1.0, 0.55, 0.28]

    init(sampleRate: Double, rpm: Double) {
        self.sampleRate = sampleRate
        self.rpm = rpm
        updateCoefficients(for: 0)
    }

    // MARK: - Commandes

    /// Vitesse instantanée, 0 à l'arrêt, 1 au régime nominal. Lue par la couche
    /// haptique pour doser son grondement.
    var currentSpeed: Double { speed }

    func spinUp(duration: Double) {
        target = 1
        timeConstant = max(duration, 0.2) / 3.2
    }

    func spinDown(duration: Double) {
        target = 0
        timeConstant = max(duration, 0.2) / 3.2
    }

    /// Positionnement instantané, utilisé quand on saute dans la chronologie.
    func snap(to value: Double) {
        target = value
        speed = value
    }

    // MARK: - Rendu

    private func updateCoefficients(for speed: Double) {
        let scale = 0.35 + 0.65 * speed
        bankL = (0..<baseFrequencies.count).map {
            Biquad.bandpass(frequency: baseFrequencies[$0] * scale,
                            q: bandQ[$0], sampleRate: sampleRate)
        }
        bankR = (0..<baseFrequencies.count).map {
            Biquad.bandpass(frequency: baseFrequencies[$0] * scale * 1.012,
                            q: bandQ[$0], sampleRate: sampleRate)
        }
        lastCoefficientSpeed = speed
    }

    /// Cœur du rendu, partagé par le nœud temps réel et le rendu hors-ligne.
    func render(left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>,
                count: Int) {

        // Les coefficients ne sont recalculés qu'une fois par bloc : la vitesse
        // évolue sur plusieurs secondes, inutile de le faire par échantillon.
        if abs(speed - lastCoefficientSpeed) > 0.004 {
            updateCoefficients(for: speed)
        }

        let dt = 1.0 / sampleRate
        let approach = 1 - exp(-dt / max(timeConstant, 0.01))

        for frame in 0..<count {
            speed += (target - speed) * approach
            let s = max(speed, 0)

            // Fondamentale de rotation : 120 Hz à 7 200 tr/min.
            let f0 = rpm * s / 60.0
            phase0 += 2 * .pi * f0 * dt
            phase1 += 2 * .pi * f0 * 2 * dt
            phase2 += 2 * .pi * f0 * 3.47 * dt
            flutterPhase += 2 * .pi * 0.63 * dt
            if phase0 > 2 * .pi { phase0 -= 2 * .pi }
            if phase1 > 2 * .pi { phase1 -= 2 * .pi }
            if phase2 > 2 * .pi { phase2 -= 2 * .pi }
            if flutterPhase > 2 * .pi { flutterPhase -= 2 * .pi }

            let tonal = sin(phase0) * 0.075
                + sin(phase1) * 0.040
                + sin(phase2) * 0.018

            let envelope = pow(s, 1.6) * (1 + 0.05 * sin(flutterPhase))

            var l = 0.0
            var r = 0.0
            let nl = noiseL.next()
            let nr = noiseR.next()
            for band in 0..<bankL.count {
                l += bankL[band].process(nl) * bandGain[band]
                r += bankR[band].process(nr) * bandGain[band]
            }

            left[frame] = Float((l * 0.9 + tonal) * envelope)
            right[frame] = Float((r * 0.9 + tonal * 0.94) * envelope)
        }
    }

    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            if buffers.count >= 2, let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                render(left: first, right: second, count: n)
            } else {
                // Sortie mono : on rend en stéréo dans un tampon temporaire puis
                // on replie, plutôt que de dupliquer la boucle de synthèse.
                var scratch = [Float](repeating: 0, count: n * 2)
                scratch.withUnsafeMutableBufferPointer { buffer in
                    let base = buffer.baseAddress!
                    render(left: base, right: base + n, count: n)
                    for i in 0..<n { first[i] = (base[i] + base[n + i]) * 0.5 }
                }
            }
            return noErr
        }
    }
}
