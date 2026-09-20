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
/// Faute d'échantillon, cette voix est procédurale : l'essentiel de l'énergie
/// est du bruit filtré par quelques résonances, et la composante tonale à
/// `tr·min⁻¹/60` reste volontairement discrète — elle donne le battement
/// une-fois-par-tour, pas le timbre. Ce qui fait le timbre, c'est
/// `SpindleCharacter` : le souffle glisse et s'éclaircit avec le régime, un
/// roulement à billes siffle et bat à chaque tour, et le niveau de chaque
/// disque est celui que son époque mesurait. **Un échantillon bouclé en CC0 la
/// remplacerait avec profit, disque par disque — c'est toujours le maillon
/// faible.**
final class SpindleVoice {

    private let sampleRate: Double

    /// Le disque qu'on entend. Modifiable pour passer d'un disque à l'autre
    /// sans reconstruire le graphe audio : écrit par le thread principal avant
    /// la lecture, lu par le thread audio, qui recalcule ses filtres au bloc
    /// suivant.
    var character: SpindleCharacter {
        didSet { characterVersion &+= 1 }
    }
    private var characterVersion = 0
    private var coefficientVersion = -1

    // État du rendu — écrit par le thread audio.
    private var speed: Double = 0
    private var phase0: Double = 0
    private var phase1: Double = 0
    private var phase2: Double = 0
    private var phaseCommutation: Double = 0
    private var flutterPhase: Double = 0

    private var noiseL = NoiseSource(seed: 0x9E37_79B9)
    private var noiseR = NoiseSource(seed: 0x85EB_CA6B)
    /// Les bandes du disque courant, tirées une fois par caractère : le calcul
    /// alloue, et il ne doit pas le faire à chaque bloc d'une rampe.
    private var bands: [SpindleCharacter.Band] = []
    private var bankL: [Biquad] = []
    private var bankR: [Biquad] = []
    private var bandGain: [Double] = []
    private var bandModulated: [Bool] = []
    private var lastCoefficientSpeed: Double = -1
    /// Niveaux du disque courant, tirés de son caractère.
    private var tonalGain = 1.0
    private var commutationLevel = 0.0

    // Consignes — écrites par le thread principal, lues par le thread audio.
    // Accès non synchronisé, acceptable : ce sont des Double isolés dont une
    // lecture déchirée n'aurait aucune conséquence audible.
    private var target: Double = 0
    private var timeConstant: Double = 1.0

    /// Écart-type de la voix d'avant — trois bandes fixes à 185, 520 et
    /// 1 450 Hz, gains 1, 0,55 et 0,28, sur un bruit uniforme. C'est le niveau
    /// du mélange par défaut, que `SpindleCharacter.gain` vaut 1 pour y rester.
    private static let referenceDeviation: Double = {
        let bands: [(Double, Double, Double)] = [(185, 7.0, 1.0), (520, 4.5, 0.55), (1_450, 2.2, 0.28)]
        let variance = bands.reduce(0) { sum, band in
            sum + band.2 * band.2 * bandVariance(frequency: band.0, q: band.1, sampleRate: 48_000)
        }
        return 0.9 * variance.squareRoot()
    }()

    /// Variance de la sortie d'un passe-bande à gain crête unitaire nourri d'un
    /// bruit blanc uniforme sur [-1, 1] : sa bande équivalente de bruit vaut
    /// `π·f/(2Q)`, rapportée à la moitié de la fréquence d'échantillonnage.
    private static func bandVariance(frequency: Double, q: Double, sampleRate: Double) -> Double {
        (1.0 / 3.0) * Double.pi * frequency / (q * sampleRate)
    }

    init(sampleRate: Double, character: SpindleCharacter) {
        self.sampleRate = sampleRate
        self.character = character
        updateCoefficients(for: 0)
    }

    // MARK: - Commandes

    /// Vitesse instantanée, 0 à l'arrêt, 1 au régime nominal. Lue par la couche
    /// haptique pour doser son grondement.
    var currentSpeed: Double { speed }

    // La constante de temps est celle de `SpindleTimeline`, qui fait tourner le
    // plateau à l'écran : les deux décrivent le même moteur, et si elles
    // divergent l'image cesse de coller au son.

    func spinUp(duration: Double) {
        target = 1
        timeConstant = SpindleTimeline.timeConstant(forRamp: duration)
    }

    func spinDown(duration: Double) {
        target = 0
        timeConstant = SpindleTimeline.timeConstant(forRamp: duration)
    }

    /// Positionnement instantané, utilisé quand on saute dans la chronologie.
    func snap(to value: Double) {
        target = value
        speed = value
    }

    // MARK: - Rendu

    /// Filtres et gains du disque courant à la vitesse donnée.
    ///
    /// Pendant la rampe, tout glisse vers le grave (`0,35 + 0,65·v`) : c'est la
    /// montée du spin-up. À plein régime, ce sont les bandes du caractère — et
    /// leur fréquence dépend du régime nominal, plus seulement de la rampe.
    /// Le gain de chaque bande est choisi pour qu'elle porte exactement sa part
    /// de puissance : le niveau total est celui du caractère, quelle que soit
    /// la forme du spectre.
    private func updateCoefficients(for speed: Double) {
        let scale = 0.35 + 0.65 * speed
        let deviation = Self.referenceDeviation * character.gain
        // Les tableaux ne sont refaits que quand le disque change. Pendant une
        // rampe, qui recalcule les coefficients à chaque bloc sur le fil audio,
        // ils sont réécrits en place : aucune allocation.
        if coefficientVersion != characterVersion || bands.isEmpty {
            bands = character.bands
            bankL = Array(repeating: Biquad(), count: bands.count)
            bankR = bankL
            bandGain = Array(repeating: 0, count: bands.count)
            bandModulated = bands.map(\.modulated)
        }
        // Un roulement ne glisse pas : ses bandes sont des résonances de la
        // structure, fixes. Seules celles du souffle suivent la vitesse, mais
        // on les calcule toutes à la même échelle pendant la rampe — c'est une
        // demi-seconde, et l'oreille n'y entend qu'une montée.
        for index in bands.indices {
            let band = bands[index]
            bankL[index] = Biquad.bandpass(frequency: band.frequency * scale, q: band.q, sampleRate: sampleRate)
            bankR[index] = Biquad.bandpass(frequency: band.frequency * scale * 1.012, q: band.q,
                                           sampleRate: sampleRate)
            let variance = Self.bandVariance(frequency: band.frequency, q: band.q, sampleRate: sampleRate)
            bandGain[index] = deviation * (band.power / variance).squareRoot()
        }
        tonalGain = character.gain
        // La raie de commutation, un vingtième du bruit en amplitude : on la
        // devine sous le souffle, on ne l'entend pas siffler.
        commutationLevel = 0.05 * deviation * 2.squareRoot()
        lastCoefficientSpeed = speed
        coefficientVersion = characterVersion
    }

    /// Cœur du rendu, partagé par le nœud temps réel et le rendu hors-ligne.
    func render(left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>,
                count: Int) {

        // Les coefficients ne sont recalculés qu'une fois par bloc : la vitesse
        // évolue sur plusieurs secondes, inutile de le faire par échantillon.
        if abs(speed - lastCoefficientSpeed) > 0.004 || coefficientVersion != characterVersion {
            updateCoefficients(for: speed)
        }

        let dt = 1.0 / sampleRate
        let approach = 1 - exp(-dt / max(timeConstant, 0.01))
        let rpm = character.rpm
        let commutations = SpindleCharacter.commutationsPerTurn

        for frame in 0..<count {
            speed += (target - speed) * approach
            let s = max(speed, 0)

            // Fondamentale de rotation : 120 Hz à 7 200 tr/min.
            let f0 = rpm * s / 60.0
            phase0 += 2 * .pi * f0 * dt
            phase1 += 2 * .pi * f0 * 2 * dt
            phase2 += 2 * .pi * f0 * 3.47 * dt
            phaseCommutation += 2 * .pi * f0 * commutations * dt
            flutterPhase += 2 * .pi * 0.63 * dt
            if phase0 > 2 * .pi { phase0 -= 2 * .pi }
            if phase1 > 2 * .pi { phase1 -= 2 * .pi }
            if phase2 > 2 * .pi { phase2 -= 2 * .pi }
            if phaseCommutation > 2 * .pi { phaseCommutation -= 2 * .pi }
            if flutterPhase > 2 * .pi { flutterPhase -= 2 * .pi }

            let tonal = (sin(phase0) * 0.075
                + sin(phase1) * 0.040
                + sin(phase2) * 0.018) * tonalGain
                + sin(phaseCommutation) * commutationLevel

            let envelope = pow(s, 1.6) * (1 + 0.05 * sin(flutterPhase))
            // Un roulement n'est jamais rond : son sifflement bat une fois par
            // tour. C'est le « wow » d'un vieux disque au repos.
            let wobble = 1 + 0.35 * sin(phase0)

            var l = 0.0
            var r = 0.0
            let nl = noiseL.next()
            let nr = noiseR.next()
            for band in 0..<bankL.count {
                let gain = bandModulated[band] ? bandGain[band] * wobble : bandGain[band]
                l += bankL[band].process(nl) * gain
                r += bankR[band].process(nr) * gain
            }

            left[frame] = Float((l + tonal) * envelope)
            right[frame] = Float((r + tonal * 0.94) * envelope)
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
