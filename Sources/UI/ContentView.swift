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
    @State private var tab: AppTab = .disks
    @State private var nowPlaying: NowPlaying?
    @Environment(\.scenePhase) private var scenePhase

    /// En arrière-plan, aucun onglet n'est vu : la passe continue de sonner,
    /// mais aucun écran ne suit plus son horloge.
    private var isActive: Bool { scenePhase == .active }

    var body: some View {
        TabView(selection: $tab) {
            // Le bandeau est posé par l'écran lui-même, sur la racine de sa pile :
            // autour de la pile, il recouvrait le bas des écrans poussés.
            DisksScreen(model: model, library: library, showsMiniPlayer: tab != .pass) { tab = .pass }
                .tabItem { Label("Disques", systemImage: "internaldrive") }
                .tag(AppTab.disks)

            SimulatorScreen(model: model, engine: model.engine, isVisible: isActive && tab == .pass)
                .tabItem { Label("Passe", systemImage: "waveform") }
                .tag(AppTab.pass)

            InstrumentsScreen(model: model, engine: model.engine, isVisible: isActive && tab == .instruments)
                .passMiniPlayer(model: model, isShown: tab != .pass) { tab = .pass }
                .tabItem { Label("Instruments", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(AppTab.instruments)

            SettingsScreen(model: model, engine: model.engine)
                .passMiniPlayer(model: model, isShown: tab != .pass) { tab = .pass }
                .tabItem { Label("Réglages", systemImage: "slider.horizontal.3") }
                .tag(AppTab.settings)
        }
        .toolbarBackground(Theme.panel, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .tint(Theme.read)
        .onAppear {
            if nowPlaying == nil { nowPlaying = NowPlaying(model: model) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.engine.suspendIfIdle() }
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

    let engine: DiskNoiseEngine

    /// Coupé, plus rien ne passe. Rouvert, un seul changement est envoyé, pour
    /// que l'écran rattrape d'un coup l'état qu'il a manqué.
    var isRelaying = true {
        didSet { if isRelaying && !oldValue { objectWillChange.send() } }
    }

    private var subscription: AnyCancellable?

    init(engine: DiskNoiseEngine) {
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

    init(label: String, value: String, unit: String) {
        self.label = label
        self.value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
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
