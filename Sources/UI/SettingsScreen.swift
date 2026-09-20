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
                    ScreenTitle("Réglages", subtitle: "Son, vibrations, et pourquoi ça sonne comme ça")
                    mixer
                    welcome
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
                    Text("Son et vibrations")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(engine.mix.preset?.label ?? "Réglage personnel")
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
        return "\(g.model) : \(FrenchFormat.integer(g.cylinders)) cylindres, \(g.heads) têtes, \(g.zones.count) "
            + "zone\(g.zones.count > 1 ? "s" : "") d'enregistrement, \(FrenchFormat.integer(Int(g.rpm))) tr/min. "
            + "La latence de rotation et les changements de piste sont simulés secteur par secteur."
    }

    /// Les fiches « Pourquoi ça sonne comme ça ? », toutes, par thème. Chacune
    /// est aussi derrière le ⓘ du chiffre qu'elle explique.
    private var explanations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pourquoi ça sonne comme ça ?")
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
            Text("LE DISQUE EN COURS")
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
                Text("Revoir l'accueil")
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
}
