import SwiftUI
import DiskCore

/// Le son, l'accueil, et les fiches « Pourquoi ça sonne comme ça ? ».
///
/// Rien ici ne dépend de l'instant écouté : l'écran ne suit donc pas l'horloge
/// du moteur, qui le ferait redessiner soixante fois par seconde.
struct SettingsScreen: View {

    @ObservedObject var model: SimulationModel
    let engine: WinchesterEngine
    @State private var opened: Set<Explanation> = []
    @AppStorage(OnboardingView.seenKey) private var onboardingSeen = false
    @State private var showsSound = false
    /// Change quand la feuille « Son et vibrations » se ferme, pour relire le
    /// mixage qu'on y a laissé.
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle("settings.title",
                                subtitle: DiskHaptics.isHardwareSupported ? "settings.subtitle" : "settings.subtitle.noHaptics")
                    mixer
                    welcome
                    support
                    explanations
                }
                .padding(16)
            }
        }
        // La feuille fermée, la ligne relit le mixage qu'on y a laissé.
        .sheet(isPresented: $showsSound, onDismiss: { revision += 1 }) {
            SoundSheet(engine: engine)
        }
    }

    /// Le mixage se règle dans sa feuille ; la ligne dit seulement lequel est
    /// en place.
    private var mixer: some View {
        Button {
            showsSound = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.dynamic(size: 17))
                    .foregroundStyle(Theme.read)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SoundSheet.title)
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(engine.mix.preset?.label ?? String(localized: "settings.sound.custom", defaultValue: "Custom mix"))
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panel()
        }
        .buttonStyle(.plain)
    }

    /// La géométrie change d'un scénario à l'autre — et d'un disque généré à
    /// l'autre : la ligne la lit plutôt que de la réciter.
    private var geometryNote: String {
        let g = model.geometry
        let zones = String(localized: "settings.geometry.zones",
                           defaultValue: "\(g.zones.count) recording zones",
                           comment: "Nombre de zones d'enregistrement, au pluriel de la langue")
        let heads = String(localized: "settings.geometry.heads",
                           defaultValue: "\(g.heads) heads",
                           comment: "Nombre de têtes du disque, au pluriel de la langue")
        return String(localized: "settings.geometry",
                      defaultValue: "\(g.model): \(Format.integer(g.cylinders)) cylinders, \(heads), \(zones), \(Format.integer(Int(g.rpm))) rpm. Rotational latency and track changes are simulated sector by sector.",
                      comment: "Géométrie du disque en cours, sur l'écran Réglages")
    }

    /// Les fiches « Pourquoi ça sonne comme ça ? », toutes, par thème. Chacune
    /// est aussi derrière le ⓘ du chiffre qu'elle explique.
    private var explanations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.explanations.title")
                .font(.dynamic(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            ForEach(Explanation.groups, id: \.title) { group in
                Text(group.title.uppercased())
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .padding(.top, 4)
                ForEach(group.topics) { topic in
                    ExplanationRow(topic: topic, isOpen: opened.contains(topic)) {
                        if opened.contains(topic) { opened.remove(topic) } else { opened.insert(topic) }
                    }
                }
            }
            Text("settings.currentDisk")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(geometryNote)
                if model.defrag != nil || model.install != nil {
                    Text(model.label.volumeNote)
                }
            }
            .font(.dynamic(size: 13))
            .foregroundStyle(Theme.text.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    private var welcome: some View {
        Button {
            onboardingSeen = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.dynamic(size: 17))
                    .foregroundStyle(Theme.write)
                    .frame(width: 26)
                Text("settings.replayWelcome")
                    .font(.dynamic(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panel()
        }
        .buttonStyle(.plain)
    }

    /// La page Ko-fi s'ouvre dans le navigateur : l'app, elle, ne touche pas au
    /// réseau — `docs/privacy/` le dit, et cite ce libellé.
    private static let kofi = URL(string: "https://ko-fi.com/gabylandais")!

    private var support: some View {
        Link(destination: Self.kofi) {
            HStack(spacing: 12) {
                Image(systemName: "cup.and.saucer")
                    .font(.dynamic(size: 17))
                    .foregroundStyle(Theme.write)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.support.title")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("settings.support.note")
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .panel()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}
