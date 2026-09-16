import SwiftUI
import DiskCore

/// La passe en cours — maquettes 09 et 10.
///
/// Rien d'autre que le présent : la phase, le temps écouté, l'avancement que
/// l'outil annonce, et deux façons de regarder — la carte du volume, ou le
/// plateau. Pas de barre de lecture ni de durée totale : la passe se calcule
/// pendant qu'on l'écoute.
///
/// Le moteur publie sa propre horloge : l'écran la suit au travers d'un relais,
/// coupé quand l'onglet est caché ou recouvert par le plein écran.
struct SimulatorScreen: View {

    enum View_: Hashable { case map, platter }

    @ObservedObject var model: SimulationModel
    @StateObject private var clock: ClockRelay
    @State private var showsFullScreenMap = false
    @State private var view: View_ = .map

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

    /// Une passe de démarrage n'a pas de carte : seul le plateau se montre.
    private var shownView: View_ { model.defrag == nil ? .platter : view }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.defrag != nil {
                        Picker("Vue", selection: $view) {
                            Text("Carte").tag(View_.map)
                            Text("Plateau").tag(View_.platter)
                        }
                        .pickerStyle(.segmented)
                    }
                    switch shownView {
                    case .map:
                        if let playback = model.defrag {
                            mapPanel(playback)
                            defragCounters(playback)
                        }
                    case .platter:
                        platterPanel
                        if let boot = model.boot { bootPanel(boot) }
                        phasesPanel
                        timeline
                    }
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { transport }
        .tint(Theme.read)
        .fullScreenCover(isPresented: $showsFullScreenMap) {
            DefragFullScreenMap(model: model, engine: engine)
        }
        .onAppear { clock.isRelaying = isVisible && !showsFullScreenMap }
        .onChange(of: isVisible) { _, visible in
            clock.isRelaying = visible && !showsFullScreenMap
        }
        // Recouvert, cet écran ne suit plus l'horloge : il se redessinait
        // sinon soixante fois par seconde sous le plein écran. Il se remet à
        // l'heure dès que le plein écran se ferme.
        .onChange(of: showsFullScreenMap) { _, covered in
            clock.isRelaying = isVisible && !covered
        }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(model.defrag?.strategy.label ?? model.boot.map(bootTitle) ?? model.geometry.model)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                activityLED
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PHASE \(model.phaseIndex + 1) · \((model.phase?.label ?? "—").uppercased())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.read)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.phase?.detail ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if model.defrag != nil {
                        Text(FrenchFormat.percent(model.defragProgress ?? 0))
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.read)
                            .monospacedDigit()
                    }
                    Text(FrenchFormat.duration(time))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .monospacedDigit()
                }
            }
            if model.defrag != nil {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Theme.read)
                            .frame(width: max(proxy.size.width * CGFloat(model.defragProgress ?? 0), 2))
                    }
                }
                .frame(height: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func bootTitle(_ boot: BootPlayback) -> String {
        boot.appName.map { "\(boot.osName), puis \($0)" } ?? boot.osName
    }

    private var activityLED: some View {
        let on = model.activityLED
        return VStack(spacing: 3) {
            Circle()
                .fill(on ? Theme.read : Color.white.opacity(0.10))
                .frame(width: 11, height: 11)
                .shadow(color: on ? Theme.read.opacity(0.9) : .clear, radius: 6)
            Text("HDD")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(on ? "Disque actif" : "Disque au repos")
    }

    // MARK: - Carte

    /// Carte du volume, rejouée sur l'horloge du moteur audio : ce sont les
    /// mêmes dates que celles des repères sonores, donc l'écriture d'un bloc se
    /// voit exactement quand elle s'entend.
    private func mapPanel(_ playback: DefragPlayback) -> some View {
        let active = model.activeCell()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendDot(Theme.read, "lecture")
                legendDot(Theme.write, "écriture")
                Spacer()
                Text("\(playback.partition.capacityDescription) · \(playback.partition.format.label)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                FullScreenMapButton { showsFullScreenMap = true }
            }
            ClusterMapView(grid: model.mapGrid,
                           shades: model.clusterShades(at: time),
                           activeCell: active?.cell,
                           activeIsWrite: active?.isWrite ?? false)
                // La carte entière ouvre le plein écran : c'est le geste
                // qu'on essaie d'abord, et il ne coûte rien de le servir.
                .contentShape(Rectangle())
                .onTapGesture { showsFullScreenMap = true }
            ClusterLegend(categories: presentCategories(in: playback),
                          clustersPerCell: model.clustersPerCell,
                          clusterBytes: playback.partition.clusterBytes)
        }
        .panel()
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
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

    /// Ce qui se compte pendant la passe, et ce qui ne se sait qu'à la fin.
    ///
    /// Les fichiers déplacés et les évacuations sont comptés par la stratégie,
    /// qui ne les publie qu'avec son plan : ils s'affichent une fois la passe
    /// entendue jusqu'au bout.
    private func defragCounters(_ playback: DefragPlayback) -> some View {
        let plan = model.end?.plan
        let before = playback.before
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                StatTile(label: "Mo déplacés",
                         value: FrenchFormat.integer(Int(model.movedBytes / 1_000_000)),
                         unit: "jusqu'ici")
                StatTile(label: "Seek moyen",
                         value: FrenchFormat.integer(model.totals.averageSeekDistance),
                         unit: "cyl.")
                StatTile(label: "Fichiers déplacés",
                         value: plan.map { FrenchFormat.integer($0.filesMoved) } ?? "—",
                         unit: plan == nil ? "au bilan" : "au total")
                StatTile(label: "Évacuations",
                         value: plan.map { FrenchFormat.integer($0.evacuations) } ?? "—",
                         unit: plan == nil ? "au bilan" : "au total")
            }
            Text("Au départ : \(FrenchFormat.integer(before.fileCount)) fichiers, "
                 + "\(FrenchFormat.percent(before.fragmentedRatio)) fragmentés, "
                 + "\(FrenchFormat.integer(before.freeHoles)) trous dans l'espace libre."
                 + (plan.map { " À l'arrivée : \(FrenchFormat.integer($0.after.fragmentedFiles)) fichiers fragmentés, "
                     + "\(FrenchFormat.integer($0.after.freeHoles)) trous." } ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            // C'est la stratégie qui commente ses propres compteurs : les mêmes
            // nombres ne disent pas la même chose d'un outil à l'autre.
            if let plan {
                Text(plan.strategy.summary(of: plan))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .panel()
            }
        }
    }

    // MARK: - Plateau

    private var platterPanel: some View {
        let frame = model.platterFrame(at: time)
        return VStack(spacing: 8) {
            PlatterView(track: model.platter, frame: frame)
                .frame(maxHeight: 300)
            HStack(alignment: .firstTextBaseline) {
                Text("CYLINDRE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("\(FrenchFormat.integer(Int(frame.cylinder.rounded()))) / \(FrenchFormat.integer(model.geometry.cylinders))")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .monospacedDigit()
                Spacer()
                Text(model.geometry.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .panel()
    }

    /// Les phases écoutées et le temps passé dans chacune, reprises
    /// comprises. Aucune phase à venir : on ne sait pas combien de temps elles
    /// prendront.
    private var phasesPanel: some View {
        let current = model.phaseIndex
        return VStack(alignment: .leading, spacing: 8) {
            Text("PHASES ÉCOUTÉES")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            if model.phaseTimes.isEmpty {
                Text("Rien encore.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(model.phaseTimes, id: \.index) { entry in
                HStack {
                    Circle()
                        .fill(Theme.phaseColor(entry.index))
                        .frame(width: 8, height: 8)
                    Text(model.phases.indices.contains(entry.index) ? model.phases[entry.index].label : "—")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(entry.index == current ? "en cours · \(FrenchFormat.duration(entry.seconds))"
                                                : FrenchFormat.duration(entry.seconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(entry.index == current ? Theme.read : Theme.dim)
                        .monospacedDigit()
                }
            }
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
                Text("\(FrenchFormat.integer(model.totals.requests)) requêtes")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    /// Le bilan d'un démarrage. Il n'y a pas de carte à montrer — un démarrage
    /// ne déplace rien — mais il y a une chose à dire : ce que ce volume-là
    /// coûte par rapport au même contenu jamais fragmenté.
    private func bootPanel(_ boot: BootPlayback) -> some View {
        // Ce que le disque a coûté ne se sait qu'à la fin du démarrage.
        let duration = model.end?.duration
        let disk = duration.map { FrenchFormat.decimal(boot.diskSeconds(duration: $0), digits: 0) } ?? "…"
        let penalty = duration.map { boot.freshSeconds > 0
            ? String(format: "%+.0f %%", ($0 / boot.freshSeconds - 1) * 100)
            : "" } ?? "à venir"
        return VStack(alignment: .leading, spacing: 10) {
            FlowRow(spacing: 10) {
                StatTile(label: "Fichiers lus", value: FrenchFormat.integer(boot.filesRead),
                         unit: boot.residentFiles > 0 ? "\(boot.residentFiles) résidents" : "ouverts")
                StatTile(label: "Calcul", value: FrenchFormat.decimal(boot.thinkSeconds, digits: 0), unit: "s")
                StatTile(label: "Disque", value: disk, unit: "s d'attente")
                StatTile(label: "Jamais fragmenté",
                         value: FrenchFormat.decimal(boot.freshSeconds, digits: 0),
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

    // MARK: - Transport

    /// Arrêter, lire ou mettre en pause, relancer. Rien d'autre : il n'y a
    /// pas de chronologie où sauter, et revenir au début, c'est relancer.
    private var transport: some View {
        let playing = engine.isPlaying || engine.isBuffering
        return HStack(spacing: 0) {
            transportButton("Arrêter", systemImage: "stop.fill", size: 18) {
                // Arrêter, c'est revenir au début sans rejouer.
                engine.pause()
                model.restart()
            }
            .disabled(time == 0 && !playing)

            Spacer()

            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                ZStack {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 54))
                        .symbolRenderingMode(.hierarchical)
                    if engine.isBuffering {
                        ProgressView().tint(Theme.text)
                    }
                }
            }
            .accessibilityLabel(playing ? "Pause" : "Lecture")

            Spacer()

            transportButton("Relancer", systemImage: "arrow.counterclockwise", size: 18) {
                model.restart()
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(
            Theme.background
                .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
                .ignoresSafeArea(edges: .horizontal)
        )
    }

    private func transportButton(_ title: String, systemImage: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: size, weight: .semibold))
                    .frame(width: 44, height: 30)
                Text(title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
        .accessibilityLabel(title)
    }
}
