import SwiftUI

/// La feuille « Son et vibrations » — maquette 15.
///
/// Trois préréglages d'abord, pour qui ne veut pas régler : Casque,
/// Haut-parleur, Vibrations seules. Les trois couches et l'haptique juste
/// dessous, comme sur la maquette ; le niveau du grondement et le diagnostic
/// haptique vont dans les réglages avancés.
///
/// Sur un appareil qui ne vibre pas — un iPad —, tout ce qui touche à
/// l'haptique disparaît, et la feuille ne s'appelle plus que « Son ».
///
/// La feuille n'observe pas le moteur, qui publie son horloge soixante fois par
/// seconde : elle se redessine quand on touche un réglage, et enregistre le
/// mixage à chaque fois.
struct SoundSheet: View {

    let engine: WinchesterEngine
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @State private var showsAdvanced = false

    var body: some View {
        let _ = revision
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        presets
                        layers
                        haptics
                        advanced
                    }
                    .padding(16)
                }
            }
            .navigationTitle(SoundSheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.ok") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .tint(Theme.read)
    }

    // MARK: - Préréglages

    private var presets: some View {
        let current = engine.mix.preset
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(SoundMix.Preset.allCases.filter { !$0.needsHaptics || engine.supportsHaptics }) { preset in
                    presetButton(preset, selected: current == preset)
                }
            }
            Text(presetNote(current))
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetButton(_ preset: SoundMix.Preset, selected: Bool) -> some View {
        Button {
            apply(preset.mix)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon(preset))
                    .font(.dynamic(size: 20))
                Text(preset.label)
                    .font(.dynamic(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.background : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.read : Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.stroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(_ preset: SoundMix.Preset) -> String {
        switch preset {
        case .headphones:  return "headphones"
        case .speaker:     return "speaker.wave.2"
        case .hapticsOnly: return "iphone.radiowaves.left.and.right"
        }
    }

    private func presetNote(_ preset: SoundMix.Preset?) -> String {
        switch preset {
        case .headphones:
            return String(localized: "sound.preset.headphones.note",
                          defaultValue: "The original mix. On headphones, a short seek and a full stroke do not sound alike.")
        case .speaker:
            return engine.supportsHaptics
                ? String(localized: "sound.preset.speaker.note",
                         defaultValue: "The speaker erases the low end of the rotation: it rises, and the rumble moves into your hand.")
                : String(localized: "sound.preset.speaker.noHaptics.note",
                         defaultValue: "The speaker erases the low end of the rotation: it is turned up to make up for it.")
        case .hapticsOnly:
            return String(localized: "sound.preset.hapticsOnly.note",
                          defaultValue: "The sound is off; the pass carries on, and the arm is felt in your hand.")
        case nil:
            return String(localized: "sound.preset.custom.note", defaultValue: "Custom mix.")
        }
    }

    // MARK: - Couches

    private var layers: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("sound.section.sound")
            LevelSlider(label: "sound.level.rotation", value: binding(\.spindleLevel))
            LevelSlider(label: "sound.level.head", value: binding(\.transientLevel))
            LevelSlider(label: "sound.level.master", value: binding(\.masterLevel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder
    private var haptics: some View {
        if engine.supportsHaptics {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: binding(\.hapticsEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sound.haptics.title")
                            .font(.dynamic(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("sound.haptics.subtitle")
                            .font(.dynamic(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                }
                if engine.hapticsEnabled {
                    LevelSlider(label: "sound.level.transients", value: binding(\.hapticIntensity))
                    Toggle(isOn: binding(\.spindleHaptics)) {
                        Text("sound.haptics.spindle")
                            .font(.dynamic(size: 13))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    @ViewBuilder
    private var advanced: some View {
        if engine.supportsHaptics {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if engine.hapticsEnabled && engine.spindleHaptics {
                        LevelSlider(label: "sound.level.rumble", value: binding(\.spindleHapticLevel))
                    }
                    Text(verbatim: engine.hapticReport)
                        .font(.dynamic(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("sound.reset") { apply(.standard) }
                        .font(.dynamic(size: 13))
                }
                .padding(.top, 10)
            } label: {
                Text("sound.advanced")
                    .font(.dynamic(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .panel()
        }
    }

    /// La clé porte déjà les capitales : `uppercased()` suit la locale de
    /// l'appareil, pas celle du texte, et sur quelques alphabets il abîme.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.dim)
    }

    /// « Son et vibrations », ou « Son » sur un appareil qui ne vibre pas. La
    /// ligne des Réglages et le bouton de la Passe portent le même nom.
    static var title: String {
        DiskHaptics.isHardwareSupported
            ? String(localized: "settings.sound.title", defaultValue: "Sound and haptics")
            : String(localized: "settings.sound.title.noHaptics", defaultValue: "Sound")
    }

    // MARK: - Écriture

    private func apply(_ mix: SoundMix) {
        engine.mix = mix
        mix.save(to: .standard)
        revision += 1
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<WinchesterEngine, Value>) -> Binding<Value> {
        let engine = engine
        let revision = $revision
        return Binding(get: { engine[keyPath: keyPath] },
                       set: {
                           engine[keyPath: keyPath] = $0
                           engine.mix.save(to: .standard)
                           revision.wrappedValue += 1
                       })
    }
}

struct LevelSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(Format.percent(Double(value)))
                    .font(.dynamic(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
                .accessibilityLabel(label)
                .accessibilityValue(Format.percent(Double(value)))
        }
    }
}
