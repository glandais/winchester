import Foundation
import DiskCore
import Combine

/// Rejoue la carte des clusters à un instant donné.
///
/// Les mutations sont appliquées dans l'ordre et l'état courant est conservé :
/// avancer d'une image ne coûte que les quelques mutations écoulées. Un saut en
/// arrière repart de la carte initiale — c'est rare et c'est le seul cas où le
/// coût est celui de la passe entière.
final class ClusterMapPlayer {

    /// Taille de la grille d'affichage. Elle est fixée ici et non dans la vue :
    /// c'est le modèle qui agrège les clusters en blocs.
    static let columns = 48
    static let rows = 26
    static var cellCount: Int { columns * rows }

    private var playback: DefragPlayback?
    private var map: [UInt8] = []
    private var index = 0
    private var time: Double = 0

    var clustersPerCell: Int {
        guard let playback else { return 1 }
        return max(playback.partition.clusterCount / Self.cellCount, 1)
    }

    func load(_ playback: DefragPlayback?) {
        self.playback = playback
        reset()
    }

    private func reset() {
        map = playback?.plan.initialMap ?? []
        index = 0
        time = 0
    }

    /// Carte agrégée en blocs d'affichage. Un bloc prend la couleur de la
    /// catégorie la plus représentée parmi ses clusters occupés : un bloc qui
    /// contient ne serait-ce qu'un fichier n'a pas l'air vide.
    func cells(at requestedTime: Double) -> [UInt8] {
        guard let playback else { return [] }
        advance(to: requestedTime, playback: playback)

        let cellCount = Self.cellCount
        let perCell = clustersPerCell
        var cells = [UInt8](repeating: 0, count: cellCount)
        var counts = [Int](repeating: 0, count: ClusterCategory.allCases.count)

        for cell in 0..<cellCount {
            let start = cell * perCell
            guard start < map.count else { break }
            let end = min(start + perCell, map.count)
            for i in 0..<counts.count { counts[i] = 0 }
            for cluster in start..<end { counts[Int(map[cluster])] += 1 }

            var best = 0
            var bestCount = 0
            for category in 1..<counts.count where counts[category] > bestCount {
                best = category
                bestCount = counts[category]
            }
            cells[cell] = UInt8(best)
        }
        return cells
    }

    func cell(ofCluster cluster: Int) -> Int { cluster / clustersPerCell }

    private func advance(to requestedTime: Double, playback: DefragPlayback) {
        if requestedTime < time { reset() }
        time = requestedTime
        let mutations = playback.mutations
        while index < mutations.count && mutations[index].time <= requestedTime {
            let mutation = mutations[index]
            let end = min(mutation.start + mutation.count, map.count)
            if mutation.start < end {
                for cluster in mutation.start..<end { map[cluster] = mutation.category }
            }
            index += 1
        }
    }
}

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
    var requests: [BlockRequest] { scenario.requests }
    var iops: [Double] { scenario.iops }
    var throughputMBs: [Double] { scenario.throughputMBs }
    var peakIOPS: Double { scenario.peakIOPS }
    var duration: Double { scenario.duration }
    var stats: TraceStats { scenario.trace.stats }
    var defrag: DefragPlayback? { scenario.defrag }

    init() {
        let scenario = ScenarioBuilder.build(.windowsBoot)
        self.selection = .builtin(.windowsBoot)
        self.scenario = scenario
        self.cache = [.builtin(.windowsBoot): scenario]
        self.engine = DiskNoiseEngine(rpm: scenario.geometry.rpm)
        mapPlayer.load(scenario.defrag)
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
        // que dans la galerie, et n'entre ici que par `load(generated:)`.
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
    func load(generated disk: GeneratedDisk) throws {
        let selection = ScenarioSelection.generated(disk.spec.id)
        let scenario = try ScenarioBuilder.build(generated: disk)
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
        mapPlayer.load(scenario.defrag)
        engine.seekTo(0)
        engine.load(cues: scenario.cues, duration: scenario.duration, rpm: scenario.geometry.rpm)
    }

    // MARK: - Interrogation à un instant donné

    func span(at time: Double) -> PhaseSpan? {
        spans.last { $0.start <= time } ?? spans.first
    }

    private func headSampleIndex(at time: Double) -> Int? {
        let samples = scenario.trace.headSamples
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        guard samples[0].time <= time else { return nil }
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func cylinder(at time: Double) -> Int {
        guard let index = headSampleIndex(at: time) else { return 0 }
        return scenario.trace.headSamples[index].cylinder
    }

    /// Derniers accès, pour la traînée affichée sur le plateau.
    func recentAccesses(at time: Double, window: Double = 1.6, limit: Int = 90) -> [HeadSample] {
        guard let index = headSampleIndex(at: time) else { return [] }
        let samples = scenario.trace.headSamples
        var result: [HeadSample] = []
        var i = index
        while i >= 0 && result.count < limit && time - samples[i].time <= window {
            result.append(samples[i])
            i -= 1
        }
        return result
    }

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

    var clustersPerCell: Int { mapPlayer.clustersPerCell }

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
