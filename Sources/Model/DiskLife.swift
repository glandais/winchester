import Foundation
import DiskCore

/// La vie d'un disque, en accéléré.
///
/// Une journée d'usage s'écoute en quelques minutes ; deux ans en durent des
/// centaines. Ce défilement-ci ne joue donc rien : il fait avancer les jours sur
/// la **carte**, en tenant le compte de ce que le volume devient, et il signale
/// les journées qui valent d'être écoutées. On s'y arrête quand on veut :
/// `replay` est laissé au matin du jour suivant, prêt pour
/// `ScenarioBuilder.build(day:replay:)`.
final class DiskLife {

    /// Ce qu'une journée laisse derrière elle.
    struct DayDigest: Identifiable, Sendable {
        var day: UInt32
        var date: String
        /// Remplissage du volume au soir.
        var fill: Double
        var fragmentedFiles: Int
        var fileCount: Int
        /// Trous dans l'espace libre. Compté de loin en loin : sur un volume de
        /// 320 Go, chaque comptage parcourt la bitmap entière.
        var freeHoles: Int?
        var bytesWritten: Int
        var activities: [DayActivity]
        /// Pourquoi cette journée mérite d'être écoutée, s'il y a une raison.
        var landmark: Landmark?

        var id: UInt32 { day }
    }

    /// Ce qui fait qu'une journée sort du lot.
    enum Landmark: Equatable, Sendable {
        case installation
        /// Le volume vient de passer ce cap de remplissage.
        case filling(Int)
        /// Le disque a refusé une écriture : il est plein.
        case full
        /// Une grosse journée : une installation de jeu, un import massif.
        case heavyDay
        /// L'utilisateur a lancé un défragmenteur ce jour-là.
        case defragmented
        /// Nouveau record de fichiers en morceaux.
        case fragmentation

        var label: String {
            switch self {
            case .installation:   return "Installation"
            case let .filling(percent): return "Disque à \(percent) %"
            case .full:           return "Disque plein"
            case .heavyDay:       return "Grosse journée"
            case .defragmented:   return "Défragmentation"
            case .fragmentation:  return "Pic de fragmentation"
            }
        }
    }

    let replay: HistoryReplay
    let grid: MapGrid
    private(set) var digests: [DayDigest] = []
    /// Les journées qui valent d'être écoutées, dans l'ordre.
    private(set) var landmarks: [DayDigest] = []

    /// Combien de jours sur les trous libres : les compter à chaque journée
    /// coûterait un parcours complet de la bitmap.
    private let holesEvery = 30

    private var fillMarks: Set<Int> = []
    private var fragmentationRecord = 0
    /// Dernière grosse journée signalée. Un disque dont le propriétaire vide
    /// son caméscope tous les soirs en aurait une par jour : ce ne serait plus
    /// un repère.
    private var lastHeavyDay: UInt32?
    private var failedWrites = 0
    private let heavyThreshold: Int

    init(spec: ProfileSpec, grid: MapGrid = .standard) {
        self.replay = HistoryReplay(spec)
        self.grid = grid
        // « Grosse journée » : ce qui s'écrit en un jour dépasse le vingtième
        // du disque. Un jeu qui s'installe, un caméscope qu'on vide.
        self.heavyThreshold = Int(spec.disk.sizeBytes / 20)
    }

    /// Le jour qui n'est pas encore joué : celui qu'on peut écouter.
    var nextDay: UInt32? { replay.nextDay }
    var isFinished: Bool { replay.isFinished }
    var dayCount: UInt32 { replay.spec.timeline.dayCount }

    /// Fait défiler `days` journées, et rend ce qu'elles laissent.
    @discardableResult
    func advance(days: Int = 1) -> [DayDigest] {
        var produced: [DayDigest] = []
        for _ in 0..<max(days, 1) {
            guard let day = replay.nextDay else { break }
            produced.append(play(day))
        }
        return produced
    }

    /// Fait défiler jusqu'à la prochaine journée qui vaut d'être écoutée.
    @discardableResult
    func advanceToLandmark(limit: Int = 400) -> DayDigest? {
        for _ in 0..<limit {
            guard let day = replay.nextDay else { return nil }
            let digest = play(day)
            if digest.landmark != nil { return digest }
        }
        return nil
    }

    private func play(_ day: UInt32) -> DayDigest {
        let activities = DayPlanner.activities(of: day, in: replay)
        let bytes = replay.writtenBytes(of: day)
        let hadFailures = replay.failedWrites
        replay.skip(through: day)

        let files = replay.catalog.files
        let fragmented = files.reduce(0) { $0 + ($1.extents.count > 1 ? 1 : 0) }
        let fill = replay.bitmap.fill
        var digest = DayDigest(day: day,
                               date: replay.spec.timeline.start.adding(days: Int(day)).description,
                               fill: fill,
                               fragmentedFiles: fragmented,
                               fileCount: files.count,
                               freeHoles: day % UInt32(holesEvery) == 0 ? replay.bitmap.freeRunCount() : nil,
                               bytesWritten: bytes,
                               activities: activities)
        digest.landmark = landmark(day: day, fill: fill, fragmented: fragmented,
                                   bytes: bytes, failures: replay.failedWrites - hadFailures)
        digests.append(digest)
        if digest.landmark != nil { landmarks.append(digest) }
        return digest
    }

    /// Ce qui fait qu'on s'arrête sur cette journée-là.
    ///
    /// Une seule raison par jour, la plus parlante : un disque qui se remplit
    /// dit plus qu'un record de fragmentation, qui arrive sans arrêt au début.
    private func landmark(day: UInt32, fill: Double, fragmented: Int,
                          bytes: Int, failures: Int) -> Landmark? {
        if day == 0 { return .installation }
        if replay.events(of: day).contains(where: { if case .defragment = $0.event { return true }; return false }) {
            return .defragmented
        }
        if failures > 0, fillMarks.insert(-1).inserted { return .full }
        for cap in [95, 90, 75, 50] where Int(fill * 100) >= cap {
            if fillMarks.insert(cap).inserted { return .filling(cap) }
            break
        }
        if bytes > heavyThreshold, day > (lastHeavyDay.map { $0 + 30 } ?? 0) {
            lastHeavyDay = day
            return .heavyDay
        }
        // Un record de fragmentation ne compte que s'il change l'ordre de
        // grandeur : sinon chaque journée du début en serait un.
        if fragmented > max(fragmentationRecord * 2, 50) {
            fragmentationRecord = fragmented
            return .fragmentation
        }
        fragmentationRecord = max(fragmentationRecord, fragmented)
        return nil
    }

    // MARK: - Ce que la carte montre

    /// La carte du volume au soir du dernier jour joué.
    func shades() -> [ClusterShade] {
        let shaded = ClusterShading.shaded(catalog: replay.catalog,
                                           systemExtents: replay.systemExtents,
                                           clusterCount: replay.bitmap.clusterCount,
                                           cellCount: grid.cellCount)
        return (0..<grid.cellCount).map { cell in
            ClusterShade(category: shaded.categories[cell] == .max
                            ? ClusterCategory.free.rawValue
                            : ClusterCategory(FileCategory(rawValue: shaded.categories[cell]) ?? .metadata).rawValue,
                         fill: shaded.fill[cell],
                         contiguous: shaded.contiguous[cell])
        }
    }

    /// Les courbes du volume : remplissage et fichiers en morceaux, un point
    /// par journée jouée.
    var curves: (fill: [Double], fragmented: [Int]) {
        (digests.map(\.fill), digests.map(\.fragmentedFiles))
    }
}
