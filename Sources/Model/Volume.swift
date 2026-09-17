import Foundation
import DiskCore

/// Nature du contenu d'un cluster, telle que la carte du défragmenteur la
/// coloriait. C'est aussi la catégorie du fichier qui l'occupe.
enum ClusterCategory: UInt8, CaseIterable {
    case free = 0
    case system
    case application
    case document
    case archive
    case churn
    case swap
    /// Ce que le système de fichiers occupe pour lui-même : secteur
    /// d'amorçage, tables FAT et racine, ou sur NTFS la MFT et sa copie.
    case reserved

    var label: String {
        switch self {
        case .free:        return "Libre"
        case .system:      return "Système"
        case .application: return "Applications"
        case .document:    return "Documents"
        case .archive:     return "Aide, archives"
        case .churn:       return "Temporaires, cache"
        case .swap:        return "Fichier d'échange"
        case .reserved:    return "FAT, MFT, racine"
        }
    }

    /// Ordre de passage du défragmenteur : les fichiers sont empaquetés dans
    /// l'ordre du parcours de l'arborescence, et ce parcours rencontre les
    /// catégories dans cet ordre-là.
    var packingGroup: Int {
        switch self {
        case .system, .archive, .reserved, .free: return 0
        case .application:                        return 1
        case .document:                           return 2
        case .churn, .swap:                       return 3
        }
    }
}

/// Suite de clusters consécutifs.
struct ClusterRun {
    let start: Int
    let count: Int
    var end: Int { start + count }
}

struct VolumeFile {
    let id: Int
    let path: String
    let kind: ClusterCategory
    /// Rang de création : c'est l'ordre des entrées dans le répertoire.
    let created: Int
    var chain: [Int]

    var directory: String {
        guard let slash = path.lastIndex(of: "\\"), slash != path.startIndex else { return "\\" }
        return String(path[path.startIndex..<slash])
    }

    var isContiguous: Bool {
        guard chain.count > 1 else { return true }
        for i in 0..<(chain.count - 1) where chain[i] + 1 != chain[i + 1] { return false }
        return true
    }

    var extents: [ClusterRun] {
        guard !chain.isEmpty else { return [] }
        var runs: [ClusterRun] = []
        var start = chain[0]
        var length = 1
        for i in 1..<chain.count {
            if chain[i] == chain[i - 1] + 1 {
                length += 1
            } else {
                runs.append(ClusterRun(start: start, count: length))
                start = chain[i]
                length = 1
            }
        }
        runs.append(ClusterRun(start: start, count: length))
        return runs
    }
}

/// Volume FAT16 : table d'occupation des clusters et catalogue de fichiers.
///
/// L'allocateur reproduit ce qui a fragmenté les volumes Windows 95 en premier
/// lieu : VFAT sert le premier cluster libre **à partir du dernier alloué**, et
/// repart au début en fin de volume. Entremêler quelques centaines de
/// créations, suppressions et extensions suffit à faire éclater les fichiers.
final class Volume {

    let partition: PartitionGeometry
    private(set) var owner: [Int32]
    private(set) var files: [Int: VolumeFile] = [:]
    private(set) var freeCount: Int

    private var cursor = 0
    private var sequence = 0
    private var nextID = 1

    init(partition: PartitionGeometry) {
        self.partition = partition
        self.owner = [Int32](repeating: -1, count: partition.clusterCount)
        self.freeCount = partition.clusterCount
    }

    var fill: Double { 1 - Double(freeCount) / Double(partition.clusterCount) }

    /// Fichiers rangés dans l'ordre où un parcours de l'arborescence FAT les
    /// rencontre : répertoires dans l'ordre de leur première entrée, fichiers
    /// dans l'ordre de leur entrée de répertoire. C'est le seul ordre dont
    /// disposait le défragmenteur livré — il n'avait aucune autre information.
    func directoryWalkOrder() -> [VolumeFile] {
        var firstEntry: [String: Int] = [:]
        for file in files.values {
            let dir = file.directory
            if let existing = firstEntry[dir] { firstEntry[dir] = min(existing, file.created) }
            else { firstEntry[dir] = file.created }
        }
        return files.values.sorted {
            let a = firstEntry[$0.directory] ?? 0
            let b = firstEntry[$1.directory] ?? 0
            return a != b ? a < b : $0.created < $1.created
        }
    }

    // MARK: - Carte

    func categoryMap() -> [UInt8] {
        var map = [UInt8](repeating: ClusterCategory.free.rawValue, count: partition.clusterCount)
        for file in files.values {
            let raw = file.kind.rawValue
            for cluster in file.chain { map[cluster] = raw }
        }
        return map
    }

    var fragmentedFileCount: Int { files.values.filter { !$0.isContiguous }.count }

    var extentsPerFile: Double {
        guard !files.isEmpty else { return 0 }
        let total = files.values.reduce(0) { $0 + $1.extents.count }
        return Double(total) / Double(files.count)
    }

    /// Nombre de trous distincts dans l'espace libre — la mesure qui dit à quel
    /// point le volume va fragmenter le prochain fichier écrit.
    var freeHoleCount: Int {
        var holes = 0
        var inHole = false
        for value in owner {
            if value < 0 {
                if !inHole { holes += 1; inHole = true }
            } else {
                inHole = false
            }
        }
        return holes
    }

    // MARK: - Allocation

    private func findFree(from start: Int) -> Int? {
        let n = partition.clusterCount
        var i = start % n
        for _ in 0..<n {
            if owner[i] < 0 { return i }
            i = (i + 1) % n
        }
        return nil
    }

    @discardableResult
    private func allocate(_ count: Int, to id: Int) -> [Int] {
        guard count <= freeCount else { return [] }
        var result: [Int] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard let c = findFree(from: cursor) else { break }
            owner[c] = Int32(id)
            freeCount -= 1
            result.append(c)
            cursor = (c + 1) % partition.clusterCount
        }
        return result
    }

    // MARK: - Opérations de système de fichiers

    @discardableResult
    func create(path: String, kind: ClusterCategory, bytes: Int) -> Int? {
        let need = partition.clusters(forBytes: bytes)
        guard need <= freeCount else { return nil }
        let id = nextID
        nextID += 1
        let chain = allocate(need, to: id)
        guard chain.count == need else { return nil }
        files[id] = VolumeFile(id: id, path: path, kind: kind, created: sequence, chain: chain)
        sequence += 1
        return id
    }

    func append(_ id: Int, bytes: Int) {
        guard var file = files[id] else { return }
        let before = file.chain.count
        let after = partition.clusters(forBytes: before * partition.clusterBytes + bytes)
        let extra = after - before
        guard extra > 0, extra <= freeCount else { return }
        file.chain.append(contentsOf: allocate(extra, to: id))
        files[id] = file
    }

    func delete(_ id: Int) {
        guard let file = files.removeValue(forKey: id) else { return }
        for cluster in file.chain {
            owner[cluster] = -1
            freeCount += 1
        }
    }

    /// Ajoute un fichier dont le placement est **déjà décidé**.
    ///
    /// C'est par là qu'entre un volume construit ailleurs — par le générateur
    /// de disques d'époque — sans repasser par l'allocateur : les clusters sont
    /// ceux qu'il a choisis, et le volume les enregistre tels quels.
    @discardableResult
    func adopt(path: String, kind: ClusterCategory, chain: [Int]) -> Int? {
        guard !chain.isEmpty else { return nil }
        let id = nextID
        nextID += 1
        for cluster in chain {
            guard cluster >= 0, cluster < partition.clusterCount else { return nil }
            if owner[cluster] < 0 { freeCount -= 1 }
            owner[cluster] = Int32(id)
        }
        files[id] = VolumeFile(id: id, path: path, kind: kind, created: sequence, chain: chain)
        sequence += 1
        cursor = (chain[chain.count - 1] + 1) % partition.clusterCount
        return id
    }

    func file(id: Int) -> VolumeFile? { files[id] }

    func fileID(atPath path: String) -> Int? {
        files.first { $0.value.path == path }?.key
    }

    /// Réécrit la chaîne d'un fichier après déplacement. Les clusters libérés et
    /// les clusters pris sont mis à jour d'un bloc : c'est ce que fait un
    /// défragmenteur quand il valide un déplacement dans la FAT.
    func rewrite(_ id: Int, chain newChain: [Int]) {
        guard var file = files[id] else { return }
        for cluster in file.chain where owner[cluster] == Int32(id) {
            owner[cluster] = -1
            freeCount += 1
        }
        for cluster in newChain {
            if owner[cluster] < 0 { freeCount -= 1 }
            owner[cluster] = Int32(id)
        }
        file.chain = newChain
        files[id] = file
    }

    func ownerOf(_ cluster: Int) -> Int? {
        let value = owner[cluster]
        return value < 0 ? nil : Int(value)
    }
}
