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
    /// Hors zone de données : secteur d'amorçage, tables d'allocation, racine.
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
        case .reserved:    return "FAT, racine"
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

/// Géométrie d'une partition FAT16 posée sur le disque.
///
/// Le calcul du nombre de clusters est circulaire — la taille de la FAT dépend
/// du nombre de clusters, qui dépend de la place restante après la FAT — et se
/// résout par quelques itérations, exactement comme le fait `FORMAT`.
struct PartitionGeometry {

    let startLBA: Int
    let clusterSectors: Int
    let clusterCount: Int
    let fatSectors: Int

    private static let reservedSectors = 1   // secteur d'amorçage
    private static let rootSectors = 32      // 512 entrées de racine

    init(startLBA: Int, sectors: Int, clusterSectors: Int) {
        self.startLBA = startLBA
        self.clusterSectors = clusterSectors

        let overhead = Self.reservedSectors + Self.rootSectors
        var n = (sectors - overhead) / clusterSectors
        var fat = 0
        for _ in 0..<3 {
            fat = Int(ceil(Double(n) * 2 / Double(DriveGeometry.bytesPerSector)))
            n = (sectors - overhead - 2 * fat) / clusterSectors
        }
        self.fatSectors = fat
        self.clusterCount = n
        precondition(n > 0 && n < 65_525, "hors des bornes FAT16")
    }

    var fat1LBA: Int { startLBA + Self.reservedSectors }
    var fat2LBA: Int { fat1LBA + fatSectors }
    var rootLBA: Int { fat2LBA + fatSectors }
    var dataStartLBA: Int { rootLBA + Self.rootSectors }
    var rootSectorCount: Int { Self.rootSectors }

    var clusterBytes: Int { clusterSectors * DriveGeometry.bytesPerSector }
    var capacityBytes: Int { clusterCount * clusterBytes }

    func lba(ofCluster cluster: Int) -> Int {
        dataStartLBA + cluster * clusterSectors
    }

    /// Secteur de la FAT qui décrit ce cluster : deux octets par cluster.
    func fatSector(forCluster cluster: Int) -> Int {
        cluster * 2 / DriveGeometry.bytesPerSector
    }

    func clusters(forBytes bytes: Int) -> Int {
        max(1, Int(ceil(Double(bytes) / Double(clusterBytes))))
    }

    var capacityDescription: String {
        String(format: "%.0f Mo", Double(capacityBytes) / 1_000_000)
    }
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

// MARK: - Vieillissement

/// Fabrique un volume tel qu'on le trouvait après deux ans d'usage : une
/// installation propre, puis des mois de création, suppression et extension de
/// fichiers, qui suffisent à disperser les fichiers de démarrage sur tout le
/// volume sans qu'aucun mécanisme exotique n'intervienne.
enum VolumeFactory {

    /// Part de la capacité occupée par chaque famille de fichiers à l'issue de
    /// l'installation. Le vieillissement ajoute ensuite son propre régime
    /// permanent de temporaires, et les documents grossissent : le volume finit
    /// aux alentours de 80 % de remplissage.
    private struct Budget {
        let directory: String
        let extension_: String
        let kind: ClusterCategory
        let share: Double
        let sizes: ClosedRange<Int>
    }

    private static let install: [Budget] = [
        Budget(directory: "\\WINDOWS", extension_: "BIN", kind: .system,
               share: 0.15, sizes: 8_000...900_000),
        Budget(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", kind: .system,
               share: 0.15, sizes: 6_000...600_000),
        Budget(directory: "\\WINDOWS\\HELP", extension_: "HLP", kind: .archive,
               share: 0.05, sizes: 40_000...1_400_000),
        Budget(directory: "\\PROGRA~1\\MSOFFICE", extension_: "DLL", kind: .application,
               share: 0.12, sizes: 20_000...2_200_000),
        Budget(directory: "\\PROGRA~1\\NETSCAPE", extension_: "DLL", kind: .application,
               share: 0.05, sizes: 15_000...1_500_000),
        Budget(directory: "\\MYDOCU~1", extension_: "DOC", kind: .document,
               share: 0.07, sizes: 12_000...900_000),
    ]

    /// Part de la capacité occupée par le fichier d'échange.
    private static let swapShare = 0.06

    /// Remplissage de référence des parts ci-dessus, avant mise à l'échelle.
    private static let referenceFill = 0.80

    /// - Parameter fill: taux de remplissage entretenu par l'utilisateur au fil
    ///   des mois. Toutes les parts d'installation sont mises à l'échelle pour
    ///   l'atteindre, et les temporaires sont purgés dès qu'il est dépassé.
    static func agedWindows95(partition: PartitionGeometry,
                              fill: Double = 0.80,
                              seed: UInt64 = 0x5EED_1995,
                              days: Int = 220) -> Volume {
        let fillCeiling = fill
        let scale = fill / referenceFill
        let volume = Volume(partition: partition)
        var rng = SeededGenerator(seed: seed)
        let capacity = Double(partition.capacityBytes)

        /// Distribution très dissymétrique : beaucoup de petits fichiers,
        /// quelques gros. Une loi uniforme donnerait un volume irréaliste.
        func size(_ range: ClosedRange<Int>, _ rng: inout SeededGenerator) -> Int {
            let u = Double.random(in: 0..<1, using: &rng)
            return range.lowerBound + Int(pow(u, 2.4) * Double(range.upperBound - range.lowerBound))
        }

        // 1. Installation de MS-DOS puis de Windows, répertoire par répertoire.
        //    L'ordre de création est celui du parcours de l'arborescence — c'est
        //    lui que suivra le défragmenteur.
        volume.create(path: "\\IO.SYS", kind: .system, bytes: 223_148)
        volume.create(path: "\\MSDOS.SYS", kind: .system, bytes: 1_676)
        volume.create(path: "\\COMMAND.COM", kind: .system, bytes: 93_890)

        var documentPaths: [String] = []
        for budget in install {
            var remaining = Int(capacity * budget.share * scale)
            var index = 0
            while remaining > 0 {
                let bytes = min(size(budget.sizes, &rng), remaining)
                let path = String(format: "%@\\F%04d.%@", budget.directory, index, budget.extension_)
                guard volume.create(path: path, kind: budget.kind, bytes: bytes) != nil else { break }
                if budget.kind == .document { documentPaths.append(path) }
                remaining -= max(bytes, partition.clusterBytes)
                index += 1
            }
        }

        // 2. Le fichier d'échange, créé au premier démarrage de Windows : il
        //    tombe donc après l'installation, au milieu du volume, et Windows le
        //    gardera ouvert — le défragmenteur ne pourra pas y toucher.
        volume.create(path: "\\WIN386.SWP", kind: .swap, bytes: Int(capacity * swapShare * scale))

        // 3. Deux ans d'usage. Chaque « journée » crée des temporaires et du
        //    cache, en supprime, et fait grossir quelques documents.
        var churnFiles: [Int] = []
        var churnCounter = 0
        let churnScale = max(capacity / 400_000_000, 0.15)
        // Croissance totale des documents sur la période, en octets. Sans ce
        // budget les réenregistrements saturent le volume et ne laissent plus
        // de place au cache — or c'est le cache qui fragmente le plus.
        var growthBudget = Int(capacity * 0.04)

        for day in 0..<days {
            // Régime permanent : un volume réel n'est jamais rempli à ras bord,
            // l'utilisateur fait de la place dès qu'il manque d'espace. C'est
            // cette limite qui fixe le taux de remplissage final.
            while volume.fill > fillCeiling, !churnFiles.isEmpty {
                let index = rng.uniform(0...(churnFiles.count - 1))
                volume.delete(churnFiles.remove(at: index))
            }

            let creations = volume.fill < fillCeiling
                ? max(Int(Double(rng.uniform(4...14)) * churnScale), 1) : 0
            for _ in 0..<creations {
                let isCache = rng.chance(0.65)
                let path = isCache
                    ? String(format: "\\WINDOWS\\TEMPOR~1\\C%05d.TMP", churnCounter)
                    : String(format: "\\WINDOWS\\TEMP\\T%05d.TMP", churnCounter)
                churnCounter += 1
                let bytes = isCache ? size(2_000...90_000, &rng) : size(4_000...700_000, &rng)
                if let id = volume.create(path: path, kind: .churn, bytes: bytes) {
                    churnFiles.append(id)
                }
            }

            // Le cache et les temporaires sont purgés en permanence : ce sont
            // eux qui creusent les trous dans lesquels tombera tout le reste.
            let deletions = min(churnFiles.count, max(Int(Double(rng.uniform(3...12)) * churnScale), 1))
            for _ in 0..<deletions where !churnFiles.isEmpty {
                let index = rng.uniform(0...(churnFiles.count - 1))
                volume.delete(churnFiles.remove(at: index))
            }

            // Extensions : un document rouvert et réenregistré, un journal qui
            // grossit. L'allocateur next-fit place la suite très loin du début.
            if !documentPaths.isEmpty, growthBudget > 0, volume.fill < fillCeiling {
                for _ in 0..<rng.uniform(2...7) where growthBudget > 0 {
                    let path = documentPaths[rng.uniform(0...(documentPaths.count - 1))]
                    let bytes = min(size(4_000...260_000, &rng), growthBudget)
                    if let id = volume.fileID(atPath: path) {
                        volume.append(id, bytes: bytes)
                        growthBudget -= bytes
                    }
                }
            }

            // Mise à jour trimestrielle : quelques fichiers système réécrits,
            // donc supprimés puis recréés ailleurs.
            if day % 55 == 40 {
                let systemPaths = volume.files.values
                    .filter { $0.kind == .system && $0.directory.hasSuffix("SYSTEM") }
                    .map(\.path)
                    .sorted()   // l'ordre d'un dictionnaire n'est pas reproductible
                guard !systemPaths.isEmpty else { continue }
                for _ in 0..<rng.uniform(6...18) {
                    let path = systemPaths[rng.uniform(0...(systemPaths.count - 1))]
                    if let id = volume.fileID(atPath: path), let old = volume.file(id: id) {
                        let bytes = old.chain.count * partition.clusterBytes
                        volume.delete(id)
                        volume.create(path: path, kind: .system,
                                      bytes: bytes + size(0...120_000, &rng))
                    }
                }
            }
        }

        return volume
    }
}
