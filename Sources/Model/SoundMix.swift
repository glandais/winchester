import Foundation

/// Tout ce que la feuille « Son et vibrations » règle, en une valeur : les
/// trois couches du mixage et l'haptique.
///
/// Le moteur garde ses réglages un par un ; cette valeur est ce qui se compare à
/// un préréglage et ce qui survit à l'app.
struct SoundMix: Codable, Equatable, Sendable {

    var spindleLevel: Float
    var transientLevel: Float
    var masterLevel: Float
    var hapticsEnabled: Bool
    var hapticIntensity: Float
    var spindleHaptics: Bool
    var spindleHapticLevel: Float

    /// Les trois façons d'écouter que proposent les maquettes.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        /// Le mixage d'origine, réglé au casque. Rotation à 20 % : le plateau
        /// d'un disque à roulements de 1993 est fort, et à 32 % il passait
        /// au-dessus des seeks à l'oreille — un réglage d'écoute, pas une
        /// donnée.
        case headphones
        /// Le haut-parleur de l'iPhone n'a pas de grave : la rotation monte, et
        /// le grondement haptique rend dans la main ce que l'oreille n'a plus.
        case speaker
        /// Le son coupé, pas le moteur : l'horloge de la passe est celle du
        /// lecteur audio, qui doit continuer de tourner.
        case hapticsOnly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .headphones:  return String(localized: "sound.preset.headphones", defaultValue: "Headphones")
            case .speaker:     return String(localized: "sound.preset.speaker", defaultValue: "Speaker")
            case .hapticsOnly: return String(localized: "sound.preset.hapticsOnly", defaultValue: "Haptics only")
            }
        }

        var needsHaptics: Bool { self == .hapticsOnly }

        var mix: SoundMix {
            switch self {
            case .headphones:
                return SoundMix(spindleLevel: 0.20, transientLevel: 1.0, masterLevel: 0.85,
                                hapticsEnabled: true, hapticIntensity: 0.85,
                                spindleHaptics: true, spindleHapticLevel: 0.45)
            case .speaker:
                return SoundMix(spindleLevel: 0.50, transientLevel: 1.0, masterLevel: 1.0,
                                hapticsEnabled: true, hapticIntensity: 0.85,
                                spindleHaptics: true, spindleHapticLevel: 0.60)
            case .hapticsOnly:
                return SoundMix(spindleLevel: 0.32, transientLevel: 1.0, masterLevel: 0,
                                hapticsEnabled: true, hapticIntensity: 1.0,
                                spindleHaptics: true, spindleHapticLevel: 0.60)
            }
        }
    }

    /// Le mixage d'une première ouverture.
    static let standard = Preset.headphones.mix

    /// Le préréglage que ce mixage reproduit, s'il en reproduit un. Un curseur
    /// déplacé d'un cheveu n'en reproduit plus aucun : l'écart toléré n'absorbe
    /// que l'arrondi d'un `Float` relu.
    var preset: Preset? {
        Preset.allCases.first { $0.mix.isClose(to: self) }
    }

    private func isClose(to other: SoundMix) -> Bool {
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.005 }
        return near(spindleLevel, other.spindleLevel)
            && near(transientLevel, other.transientLevel)
            && near(masterLevel, other.masterLevel)
            && hapticsEnabled == other.hapticsEnabled
            && near(hapticIntensity, other.hapticIntensity)
            && spindleHaptics == other.spindleHaptics
            && near(spindleHapticLevel, other.spindleHapticLevel)
    }

    // MARK: - Ce qui survit à l'app

    static let defaultsKey = "soundMix"

    /// Le mixage enregistré, ou le mixage d'origine s'il n'y en a pas — ou s'il
    /// ne se relit plus : un réglage de volume perdu ne vaut pas une erreur.
    static func load(from defaults: UserDefaults) -> SoundMix {
        guard let data = defaults.data(forKey: defaultsKey),
              let mix = try? JSONDecoder().decode(SoundMix.self, from: data) else { return .standard }
        return mix.clamped()
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Chaque niveau ramené entre 0 et 1 : un fichier modifié à la main ne doit
    /// pas faire saturer la sortie.
    func clamped() -> SoundMix {
        func unit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }
        var mix = self
        mix.spindleLevel = unit(spindleLevel)
        mix.transientLevel = unit(transientLevel)
        mix.masterLevel = unit(masterLevel)
        mix.hapticIntensity = unit(hapticIntensity)
        mix.spindleHapticLevel = unit(spindleHapticLevel)
        return mix
    }
}
