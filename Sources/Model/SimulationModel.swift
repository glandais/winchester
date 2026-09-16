import Foundation
import DiskCore
import Combine

/// Assemble la chaîne complète : scénario → requêtes bloc → chronologie
/// mécanique → repères audio, et expose au rendu ce qu'il faut pour afficher
/// l'état du disque à un instant donné.
@MainActor
final class SimulationModel: ObservableObject {

    @Published private(set) var selection: ScenarioSelection
    @Published private(set) var scenario: Scenario

    let engine: DiskNoiseEngine

    private var cache: [ScenarioSelection: Scenario] = [:]
    private let mapPlayer = ClusterMapPlayer()

    var kind: ScenarioKind { scenario.kind }
    var label: ScenarioLabel { scenario.label }

    static let bucketDuration = ScenarioBuilder.bucketDuration

    var geometry: DriveGeometry { scenario.geometry }
    var spans: [PhaseSpan] { scenario.spans }
    var requestCount: Int { scenario.requestCount }
    var iops: [Double] { scenario.iops }
    var throughputMBs: [Double] { scenario.throughputMBs }
    var peakIOPS: Double { scenario.peakIOPS }
    var duration: Double { scenario.duration }
    var stats: TraceStats { scenario.trace.stats }
    var defrag: DefragPlayback? { scenario.defrag }
    var boot: BootPlayback? { scenario.boot }

    init() {
        let scenario = ScenarioBuilder.build(.windowsBoot)
        self.selection = .builtin(.windowsBoot)
        self.scenario = scenario
        self.cache = [.builtin(.windowsBoot): scenario]
        self.engine = DiskNoiseEngine(rpm: scenario.geometry.rpm)
        mapPlayer.load(scenario.defrag?.clusterTimeline)
        engine.load(cues: scenario.cues, duration: scenario.duration, rpm: scenario.geometry.rpm)
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

    /// Bascule de scénario. Les scénarios livrés sont conservés une fois
    /// construits : la construction d'une passe de défragmentation coûte
    /// quelques dizaines de millisecondes, mais on ne la refait pas à chaque
    /// aller-retour.
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
    /// La planification et la simulation restent du même ordre que la passe
    /// livrée : 70 à 190 ms en release sur les huit volumes FAT16 que le pont
    /// accepte, le plus lourd étant `famille-1996` et ses 163 000 requêtes.
    /// C'est court pour une action explicite, et c'est pour cela que rien de
    /// tout cela ne part en tâche de fond — la génération du disque, elle, en
    /// vient déjà.
    ///
    /// Un seul disque de la galerie est gardé à la fois, quelle que soit
    /// l'activité : le sélecteur est segmenté, et une quatrième entrée n'y
    /// tiendrait pas. Revenir sur le précédent se fait depuis la galerie.
    func load(generated disk: GeneratedDisk, as activity: GeneratedActivity) throws {
        let selection = ScenarioSelection.generated(disk.spec.id, activity)
        let scenario: Scenario
        switch activity {
        case .boot:   scenario = ScenarioBuilder.build(boot: disk)
        case .defrag: scenario = try ScenarioBuilder.build(generated: disk)
        }
        for key in cache.keys where key.isGenerated { cache[key] = nil }
        cache[selection] = scenario
        adopt(scenario, as: selection)
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
        mapPlayer.load(scenario.defrag?.clusterTimeline)
        engine.seekTo(0)
        engine.load(cues: scenario.cues, duration: scenario.duration, rpm: scenario.geometry.rpm)
    }

    // MARK: - Interrogation à un instant donné

    func span(at time: Double) -> PhaseSpan? {
        spans.last { $0.start <= time } ?? spans.first
    }

    /// Le plateau et sa trace de position, tels que la vue les interroge.
    var platter: PlatterTrack {
        PlatterTrack(geometry: scenario.geometry,
                     seekModel: scenario.seekModel,
                     samples: scenario.trace.headSamples,
                     spindle: scenario.trace.spindle,
                     parkAt: scenario.trace.parkAt)
    }

    /// Tout ce que le plateau doit montrer à cet instant, en une seule passe.
    func platterFrame(at time: Double) -> PlatterFrame { platter.frame(at: time) }

    func bucketValue(_ series: [Double], at time: Double) -> Double {
        guard !series.isEmpty else { return 0 }
        let index = min(max(Int(time / Self.bucketDuration), 0), series.count - 1)
        return series[index]
    }

    /// Le voyant d'activité, comme sur la façade : c'est exactement le signal
    /// dont se contente HDDSynth pour déclencher ses sons.
    func activityLED(at time: Double) -> Bool {
        bucketValue(iops, at: time) > 0.5
    }

    // MARK: - Défragmentation

    func clusterCells(at time: Double) -> [UInt8] { mapPlayer.cells(at: time) }

    /// La carte avec le taux d'occupation de chaque bloc, dont le plein écran
    /// fait sa teinte proportionnelle.
    func clusterShades(at time: Double) -> [ClusterShade] { mapPlayer.shades(at: time) }

    /// Les accès encore visibles sur la carte, en plein écran.
    ///
    /// La projection d'un cluster sur la grille passe par le rejeu, seul à
    /// savoir combien de clusters vaut un bloc à cet instant — la grille change
    /// quand on ouvre le plein écran.
    func mapTrail(at time: Double) -> [MapTrailPoint] {
        guard let playback = defrag else { return [] }
        return MapTrail.points(in: playback.activity, at: time) { [mapPlayer] cluster in
            mapPlayer.cell(ofCluster: cluster)
        }
    }

    var clustersPerCell: Int { mapPlayer.clustersPerCell }

    /// Grille sur laquelle la carte est agrégée. La vue la lit ici plutôt que
    /// de la deviner : c'est le modèle qui décide combien de blocs il produit,
    /// et la vue n'en dessine jamais d'autres.
    var mapGrid: MapGrid { mapPlayer.grid }

    /// Change la grille d'affichage — le plein écran la dérive de la surface
    /// disponible. Le rejeu garde sa position ; seule l'agrégation est refaite.
    func setMapGrid(_ grid: MapGrid) {
        guard grid != mapPlayer.grid else { return }
        mapPlayer.setGrid(grid)
        objectWillChange.send()
    }

    /// Cellule en cours d'accès, s'il y en a une à cet instant.
    func activeCell(at time: Double) -> (cell: Int, isWrite: Bool)? {
        guard let playback = defrag, !playback.activity.isEmpty else { return nil }
        let activity = playback.activity

        var low = 0
        var high = activity.count - 1
        guard activity[0].start <= time else { return nil }
        while low < high {
            let mid = (low + high + 1) / 2
            if activity[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        let current = activity[low]
        // Au-delà de la fin de l'opération on garde le surlignage un court
        // instant : à 60 images par seconde, la plupart des transferts durent
        // moins d'une image et clignoteraient.
        guard time - current.end < 0.12 else { return nil }
        return (mapPlayer.cell(ofCluster: current.cluster), current.isWrite)
    }

    func movedBytes(at time: Double) -> Double {
        guard let playback = defrag else { return 0 }
        return bucketValue(playback.movedBytes, at: time)
    }

    /// Avancement de la passe, du début de l'analyse à la dernière opération.
    func defragProgress(at time: Double) -> Double {
        guard let playback = defrag, playback.workEndTime > 0 else { return 0 }
        return min(max(time / playback.workEndTime, 0), 1)
    }
}
