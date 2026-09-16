import Testing
import Foundation
@testable import DefragKit

/// Les préréglages de « Son et vibrations », et ce qui en survit à l'app.
@Suite("Son et vibrations")
struct SoundMixTests {

    private static func defaults() -> UserDefaults {
        let name = "disknoise-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("Chaque préréglage se reconnaît, et ils sont tous distincts")
    func presetsAreRecognised() {
        for preset in SoundMix.Preset.allCases {
            #expect(preset.mix.preset == preset)
        }
        #expect(Set(SoundMix.Preset.allCases.map(\.mix.masterLevel)).count >= 2)
        #expect(SoundMix.standard.preset == .headphones)
    }

    @Test("Un curseur déplacé ne correspond plus à aucun préréglage")
    func movedSliderIsCustom() {
        var mix = SoundMix.Preset.speaker.mix
        mix.spindleLevel -= 0.05
        #expect(mix.preset == nil)
        mix = SoundMix.Preset.headphones.mix
        mix.hapticsEnabled = false
        #expect(mix.preset == nil)
    }

    @Test("Vibrations seules coupe le son sans couper l'haptique")
    func hapticsOnly() {
        let mix = SoundMix.Preset.hapticsOnly.mix
        #expect(mix.masterLevel == 0)
        #expect(mix.hapticsEnabled)
        #expect(SoundMix.Preset.hapticsOnly.needsHaptics)
        #expect(!SoundMix.Preset.headphones.needsHaptics)
    }

    @Test("Le mixage enregistré se relit ; rien d'enregistré donne le mixage d'origine")
    func roundTrip() {
        let defaults = Self.defaults()
        #expect(SoundMix.load(from: defaults) == .standard)
        var mix = SoundMix.Preset.speaker.mix
        mix.hapticIntensity = 0.4
        mix.save(to: defaults)
        #expect(SoundMix.load(from: defaults) == mix)
    }

    @Test("Un enregistrement illisible ou hors bornes ne casse rien")
    func damagedDefaults() throws {
        let defaults = Self.defaults()
        defaults.set(Data("pas du json".utf8), forKey: SoundMix.defaultsKey)
        #expect(SoundMix.load(from: defaults) == .standard)

        var loud = SoundMix.standard
        loud.masterLevel = 7
        loud.spindleLevel = -1
        loud.save(to: defaults)
        let reloaded = SoundMix.load(from: defaults)
        #expect(reloaded.masterLevel == 1)
        #expect(reloaded.spindleLevel == 0)
    }
}
