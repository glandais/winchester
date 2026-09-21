import SwiftUI
import DiskCore
import Combine

/// Les quatre onglets des maquettes.
///
/// La barre d'onglets tient lieu de mini-lecteur : une passe ne s'arrête pas
/// quand on retourne choisir un disque, et l'onglet **Passe** la retrouve d'un
/// geste. Il n'y a qu'un moteur audio, donc qu'une passe à la fois.
enum AppTab: Hashable {
    case disks
    case pass
    case instruments
    case settings
}

struct ContentView: View {
    @StateObject private var model = SimulationModel()
    @StateObject private var library = DiskLibraryModel()
    @State private var tab: AppTab = .launch
    /// La pile de l'onglet Disques. Tenue ici parce que la Passe y pousse la
    /// fiche du disque qu'on écoute : son titre y mène (`UX_REVIEW.md` §2.4).
    @State private var disksPath: [String] = {
        #if SCREENSHOTS
        return ScreenshotMode.isActive ? ScreenshotMode.disksPath : []
        #else
        return []
        #endif
    }()
    @State private var nowPlaying: NowPlaying?
    @AppStorage(OnboardingView.seenKey) private var onboardingSeen = false
    /// Quand l'app est passée en arrière-plan, pour savoir au retour si l'absence
    /// a compté.
    @State private var backgroundedAt: Date?
    /// Le bandeau dit où en est la passe, jusqu'à ce qu'on l'ouvre.
    @State private var returnedFromBackground = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    /// En arrière-plan, aucun onglet n'est vu : la passe continue de sonner,
    /// mais aucun écran ne suit plus son horloge.
    private var isActive: Bool { scenePhase == .active }

    /// Ouvre la fiche d'un disque depuis n'importe où : bascule sur l'onglet
    /// Disques et pose la fiche au sommet de sa pile.
    ///
    /// C'est ce qui manquait à la Passe, dont le nom du disque était un titre
    /// mort : pour retrouver la fiche, il fallait deviner que l'onglet Disques
    /// avait gardé sa pile (`UX_REVIEW.md` §2.4).
    private func openDisk(_ id: String) {
        if disksPath.last != id { disksPath = [id] }
        tab = .disks
    }

    var body: some View {
        TabView(selection: $tab) {
            // Le bandeau est posé par l'écran lui-même, sur la racine de sa pile :
            // autour de la pile, il recouvrait le bas des écrans poussés.
            DisksScreen(model: model, library: library, path: $disksPath,
                        showsMiniPlayer: tab != .pass,
                        returnedFromBackground: returnedFromBackground) { tab = .pass }
                .tabItem { Label("tab.disks", systemImage: "internaldrive") }
                .tag(AppTab.disks)

            SimulatorScreen(model: model, engine: model.engine, isVisible: isActive && tab == .pass,
                            onOpenDisk: openDisk)
                .tabItem { Label("tab.pass", systemImage: "waveform") }
                .tag(AppTab.pass)

            InstrumentsScreen(model: model, engine: model.engine, isVisible: isActive && tab == .instruments)
                .passMiniPlayer(model: model, isShown: tab != .pass, returned: returnedFromBackground) { tab = .pass }
                .tabItem { Label("tab.instruments", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(AppTab.instruments)

            SettingsScreen(model: model, engine: model.engine)
                .passMiniPlayer(model: model, isShown: tab != .pass, returned: returnedFromBackground) { tab = .pass }
                .tabItem { Label("tab.settings", systemImage: "slider.horizontal.3") }
                .tag(AppTab.settings)
        }
        // `Font.dynamic` lit la taille de texte au moment du dessin : quand elle
        // change, les écrans sont refaits. Les modèles, eux, vivent au-dessus.
        .id(typeSize)
        .dynamicTypeSize(...TypeScale.largestDynamicTypeSize)
        .toolbarBackground(Theme.panel, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .tint(Theme.read)
        .onAppear {
            if nowPlaying == nil { nowPlaying = NowPlaying(model: model) }
        }
        #if SCREENSHOTS
        .task { if ScreenshotMode.isActive { await ScreenshotMode.stage(model, library: library) } }
        #endif
        // L'accueil ne se montre qu'une fois ; il se referme sur les disques,
        // où sont les deux démos prêtes à écouter.
        .fullScreenCover(isPresented: Binding(get: { !onboardingSeen }, set: { onboardingSeen = !$0 })) {
            OnboardingView(engine: model.engine) {
                tab = .disks
                onboardingSeen = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.engine.suspendIfIdle()
                backgroundedAt = Date()
            case .active:
                // Un aller-retour éclair — le centre de contrôle, une
                // notification — ne vaut pas qu'on le signale.
                if let since = backgroundedAt, Date().timeIntervalSince(since) > 5,
                   model.engine.currentTime > 0 {
                    returnedFromBackground = true
                }
                backgroundedAt = nil
            default:
                break
            }
        }
        .onChange(of: tab) { _, shown in
            if shown == .pass { returnedFromBackground = false }
        }
    }
}

// MARK: - Relais d'horloge

/// Transmet à un écran les changements du moteur — son horloge d'abord, soixante
/// fois par seconde —, tant qu'on ne lui demande pas de se taire.
///
/// `@ObservedObject` ne sait pas cesser d'observer : un écran recouvert par un
/// plein écran reste abonné, et SwiftUI recalcule son corps à chaque image même
/// si rien n'en est visible. Le relais est ce qu'on peut couper.
@MainActor
final class ClockRelay: ObservableObject {

    let engine: WinchesterEngine

    /// Coupé, plus rien ne passe. Rouvert, un seul changement est envoyé, pour
    /// que l'écran rattrape d'un coup l'état qu'il a manqué.
    var isRelaying = true {
        didSet { if isRelaying && !oldValue { objectWillChange.send() } }
    }

    private var subscription: AnyCancellable?

    init(engine: WinchesterEngine) {
        self.engine = engine
        subscription = engine.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRelaying else { return }
                self.objectWillChange.send()
            }
        }
    }
}

// MARK: - Petits composants

struct StatTile: View {
    let label: String
    let value: String
    let unit: String
    /// La fiche qui explique ce chiffre, derrière un ⓘ.
    let why: Explanation?

    init(label: String, value: String, unit: String, why: Explanation? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.why = why
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if let why {
                    Spacer(minLength: 0)
                    WhyButton(topic: why, context: "\(label) · \(value) \(unit)")
                        .padding(-6)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.dynamic(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(unit)
                    .font(.dynamic(size: 10))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
    }
}
