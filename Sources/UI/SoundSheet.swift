import SwiftUI

/// La feuille « Son et vibrations » — maquette 15.
///
/// Trois préréglages d'abord, pour qui ne veut pas régler : Casque,
/// Haut-parleur, Vibrations seules. Les trois couches et l'haptique juste
/// dessous, comme sur la maquette ; le niveau du grondement et le diagnostic
/// haptique vont dans les réglages avancés.
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
            .navigationTitle("Son et vibrations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
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
                ForEach(SoundMix.Preset.allCases) { preset in
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
        let unavailable = preset.needsHaptics && !engine.supportsHaptics
        return Button {
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
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(unavailable ? "Indisponible : cet appareil ne vibre pas" : "")
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
            return "Le mixage d'origine. Au casque, un seek court et une pleine course ne sonnent pas pareil."
        case .speaker:
            return "Le haut-parleur efface le grave de la rotation : elle monte, et le grondement passe dans la main."
        case .hapticsOnly:
            return "Le son est coupé ; la passe continue, et le bras se sent dans la main."
        case nil:
            return engine.supportsHaptics
                ? "Réglage personnel."
                : "Réglage personnel. Cet appareil ne vibre pas : « Vibrations seules » est indisponible."
        }
    }

    // MARK: - Couches

    private var layers: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Son")
            LevelSlider(label: "Rotation", value: binding(\.spindleLevel))
            LevelSlider(label: "Tête", value: binding(\.transientLevel))
            LevelSlider(label: "Général", value: binding(\.masterLevel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var haptics: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.supportsHaptics {
                Toggle(isOn: binding(\.hapticsEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haptique")
                            .font(.dynamic(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Taptic Engine · transitoires du bras")
                            .font(.dynamic(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                }
                if engine.hapticsEnabled {
                    LevelSlider(label: "Intensité des transitoires", value: binding(\.hapticIntensity))
                    Toggle(isOn: binding(\.spindleHaptics)) {
                        Text("Grondement de rotation")
                            .font(.dynamic(size: 13))
                            .foregroundStyle(Theme.text)
                    }
                }
            } else {
                sectionTitle("Haptique")
                Text("Indisponible sur cet appareil : il n'a pas de Taptic Engine que l'app puisse piloter. "
                     + "Le son n'en dépend pas.")
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder
    private var advanced: some View {
        if engine.supportsHaptics {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if engine.hapticsEnabled && engine.spindleHaptics {
                        LevelSlider(label: "Niveau du grondement", value: binding(\.spindleHapticLevel))
                    }
                    Text(engine.hapticReport)
                        .font(.dynamic(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Revenir au mixage d'origine") { apply(.standard) }
                        .font(.dynamic(size: 13))
                }
                .padding(.top, 10)
            } label: {
                Text("Réglages avancés")
                    .font(.dynamic(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .panel()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.dim)
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
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(FrenchFormat.percent(Double(value)))
                    .font(.dynamic(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
                .accessibilityLabel(label)
                .accessibilityValue(FrenchFormat.percent(Double(value)))
        }
    }
}
