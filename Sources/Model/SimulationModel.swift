import Foundation
import DiskCore
import Combine

/// Branche un scénario sur le moteur audio, et expose au rendu ce que la passe
/// montre à l'instant écouté.
///
/// Rien n'est plus calculé d'avance : choisir un scénario lance sa passe sur un
/// fil à part, qui avance quelques secondes devant l'écoute. L'écran ne
/// connaît de la passe que son présent — ni sa durée, ni son passé au-delà de
/// ce qu'une image peut encore montrer.
@MainActor
final class SimulationModel: ObservableObject {

    @Published private(set) var selection: ScenarioSelection
    @Published private(set) var scenario: Scenario
    /// La passe en cours d'écoute.
    @Published private(set) var live: LivePass

    let engine: DiskNoiseEngine

    /// Les scénarios décrits, pas leurs passes : un disque de la galerie coûte
    /// sa conversion en volume, qu'on ne refait pas à chaque aller-retour.
    private var cache: [ScenarioSelection: Scenario] = [:]

    /// Le disque de la galerie que joue la passe, s'il en vient un : c'est lui
    /// qu'on relance avec un autre outil, ou qu'on démarre une fois rangé.
    private(set) var disk: GeneratedDisk?
    /// L'outil qui a rangé `disk`, quand la passe démarre un volume rangé.
    private(set) var rangedBy: String?

    /// Les passes entendues jusqu'au bout, dans l'ordre. C'est ce que lisent
    /// le bilan et la comparaison.
    @Published private(set) var records: [PassRecord] = []
    /// Numéro de la passe en cours ; un bilan le porte, pour qu'on sache qu'il
    /// parle d'elle.
    private(set) var passNumber = 0
    /// La carte au départ de la passe en cours.
    private var startShades: (grid: MapGrid, shades: [ClusterShade])?
    private var finished: AnyCancellable?

    /// Le nombre de passes gardées : un bilan garde le disque entier, et un
    /// NTFS de 320 Go pèse quelques mégaoctets de catalogue.
    private static let recordLimit = 12

    var kind: ScenarioKind { scenario.kind }
    var label: ScenarioLabel { scenario.label }
    var geometry: DriveGeometry { scenario.geometry }
    var defrag: DefragPlayback? { scenario.defrag }
    var boot: BootPlayback? { scenario.boot }
    var install: InstallPlayback? { scenario.install }
    var dayPlayback: DayPlayback? { scenario.dayPlayback }
    /// La carte de la passe : le volume à ranger, ou celui qu'on installe.
    var mapSource: (partition: PartitionGeometry, initialRuns: [MapRun])? { scenario.map }

    init() {
        let scenario = ScenarioBuilder.build(.windowsBoot)
        let live = scenario.startLivePass()
        self.selection = .builtin(.windowsBoot)
        self.scenario = scenario
        self.live = live
        self.cache = [.builtin(.windowsBoot): scenario]
        self.engine = DiskNoiseEngine(rpm: scenario.geometry.rpm)
        engine.mix = SoundMix.load(from: .standard)
        engine.load(feed: live, rpm: scenario.geometry.rpm)
        captureStart()
        finished = engine.$isFinished
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recordFinishedPass() }
            }
    }

    /// Ce que propose le sélecteur : les scénarios livrés, puis le disque de la
    /// galerie qu'on lui a confié, s'il y en a un.
    ///
    /// Un seul à la fois : c'est un sélecteur segmenté, et vingt profils n'y
    /// tiendraient pas. Revenir sur un disque précédent se fait depuis la
    /// galerie, où il est de toute façon déjà affiché.
    var selections: [ScenarioSelection] {
        ScenarioKind.allCases.map(ScenarioSelection.builtin)
            + cache.keys.filter(\.isGenerated).sorted { $0.sortKey < $1.sortKey }
    }

    /// Bascule de scénario. La passe repart de son début.
    func select(_ selection: ScenarioSelection) {
        guard selection != self.selection else { return }
        guard let scenario = cache[selection] ?? built(selection) else { return }
        cache[selection] = scenario
        adopt(scenario, as: selection)
    }

    private func built(_ selection: ScenarioSelection) -> Scenario? {
        // Un disque généré n'est jamais reconstruit à la volée : il n'existe
        // que dans la galerie, et n'entre ici que par `load(generated:as:)`.
        guard case let .builtin(kind) = selection else { return nil }
        return ScenarioBuilder.build(kind)
    }

    /// Adopte un disque fabriqué par la galerie et bascule dessus.
    ///
    /// Plus rien n'est planifié ici : la conversion du disque en volume est le
    /// seul coût payé sur le fil principal, la passe elle-même se calcule
    /// pendant qu'on l'écoute.
    ///
    /// Un seul disque de la galerie est gardé à la fois, quelle que soit
    /// l'activité : le sélecteur est segmenté, et une quatrième entrée n'y
    /// tiendrait pas. Revenir sur le précédent se fait depuis la galerie.
    ///
    /// `strategy` choisit le défragmenteur ; `nil` laisse le format décider,
    /// comme l'aurait fait la machine de l'époque. Un démarrage l'ignore.
    func load(generated disk: GeneratedDisk,
              as activity: GeneratedActivity,
              using strategy: (any DefragStrategy)? = nil) throws {
        let selection = ScenarioSelection.generated(disk.spec.id, activity)
        let scenario: Scenario
        switch activity {
        case .boot:    scenario = ScenarioBuilder.build(boot: disk)
        case .defrag:  scenario = try ScenarioBuilder.build(generated: disk, using: strategy)
        // L'installation repart de la fiche, pas du disque vieilli : c'est le
        // jour 0 de la même histoire qu'on rejoue.
        case .install: scenario = ScenarioBuilder.build(install: try DiskGenerator.install(disk.spec))
        // Revivre n'est pas une passe : l'écran du défilement mène lui-même à
        // la journée qu'on veut écouter, par `load(day:of:)`.
        case .life: throw ActivityError.notAPass
        }
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        self.disk = disk
        self.rangedBy = nil
        adopt(scenario, as: selection)
    }

    /// Écoute une journée de la vie d'un disque, là où le défilement en est.
    ///
    /// Le rejeu est celui du défilement : la journée est jouée sur le disque
    /// tel qu'il est ce matin-là, et le défilement reprendra ensuite au
    /// lendemain.
    func load(day: UInt32, of life: DiskLife, disk: GeneratedDisk) throws {
        let scenario = try ScenarioBuilder.build(day: day, replay: life.replay)
        let selection = ScenarioSelection.generated(disk.spec.id, .life)
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        self.disk = disk
        self.rangedBy = nil
        adopt(scenario, as: selection)
    }

    /// Démarre le disque qu'une installation vient de poser : le jour 0 de
    /// l'histoire, avant tout usage.
    func loadInstalledBoot(from record: PassRecord) {
        guard let original = record.disk, let installed = record.installed else { return }
        let scenario = ScenarioBuilder.build(boot: installed, rangedBy: nil, freshlyInstalled: true)
        let selection = ScenarioSelection.generated(original.spec.id, .boot)
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        self.disk = original
        self.rangedBy = nil
        adopt(scenario, as: selection)
    }

    /// Démarre le disque qu'une passe a laissé : les mêmes fichiers, là où
    /// l'outil les a posés. Rien si la passe ne venait pas de la galerie.
    func loadRangedBoot(from record: PassRecord) {
        guard let original = record.disk, !record.arrangement.isEmpty else { return }
        let places = Dictionary(record.arrangement.map { ($0.id, $0.extents) },
                                uniquingKeysWith: { _, last in last })
        let ranged = original.rearranged(extents: places)
        let scenario = ScenarioBuilder.build(boot: ranged, rangedBy: record.toolLabel)
        let selection = ScenarioSelection.generated(original.spec.id, .boot)
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        // Le disque d'origine reste celui qu'on relance : ranger un disque déjà
        // rangé n'est pas ce qu'on compare.
        self.disk = original
        self.rangedBy = record.toolLabel
        adopt(scenario, as: selection)
        // Même sélection que le démarrage d'origine : `adopt` ne saute pas.
    }

    /// Nom d'un choix dans le sélecteur. Un disque généré porte le nom de son
    /// profil, qui n'est connu qu'une fois le scénario construit.
    func title(of selection: ScenarioSelection) -> String {
        if let scenario = cache[selection] { return scenario.label.title }
        if case let .builtin(kind) = selection { return kind.title }
        return "—"
    }

    private func adopt(_ scenario: Scenario, as selection: ScenarioSelection) {
        self.selection = selection
        self.scenario = scenario
        startPass()
    }

    /// Relance la passe depuis son début — le seul retour en arrière qui
    /// reste. La lecture reprend si elle était en cours.
    func restart() {
        let wasPlaying = engine.isPlaying || engine.isBuffering
        startPass()
        if wasPlaying { engine.play() }
    }

    private func startPass() {
        // La passe abandonnée libère son producteur en partant.
        let grid = live.map?.grid ?? .standard
        live = scenario.startLivePass()
        live.map?.setGrid(grid)
        engine.load(feed: live, rpm: scenario.geometry.rpm)
        passNumber += 1
        captureStart()
    }

    /// La carte avant la première mutation : ce que le bilan montre à gauche.
    private func captureStart() {
        guard let map = live.map else { startShades = nil; return }
        startShades = (map.grid, map.shades(at: 0))
    }

    /// Une passe vient d'être entendue jusqu'au bout : on garde son bilan.
    private func recordFinishedPass() {
        guard let end = live.end, records.last?.passNumber != passNumber else { return }
        let totals = live.totals
        var record = PassRecord(passNumber: passNumber,
                                diskID: disk?.spec.id ?? label.title,
                                title: label.title,
                                kind: recordKind,
                                toolLabel: defrag?.strategy.label ?? install?.osName
                                    ?? dayPlayback.map { "Jour \($0.day)" } ?? boot?.osName ?? "",
                                toolID: defrag?.strategy.id,
                                rangedBy: rangedBy,
                                duration: end.duration,
                                requests: totals.requests,
                                seeks: totals.seeks,
                                averageSeek: totals.averageSeekDistance,
                                movedBytes: totals.movedBytes)
        if let plan = end.plan, let playback = defrag {
            record.before = playback.before
            record.after = plan.after
            record.filesMoved = plan.filesMoved
            record.evacuations = plan.evacuations
            record.summary = plan.strategy.summary(of: plan)
            record.arrangement = plan.arrangement
            record.contentBytes = playback.before.fill * Double(playback.partition.clusterCount)
                * Double(playback.partition.clusterBytes)
            if let start = startShades, let map = live.map {
                record.startMap = start
                record.endMap = (map.grid, map.shades(at: end.duration))
            }
        }
        if let boot {
            record.freshSeconds = boot.freshSeconds
        }
        if let install {
            record.installed = install.installed
            record.filesMoved = install.files
            record.contentBytes = Double(install.bytes)
            if let start = startShades, let map = live.map {
                record.startMap = start
                record.endMap = (map.grid, map.shades(at: end.duration))
            }
        }
        record.disk = disk
        records.append(record)
        if records.count > Self.recordLimit { records.removeFirst(records.count - Self.recordLimit) }
    }

    private var recordKind: PassRecord.Kind {
        if defrag != nil { return .defrag }
        if install != nil { return .install }
        if dayPlayback != nil { return .day }
        return .boot
    }

    /// Le bilan de la passe en cours, si elle est finie.
    var currentRecord: PassRecord? {
        records.last { $0.passNumber == passNumber }
    }

    /// Les autres passes de défragmentation sur le même disque.
    func otherDefrags(than record: PassRecord) -> [PassRecord] {
        records.filter { $0.kind == .defrag && $0.diskID == record.diskID && $0.id != record.id }
    }

    /// Le dernier démarrage du même disque dans l'autre état — vieilli si
    /// celui-ci est rangé, rangé si celui-ci est vieilli.
    func counterpartBoot(ofDisk diskID: String, rangedBy: String?) -> PassRecord? {
        records.last { $0.kind == .boot && $0.diskID == diskID && ($0.rangedBy == nil) != (rangedBy == nil) }
    }

    // MARK: - Minuterie d'arrêt

    /// L'heure à laquelle la passe s'arrêtera d'elle-même, en fondu.
    @Published private(set) var sleepDeadline: Date?
    private var sleepCheck: Timer?

    /// Arme la minuterie, ou la désarme avec `nil`. Elle compte en heure
    /// murale, pas en temps de passe : c'est l'heure du coucher qu'on règle, et
    /// une passe qui attend son calcul ne doit pas la repousser.
    func setSleepTimer(after seconds: Double?) {
        sleepCheck?.invalidate()
        sleepCheck = nil
        guard let seconds else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date(timeIntervalSinceNow: seconds)
        // Une vérification par seconde suffit à une échéance d'une heure, et
        // continue en arrière-plan tant que la passe joue.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSleepTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepCheck = timer
    }

    private func checkSleepTimer() {
        guard let deadline = sleepDeadline, Date() >= deadline else { return }
        setSleepTimer(after: nil)
        engine.pauseFadingOut()
    }

    // MARK: - L'instant écouté

    /// La phase en cours et son rang, pour la couleur.
    var phase: PhaseDescriptor? { live.phase }
    var phaseIndex: Int { live.phaseIndex }

    /// Le plateau et sa trace de position, tels que la vue les interroge.
    var platter: PlatterTrack { live.platter }

    /// Tout ce que le plateau doit montrer à cet instant, en une seule passe.
    func platterFrame(at time: Double) -> PlatterFrame { live.platter.frame(at: time) }

    /// Le voyant d'activité, comme sur la façade : c'est exactement le signal
    /// dont se contente HDDSynth pour déclencher ses sons.
    var activityLED: Bool { live.requestRate > 0.5 }

    /// Le temps écouté dans chaque phase, dans l'ordre où elles sont apparues.
    var phaseTimes: [PhaseTime] { live.phaseTimes }
    var phases: [PhaseDescriptor] { live.phases }

    var requestRate: Double { live.requestRate }
    var throughputMBs: Double { live.throughputMBs }
    var totals: ActivityTotals { live.totals }

    /// Le bilan, une fois la passe entendue jusqu'au bout de son travail.
    var end: PassEnd? {
        guard let end = live.end, live.now >= end.workEnd else { return nil }
        return end
    }

    // MARK: - Défragmentation

    func clusterShades(at time: Double) -> [ClusterShade] { live.map?.shades(at: time) ?? [] }

    /// Les accès encore visibles sur la carte, en plein écran.
    func mapTrail() -> [MapTrailPoint] { live.mapTrail() }

    /// Cellule en cours d'accès, s'il y en a une à cet instant.
    func activeCell() -> (cell: Int, isWrite: Bool)? { live.activeCell() }

    var clustersPerCell: Double { live.map?.clustersPerCell ?? 1 }

    /// Les clusters d'un bloc de la carte rejouée.
    func clusters(ofCell cell: Int) -> Range<Int> {
        live.map?.partition.clusters(ofCell: cell) ?? 0..<0
    }

    /// Grille sur laquelle la carte est agrégée. La vue la lit ici plutôt que
    /// de la deviner : c'est le modèle qui décide combien de blocs il produit,
    /// et la vue n'en dessine jamais d'autres.
    var mapGrid: MapGrid { live.map?.grid ?? .standard }

    /// Change la grille d'affichage — le plein écran la dérive de la surface
    /// disponible. Le rejeu garde sa position ; seule l'agrégation est refaite.
    func setMapGrid(_ grid: MapGrid) {
        guard let map = live.map, grid != map.grid else { return }
        map.setGrid(grid)
        objectWillChange.send()
    }

    var movedBytes: Double { Double(live.totals.movedBytes) }

    /// Avancement annoncé par le défragmenteur, s'il en annonce un.
    var defragProgress: Double? { live.progress }
}
