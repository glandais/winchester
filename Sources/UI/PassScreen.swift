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
    @State private var report: PassRecord?
    @State private var showsSound = false
    @State private var showsAmbient = false

    /// Un onglet caché reste en vie : sans cela, il suivrait l'horloge soixante
    /// fois par seconde sans que personne le voie.
    let isVisible: Bool

    init(model: SimulationModel, engine: WinchesterEngine, isVisible: Bool) {
        _model = ObservedObject(wrappedValue: model)
        _clock = StateObject(wrappedValue: ClockRelay(engine: engine))
        self.isVisible = isVisible
    }

    private var engine: WinchesterEngine { clock.engine }
    private var time: Double { engine.currentTime }

    /// Un plein écran le recouvre : la carte, ou le mode ambiance.
    private var isCovered: Bool { showsFullScreenMap || showsAmbient }

    /// Une passe de démarrage n'a pas de carte : seul le plateau se montre.
    private var shownView: View_ { model.mapSource == nil ? .platter : view }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let interruption = engine.interruption {
                        interruptionCard(interruption)
                    }
                    if let record = model.currentRecord, record.kind != .boot {
                        finishedCard(record)
                    }
                    if model.mapSource != nil {
                        Picker("Vue", selection: $view) {
                            Text("Carte").tag(View_.map)
                            Text("Plateau").tag(View_.platter)
                        }
                        .pickerStyle(.segmented)
                    }
                    switch shownView {
                    case .map:
                        if let source = model.mapSource {
                            mapPanel(partition: source.partition, initialRuns: source.initialRuns)
                        }
                        if let playback = model.defrag {
                            defragCounters(playback)
                        } else if let install = model.install {
                            installCounters(install)
                        } else if let day = model.dayPlayback {
                            dayCounters(day)
                        }
                    case .platter:
                        platterPanel
                        phasesPanel
                        if let boot = model.boot {
                            bootTiles(boot)
                            witnessPanel(boot)
                        }
                        timeline
                    }
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { transport }
        .sheet(item: $report) { record in
            PassReportSheet(model: model, record: record, onLaunched: { view = .map })
        }
        .tint(Theme.read)
        .fullScreenCover(isPresented: $showsFullScreenMap) {
            DefragFullScreenMap(model: model, engine: engine)
        }
        .sheet(isPresented: $showsSound) { SoundSheet(engine: engine) }
        .fullScreenCover(isPresented: $showsAmbient) { AmbientScreen(model: model) }
        .onAppear { clock.isRelaying = isVisible && !isCovered }
        .onChange(of: isVisible) { _, visible in
            clock.isRelaying = visible && !isCovered
        }
        // Recouvert, cet écran ne suit plus l'horloge : il se redessinait
        // sinon soixante fois par seconde sous le plein écran. Il se remet à
        // l'heure dès que le plein écran se ferme.
        .onChange(of: isCovered) { _, covered in
            clock.isRelaying = isVisible && !covered
        }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label.title)
                        .font(.dynamic(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(model.defrag?.strategy.label ?? model.install.map(installTitle)
                         ?? model.dayPlayback.map(dayTitle) ?? model.boot.map(bootTitle)
                         ?? model.geometry.model)
                        .font(.dynamic(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                headerButton("speaker.wave.2", label: "Son et vibrations") { showsSound = true }
                headerButton("moon.stars", label: "Mode ambiance") { showsAmbient = true }
                activityLED
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PHASE \(model.phaseIndex + 1) · \((model.phase?.label ?? "—").uppercased())")
                        .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.read)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.phase?.detail ?? "")
                        .font(.dynamic(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if model.mapSource != nil {
                        Text(FrenchFormat.percent(model.defragProgress ?? 0))
                            .font(.dynamic(size: 24, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.read)
                            .monospacedDigit()
                    }
                    Text(FrenchFormat.duration(time))
                        .font(.dynamic(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .monospacedDigit()
                }
            }
            if model.mapSource != nil {
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

    /// La lecture s'est arrêtée sans qu'on le demande : on dit pourquoi, et où.
    private func interruptionCard(_ interruption: PlaybackInterruption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.dynamic(size: 20))
                .foregroundStyle(Theme.read)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Passe interrompue à \(FrenchFormat.duration(interruption.time))")
                    .font(.dynamic(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Cause : \(interruption.label). Elle reprend où elle s'est arrêtée.")
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Reprendre") { engine.play() }
                .font(.dynamic(size: 13, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.background)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .contain)
    }

    /// La passe est entendue jusqu'au bout : son bilan est prêt.
    private func finishedCard(_ record: PassRecord) -> some View {
        Button {
            report = record
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.dynamic(size: 20))
                    .foregroundStyle(Theme.read)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passe terminée")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(record.kind == .install ? "Le disque posé, et son premier démarrage"
                                                 : "Avant → après, un autre outil, le disque rangé")
                        .font(.dynamic(size: 11))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Text("Voir le bilan")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.read))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
        .buttonStyle(.plain)
    }

    private func headerButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.dynamic(size: 15))
                .foregroundStyle(Theme.text.opacity(0.8))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .accessibilityLabel(label)
    }

    private func installTitle(_ install: InstallPlayback) -> String {
        "Installation depuis \(install.medium)"
    }

    private func dayTitle(_ day: DayPlayback) -> String {
        day.activities.isEmpty ? "Journée sans activité"
            : day.activities.map(\.label).joined(separator: ", ")
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
                .font(.dynamic(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(on ? "Disque actif" : "Disque au repos")
    }

    // MARK: - Carte

    /// Carte du volume, rejouée sur l'horloge du moteur audio : ce sont les
    /// mêmes dates que celles des repères sonores, donc l'écriture d'un bloc se
    /// voit exactement quand elle s'entend.
    private func mapPanel(partition: PartitionGeometry, initialRuns: [MapRun]) -> some View {
        let active = model.activeCell()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                legendDot(Theme.read, "lecture")
                legendDot(Theme.write, "écriture")
                Spacer()
                Text("\(partition.capacityDescription) · \(partition.format.label)")
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
            ClusterLegend(categories: presentCategories(in: initialRuns),
                          clustersPerCell: model.clustersPerCell,
                          clusterBytes: partition.clusterBytes)
        }
        .panel()
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(.dynamic(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Le fichier d'échange et les répertoires ne pèsent que quelques blocs :
    /// inutile de leur réserver une entrée de légende s'ils sont absents.
    private func presentCategories(in initialRuns: [MapRun]) -> [ClusterCategory] {
        var seen = Set<UInt8>(initialRuns.lazy.map(\.category))
        seen.insert(ClusterCategory.free.rawValue)
        // Une installation part d'un volume vierge : ce qu'elle posera ne se
        // voit pas au départ, mais c'est ce que la légende doit nommer.
        if let install = model.install {
            seen.formUnion(install.installed.catalog.files.lazy.map { ClusterCategory($0.category).rawValue })
            if install.temporaryFiles > 0 { seen.insert(ClusterCategory.churn.rawValue) }
            if install.installed.catalog.directories.contains(where: { !$0.extents.isEmpty }) {
                seen.insert(ClusterCategory.directory.rawValue)
            }
        }
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
                // « jusqu'ici » ne se dit que tant que la passe court : une
                // fois le plan rendu, le compteur est définitif.
                StatTile(label: "Déplacé",
                         value: FrenchFormat.megabytes(UInt64(max(model.movedBytes, 0))),
                         unit: plan == nil ? "jusqu'ici" : "en tout")
                StatTile(label: "Seek moyen",
                         value: FrenchFormat.integer(model.totals.averageSeekDistance),
                         unit: "cyl.", why: .seekLaw)
                StatTile(label: "Fichiers déplacés",
                         value: plan.map { FrenchFormat.integer($0.filesMoved) } ?? "—",
                         unit: plan == nil ? "au bilan" : "au total")
                StatTile(label: "Évacuations",
                         value: plan.map { FrenchFormat.integer($0.evacuations) } ?? "—",
                         unit: plan == nil ? "au bilan" : "au total", why: .evacuations)
            }
            // « éléments » et non « fichiers » : depuis le lot 4 les répertoires
            // sont des occupants comme les autres, et ce compteur les inclut —
            // d'où les onze de plus que la fiche du disque (`UX_REVIEW.md` §3).
            // Le taux, lui, est rapporté à tout le catalogue, quand la fiche le
            // rapporte aux seuls fichiers fragmentables : le dire, les deux
            // nombres se lisent côte à côte.
            Text("Au départ : \(FrenchFormat.integer(before.fileCount)) éléments, "
                 + "\(FrenchFormat.percent(before.fragmentedRatio)) fragmentés, "
                 + "\(FrenchFormat.integer(before.freeHoles)) trous dans l'espace libre."
                 + (plan.map { " À l'arrivée : \(FrenchFormat.integer($0.after.fragmentedFiles)) éléments fragmentés, "
                     + "\(FrenchFormat.integer($0.after.freeHoles)) trous." } ?? ""))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            // C'est la stratégie qui commente ses propres compteurs : les mêmes
            // nombres ne disent pas la même chose d'un outil à l'autre.
            if let plan {
                Text(plan.strategy.summary(of: plan))
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .panel()
            }
        }
    }

    /// Ce qu'une installation a posé jusqu'ici, et ce qu'elle laissera.
    private func installCounters(_ install: InstallPlayback) -> some View {
        let placed = model.live.moves?.filesMoved ?? 0
        let finished = model.end != nil
        let arrival = install.installed.metrics
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                StatTile(label: "Fichiers posés",
                         value: FrenchFormat.integer(placed),
                         unit: "sur \(FrenchFormat.integer(install.files))")
                StatTile(label: "Écrit",
                         value: FrenchFormat.megabytes(UInt64(max(model.movedBytes, 0))),
                         unit: finished ? "en tout" : "jusqu'ici")
                StatTile(label: "Source", value: install.medium, unit: "le système")
                StatTile(label: "Redémarrages",
                         value: FrenchFormat.integer(install.reboots),
                         unit: "prévus", why: .installation)
            }
            Text("À poser : \(FrenchFormat.integer(install.files)) fichiers, "
                 + "\(FrenchFormat.megabytes(UInt64(install.bytes))), "
                 + (install.temporaryFiles > 0
                    ? "et \(FrenchFormat.integer(install.temporaryFiles)) archives extraites puis effacées "
                        + "(\(FrenchFormat.megabytes(UInt64(install.temporaryBytes)))). "
                    : "sans rien extraire à côté. ")
                 + (finished
                    ? "À l'arrivée : \(FrenchFormat.integer(arrival.fragmentedFileCount)) fichiers fragmentés, "
                        + "\(FrenchFormat.integer(arrival.freeRunCount)) trous dans l'espace libre."
                    : ""))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ce qu'une journée fait au disque, à mesure qu'on l'écoute.
    private func dayCounters(_ day: DayPlayback) -> some View {
        let detail = model.totals.detail
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                StatTile(label: "Lu", value: FrenchFormat.megabytes(UInt64(detail.readBytes)),
                         unit: "jusqu'ici")
                StatTile(label: "Écrit", value: FrenchFormat.megabytes(UInt64(detail.writeBytes)),
                         unit: "sur \(FrenchFormat.megabytes(UInt64(day.bytes))) annoncés")
                StatTile(label: "Seek moyen", value: FrenchFormat.integer(model.totals.averageSeekDistance),
                         unit: "cyl.", why: .seekLaw)
                StatTile(label: "Volume ce matin", value: FrenchFormat.percent(day.disk.metrics.fill),
                         unit: "\(FrenchFormat.integer(day.disk.metrics.fragmentedFileCount)) en morceaux")
            }
            Text("Jour \(FrenchFormat.integer(Int(day.day))) du disque, \(day.date). "
                 + (day.activities.isEmpty
                    ? "Rien n'y est écrit : la machine s'allume et s'éteint."
                    : "Ce qui s'y écrit vient de l'histoire du profil ; ce qui s'y lit, de ce que "
                        + "l'activité suppose."))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
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
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("\(FrenchFormat.integer(Int(frame.cylinder.rounded()))) / \(FrenchFormat.integer(model.geometry.cylinders))")
                    .font(.dynamic(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .monospacedDigit()
                Spacer()
                Text(model.geometry.model)
                    .font(.dynamic(size: 10, design: .monospaced))
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
        // Une passe entendue jusqu'au bout n'a plus de phase en cours.
        let current = engine.isFinished ? -1 : model.phaseIndex
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.defrag != nil ? "PHASES ÉCOUTÉES" : "ÉTAPES")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            if model.phaseTimes.isEmpty {
                Text("Rien encore.")
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(model.phaseTimes, id: \.index) { entry in
                HStack {
                    Circle()
                        .fill(Theme.phaseColor(entry.index))
                        .frame(width: 8, height: 8)
                    Text(model.phases.indices.contains(entry.index) ? model.phases[entry.index].label : "—")
                        .font(.dynamic(size: 13))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(entry.index == current ? "en cours · \(FrenchFormat.duration(entry.seconds))"
                                                : FrenchFormat.duration(entry.seconds))
                        .font(.dynamic(size: 12, design: .monospaced))
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
            .font(.dynamic(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    // MARK: - Démarrage

    /// Ce que le démarrage coûte, à mesure qu'on l'écoute : le calcul de la
    /// machine d'un côté, le disque de l'autre. Leur somme tend vers la durée.
    private func bootTiles(_ boot: BootPlayback) -> some View {
        let detail = model.totals.detail
        let disk = detail.seekSeconds + detail.rotationSeconds + detail.transferSeconds
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Fichiers à lire", value: FrenchFormat.integer(boot.filesRead),
                     unit: boot.residentFiles > 0 ? "dont \(FrenchFormat.integer(boot.residentFiles)) dans la MFT" : "")
            StatTile(label: "Lu",
                     value: FrenchFormat.megabytes(UInt64(detail.readBytes)),
                     unit: "jusqu'ici")
            StatTile(label: "Calcul", value: FrenchFormat.duration(detail.thinkSeconds),
                     unit: "la machine")
            StatTile(label: "Disque", value: FrenchFormat.duration(disk),
                     unit: "le bras et le plateau")
        }
    }

    /// Le témoin — maquette 14. Le même contenu, chacun d'un seul tenant et
    /// tassé contre le début du volume, a été simulé avant l'écoute ; l'écart
    /// ne se lit qu'une fois ce démarrage-ci entendu jusqu'au bout.
    private func witnessPanel(_ boot: BootPlayback) -> some View {
        let duration = model.end?.duration
        let gap = duration.flatMap { boot.freshSeconds > 0 ? $0 / boot.freshSeconds - 1 : nil }
        let totals = model.totals
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(duration.map { "DÉMARRAGE TERMINÉ · \(FrenchFormat.duration($0).uppercased())" }
                         ?? "DÉMARRAGE EN COURS · \(FrenchFormat.duration(time).uppercased())")
                        .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    HStack(spacing: 2) {
                        Text("Le témoin")
                            .font(.dynamic(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        WhyButton(topic: .witness)
                    }
                }
                Spacer()
                Text(gap.map(signedPercent) ?? "…")
                    .font(.dynamic(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(gap.map { $0 < 0 ? Theme.write : Theme.read } ?? Theme.dim)
                    .monospacedDigit()
            }

            VStack(spacing: 6) {
                if let diskID = model.disk?.spec.id,
                   let other = model.counterpartBoot(ofDisk: diskID, rangedBy: model.rangedBy) {
                    // Le même disque, entendu dans l'autre état : vieilli, ou
                    // rangé par un outil.
                    witnessRow(other.rangedBy.map { "rangé par \($0)" } ?? "avant rangement",
                               FrenchFormat.decimal(other.duration, digits: 1) + "\u{00A0}s",
                               seeks: other.seeks, average: other.averageSeek,
                               final: true)
                }
                witnessRow(model.rangedBy.map { "rangé par \($0)" } ?? "ce disque",
                           duration.map { FrenchFormat.decimal($0, digits: 1) + "\u{00A0}s" } ?? "en cours",
                           seeks: totals.seeks, average: totals.averageSeekDistance,
                           final: duration != nil)
                witnessRow("jamais fragmenté",
                           FrenchFormat.decimal(boot.freshSeconds, digits: 1) + "\u{00A0}s",
                           seeks: boot.freshSeeks, average: boot.freshAverageSeek,
                           final: true)
            }

            Text(witnessExplanation(boot, gap: gap))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 4) {
                WhyButton(topic: .prefetch)
                    .padding(.vertical, -6)
                Text(boot.readsByPosition
                     ? "Préchargeur de \(boot.osName) : la liste de lecture est rangée par position sur le disque, et relue d'une seule course du bras."
                     : "Pas de préchargeur sur \(boot.osName) : le bras suit l'ordre dans lequel le système demande ses fichiers, pas leur position.")
                    .font(.dynamic(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func witnessRow(_ label: String, _ duration: String,
                            seeks: Int, average: Int, final: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.dynamic(size: 13))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("\(FrenchFormat.integer(seeks)) seeks · \(FrenchFormat.integer(average)) cyl.")
                .font(.dynamic(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Text(duration)
                .font(.dynamic(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(final ? Theme.text : Theme.dim)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .monospacedDigit()
    }

    private func signedPercent(_ ratio: Double) -> String {
        (ratio >= 0 ? "+" : "−") + FrenchFormat.decimal(abs(ratio) * 100, digits: 1) + "\u{00A0}%"
    }

    /// Ce que dit l'écart. Sur les vingt démarrages de la galerie, FAT coûte
    /// de 0 à 4 %, et le témoin NTFS perd parfois : la phrase suit le format et
    /// le signe, pas un chiffre attendu.
    private func witnessExplanation(_ boot: BootPlayback, gap: Double?) -> String {
        guard let gap else {
            return "Le témoin lit exactement les mêmes fichiers, chacun d'un seul tenant et tassé contre "
                + "le début du volume. Il a été simulé avant l'écoute ; l'écart se lit à la fin."
        }
        switch boot.fileSystem {
        case .fat16, .vfat, .fat32:
            if gap < 0.05 {
                return "Sur FAT, la fragmentation ne coûte presque rien au démarrage : ces fichiers ont été "
                    + "écrits d'un seul tenant par l'installeur, sur un disque vide. Ce qui fait le bruit, "
                    + "c'est l'ordre dans lequel on les demande."
            }
            return "Ici, la place des fichiers coûte \(signedPercent(gap)) : plus que ce qu'un démarrage FAT "
                + "paie d'ordinaire. Les fichiers lus n'ont pas tous gardé la place que l'installeur "
                + "leur avait donnée."
        case .ntfs:
            if gap < 0 {
                return "Le témoin perd : NTFS choisit le trou qui convient plutôt que le premier venu, et sa "
                    + "disposition bat ici un rangement qui empile tout dans l'ordre du répertoire."
            }
            return "Sur NTFS, le témoin ne gagne pas toujours ; ici il gagne \(FrenchFormat.decimal(gap * 100, digits: 1)) %. "
                + "Il ne mesure pas la fragmentation seule, mais ce que coûte la place réelle des fichiers "
                + "face à un rangement naïf."
        }
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
                        .font(.dynamic(size: 54))
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
                    .font(.dynamic(size: size, weight: .semibold))
                    .frame(width: 44, height: 30)
                Text(title)
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
        .accessibilityLabel(title)
    }
}
