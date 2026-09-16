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

    var body: some View {
        TabView(selection: $tab) {
            DisksScreen(model: model, library: library) { tab = .pass }
                .passMiniPlayer(model: model, isShown: tab != .pass) { tab = .pass }
                .tabItem { Label("Disques", systemImage: "internaldrive") }
                .tag(AppTab.disks)

            SimulatorScreen(model: model, engine: model.engine, isVisible: tab == .pass)
                .tabItem { Label("Passe", systemImage: "waveform") }
                .tag(AppTab.pass)

            InstrumentsScreen(model: model, engine: model.engine, isVisible: tab == .instruments)
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
    }
}

/// Le moteur publie sa propre horloge : l'écran la suit au travers d'un relais,
/// sinon il ne se rafraîchit pas pendant la lecture.
struct SimulatorScreen: View {

    @ObservedObject var model: SimulationModel
    @StateObject private var clock: ClockRelay
    @State private var showsFullScreenMap = false

    /// Un onglet caché reste en vie : sans cela, il suivrait l'horloge soixante
    /// fois par seconde sans que personne le voie.
    let isVisible: Bool

    init(model: SimulationModel, engine: DiskNoiseEngine, isVisible: Bool) {
        _model = ObservedObject(wrappedValue: model)
        _clock = StateObject(wrappedValue: ClockRelay(engine: engine))
        self.isVisible = isVisible
    }

    private var engine: DiskNoiseEngine { clock.engine }

    private var time: Double { engine.currentTime }
    /// Une seule interrogation de la trace par image, partagée par le plateau et
    /// par l'afficheur de cylindre.
    private var platter: PlatterFrame { model.platterFrame(at: time) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    if model.defrag != nil { defragPanel }
                    if let boot = model.boot { bootPanel(boot) }
                    PlatterView(track: model.platter, frame: platter)
                        .frame(maxHeight: 300)
                        .panel()

                    phaseBanner
                    timeline
                    transport
                }
                .padding(16)
            }
        }
        .tint(Theme.read)
        .onAppear { clock.isRelaying = isVisible && !showsFullScreenMap }
        .onChange(of: isVisible) { _, visible in
            clock.isRelaying = visible && !showsFullScreenMap
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DiskNoise")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(model.label.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            activityLED
        }
    }

    /// Carte du volume, rejouée sur l'horloge du moteur audio : ce sont les
    /// mêmes dates que celles des repères sonores, donc l'écriture d'un bloc se
    /// voit exactement quand elle s'entend.
    @ViewBuilder
    private var defragPanel: some View {
        if let playback = model.defrag {
            let active = model.activeCell()
            let before = playback.before
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Volume C:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(playback.partition.capacityDescription) · \(playback.partition.format.label) · clusters de \(playback.partition.clusterBytes / 1024) Ko")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    // Le plein écran est à côté du titre du volume, là où l'œil
                    // passe déjà, plutôt qu'en surimpression sur la carte où il
                    // masquerait des blocs.
                    FullScreenMapButton { showsFullScreenMap = true }
                }

                // L'outil qu'on écoute. Sans lui, deux passes aux signatures
                // sonores opposées s'annoncent de la même façon, et le seul
                // indice de ce qui a changé est un compteur.
                Text(playback.strategy.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)

                ClusterMapView(grid: model.mapGrid,
                               shades: model.clusterShades(at: time),
                               activeCell: active?.cell,
                               activeIsWrite: active?.isWrite ?? false)
                    // La carte entière ouvre le plein écran : c'est le geste
                    // qu'on essaie d'abord, et il ne coûte rien de le servir.
                    .contentShape(Rectangle())
                    .onTapGesture { showsFullScreenMap = true }

                progressBar()

                ClusterLegend(categories: presentCategories(in: playback),
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: playback.partition.clusterBytes)

                // L'arrivée n'est connue qu'une fois la passe entendue jusqu'au
                // bout : elle se calcule pendant qu'on l'écoute.
                let plan = model.end?.plan
                Text(String(format: "Au départ : %d fichiers, %d fragmentés (%.0f %%), %.2f extents par fichier, %d trous dans l'espace libre.",
                            before.fileCount, before.fragmentedFiles,
                            before.fragmentedRatio * 100, before.extentsPerFile,
                            before.freeHoles)
                     + (plan.map { String(format: " À l'arrivée : %d fragmentés, %d trous.",
                                          $0.after.fragmentedFiles, $0.after.freeHoles) } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                // C'est la stratégie qui commente ses propres compteurs : les
                // mêmes nombres ne disent pas la même chose d'un outil à
                // l'autre.
                if let plan {
                    Text(plan.strategy.summary(of: plan))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .fullScreenCover(isPresented: $showsFullScreenMap) {
                DefragFullScreenMap(model: model, engine: engine)
            }
            // Recouvert, cet écran ne suit plus l'horloge : il se redessinait
            // sinon soixante fois par seconde sous le plein écran — carte,
            // plateau et bandeau que personne ne voit —, et doublait le coût de
            // la lecture. Il se remet à l'heure dès que le plein écran se ferme.
            .onChange(of: showsFullScreenMap) { _, covered in
                clock.isRelaying = isVisible && !covered
            }
        }
    }

    /// L'avancement tel que l'outil l'annonçait. Il n'y a plus de total à
    /// afficher : on ne sait ce qu'une passe déplacera qu'une fois déplacé.
    private func progressBar() -> some View {
        let progress = model.defragProgress ?? 0
        let moved = model.movedBytes / 1_000_000
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.read)
                        .frame(width: max(proxy.size.width * CGFloat(progress), 2))
                }
            }
            .frame(height: 5)
            HStack {
                Text(String(format: "%.0f %%", progress * 100))
                Spacer()
                Text(String(format: "%.0f Mo déplacés", moved))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
    }

    /// Le fichier d'échange et les répertoires ne pèsent que quelques blocs :
    /// inutile de leur réserver une entrée de légende s'ils sont absents.
    private func presentCategories(in playback: DefragPlayback) -> [ClusterCategory] {
        var seen = Set<UInt8>(playback.initialRuns.lazy.map(\.category))
        seen.insert(ClusterCategory.free.rawValue)
        return ClusterCategory.allCases.filter { seen.contains($0.rawValue) }
    }

    private var activityLED: some View {
        let on = model.activityLED
        return VStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.read : Color.white.opacity(0.10))
                .frame(width: 13, height: 13)
                .shadow(color: on ? Theme.read.opacity(0.9) : .clear, radius: 7)
            Text("HDD")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }

    private var phaseBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.phaseColor(model.phaseIndex))
                    .frame(width: 9, height: 9)
                Text(model.phase?.label ?? "—")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.geometry.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Text(model.phase?.detail ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Le bilan d'un démarrage. Il n'y a pas de carte à montrer — un démarrage
    /// ne déplace rien — mais il y a une chose à dire : ce que ce volume-là
    /// coûte par rapport au même contenu jamais fragmenté.
    private func bootPanel(_ boot: BootPlayback) -> some View {
        // Ce que le disque a coûté ne se sait qu'à la fin du démarrage.
        let duration = model.end?.duration
        let disk = duration.map { String(format: "%.0f", boot.diskSeconds(duration: $0)) } ?? "…"
        let penalty = duration.map { boot.freshSeconds > 0
            ? String(format: "%+.0f %%", ($0 / boot.freshSeconds - 1) * 100)
            : "" } ?? "à venir"
        return VStack(alignment: .leading, spacing: 10) {
            Text(boot.appName.map { "\(boot.osName), puis \($0)" } ?? boot.osName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)

            FlowRow(spacing: 10) {
                StatTile(label: "Fichiers lus", value: "\(boot.filesRead)",
                         unit: boot.residentFiles > 0 ? "\(boot.residentFiles) résidents" : "ouverts")
                StatTile(label: "Calcul", value: String(format: "%.0f", boot.thinkSeconds), unit: "s")
                StatTile(label: "Disque", value: disk, unit: "s d'attente")
                StatTile(label: "Jamais fragmenté",
                         value: String(format: "%.0f", boot.freshSeconds),
                         unit: penalty)
            }

            Text("Le témoin lit exactement les mêmes fichiers, d'un seul tenant chacun et "
                 + "rangés dans l'ordre du répertoire. L'écart dit ce que ce volume-ci fait "
                 + "payer à son démarrage — ou ce qu'il lui fait gagner, quand son "
                 + "allocateur place mieux qu'un empilement.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            ActivityTimeline(
                marks: model.live.phaseMarks,
                buckets: model.live.buckets,
                now: time,
                window: LivePass.activityWindow
            )
            HStack {
                Text("−1 min")
                Spacer()
                Text(model.totals.requests > 0 ? "\(model.totals.requests) requêtes" : "")
                Spacer()
                Text(time.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    private var transport: some View {
        HStack(spacing: 22) {
            // Revenir au début, c'est relancer la passe : il n'y a plus de
            // chronologie où sauter.
            Button {
                model.restart()
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 19))
            }
            .accessibilityLabel("Relancer la passe")

            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying || engine.isBuffering
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.hierarchical)
            }

            if engine.isBuffering {
                ProgressView()
                    .tint(Theme.dim)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("cylindre")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("\(Int(platter.cylinder.rounded()))")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.text)
        .panel()
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
