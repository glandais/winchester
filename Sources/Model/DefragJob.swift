import Foundation

/// Modification de la carte des clusters, datée après coup par la simulation.
struct MapMutation {
    let start: Int
    let count: Int
    let category: ClusterCategory
}

/// Une requête bloc enrichie de ce qu'elle veut dire pour la carte et pour
/// l'affichage. Le simulateur ne consomme que `lba` / `sectors` / `isWrite` ;
/// le reste sert à rejouer visuellement la passe.
struct DiskOperation {

    enum Kind {
        /// Lecture des tables et des répertoires, pendant l'analyse.
        case scan
        case readExtent
        case writeExtent
        /// Validation d'un déplacement : FAT et entrée de répertoire.
        case metadata
    }

    let kind: Kind
    let phase: Int
    let lba: Int
    let sectors: Int
    let isWrite: Bool
    /// Date d'émission imposée, ou 0 : dès que le disque se libère.
    let issueTime: Double
    let cluster: Int?
    let mutations: [MapMutation]
}

struct PhaseDescriptor: Identifiable {
    let id: String
    let label: String
    let detail: String
}

struct VolumeStats {
    let fill: Double
    let fragmentedFiles: Int
    let fileCount: Int
    let extentsPerFile: Double
    let freeHoles: Int

    var fragmentedRatio: Double {
        fileCount > 0 ? Double(fragmentedFiles) / Double(fileCount) : 0
    }
}

struct DefragPlan {
    let partition: PartitionGeometry
    let initialMap: [UInt8]
    let operations: [DiskOperation]
    let phases: [PhaseDescriptor]
    let before: VolumeStats
    let after: VolumeStats
    let movedBytes: Int
    let filesMoved: Int
    let filesAlreadyInPlace: Int
    let evacuations: Int
}

/// Planificateur d'une passe « défragmentation complète (fichiers et espace
/// libre) », la commande que proposait le défragmenteur livré avec Windows 95.
///
/// Le principe tient en une phrase : rendre chaque fichier contigu et le tasser
/// contre le début du volume, dans l'ordre du parcours de l'arborescence — le
/// seul ordre dont l'outil disposait. Deux conséquences qui s'entendent :
///
/// - la destination d'un fichier est presque toujours occupée par un autre, qui
///   doit d'abord être **évacué** vers l'espace libre de la fin du volume. Ce
///   fichier-là sera relu et redéplacé quand viendra son tour. C'est ce
///   va-et-vient, et non le volume de données, qui fait durer une passe ;
/// - chaque déplacement validé réécrit les deux copies de la FAT et l'entrée de
///   répertoire, toutes les trois au tout début de la partition. D'où le
///   retour systématique du bras vers le bord du plateau, à peu près une fois
///   par fichier : le « clac … clac … clac » régulier d'une défragmentation.
///
/// Le fichier d'échange n'est pas déplaçable : Windows l'a ouvert, et le
/// défragmenteur tasse tout autour de lui.
enum DefragPlanner {

    /// Tampon de déplacement. L'outil d'époque travaillait sur quelques
    /// centaines de kilo-octets à la fois : c'est cette taille qui fixe le
    /// rythme des allers-retours lecture/écriture, donc le tempo de la passe.
    static let bufferBytes = 256 * 1024

    static let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Lecture des deux FAT et parcours de l'arborescence"),
        PhaseDescriptor(id: "system", label: "Fichiers système",
                        detail: "\\WINDOWS — les premiers du parcours, souvent déjà en place"),
        PhaseDescriptor(id: "apps", label: "Applications",
                        detail: "\\PROGRA~1 — gros fichiers, évacuations en cascade"),
        PhaseDescriptor(id: "docs", label: "Documents",
                        detail: "Fichiers réenregistrés des dizaines de fois, très éclatés"),
        PhaseDescriptor(id: "churn", label: "Temporaires et cache",
                        detail: "Des milliers de fragments d'un cluster : le martèlement"),
        PhaseDescriptor(id: "commit", label: "Écriture des tables d'allocation",
                        detail: "Réécriture complète des deux FAT et de la racine"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le volume ne tourne plus que pour lui-même"),
    ]

    static func plan(volume: Volume) -> DefragPlan {

        let partition = volume.partition
        let initialMap = volume.categoryMap()
        let before = stats(of: volume)

        var operations: [DiskOperation] = []
        var movedClusters = 0
        var filesMoved = 0
        var alreadyInPlace = 0
        var evacuations = 0

        // MARK: Phase 0 — analyse

        operations.append(contentsOf: analysisOperations(partition: partition,
                                                         directoryCount: directoryCount(of: volume)))

        // MARK: Clusters intouchables

        var blocked = [Bool](repeating: false, count: partition.clusterCount)
        let swapIDs = volume.files.values.filter { $0.kind == .swap }.map(\.id)
        for id in swapIDs {
            for cluster in volume.file(id: id)?.chain ?? [] { blocked[cluster] = true }
        }

        // MARK: Empaquetage

        let order = volume.directoryWalkOrder()
        var frontier = 0
        var phase = 1

        for entry in order {
            guard entry.kind != .swap else { continue }
            guard let file = volume.file(id: entry.id) else { continue }
            phase = max(phase, file.kind.packingGroup + 1)

            let need = file.chain.count
            guard let destination = destination(from: frontier, need: need, blocked: blocked)
            else { break }

            // Déjà contigu et déjà au bon endroit : le défragmenteur ne le
            // touche pas. C'est pour cela qu'une passe démarre dans le calme,
            // puis s'emballe dès qu'elle atteint la zone remuée.
            if file.chain.first == destination && file.isContiguous {
                frontier = destination + need
                alreadyInPlace += 1
                continue
            }

            let destinationChain = Array(destination..<(destination + need))

            // 1. Évacuer ce qui occupe la destination.
            var occupants: [Int] = []
            for cluster in destinationChain {
                if let id = volume.ownerOf(cluster), id != file.id, !occupants.contains(id) {
                    occupants.append(id)
                }
            }
            for id in occupants {
                guard let occupant = volume.file(id: id) else { continue }
                let reservedLow = frontier
                let reservedHigh = destination + need
                guard let target = freeClusters(volume: volume,
                                                count: occupant.chain.count,
                                                from: reservedHigh,
                                                blocked: blocked,
                                                excludingBelow: reservedLow,
                                                excludingRange: reservedLow..<reservedHigh)
                else { continue }

                operations.append(contentsOf: moveOperations(chain: occupant.chain,
                                                             destination: target,
                                                             category: occupant.kind,
                                                             phase: phase,
                                                             partition: partition))
                operations.append(contentsOf: commitOperations(cluster: target[0],
                                                               phase: phase,
                                                               partition: partition))
                volume.rewrite(id, chain: target)
                movedClusters += occupant.chain.count
                evacuations += 1
            }

            // 2. Déplacer le fichier vers sa destination définitive.
            operations.append(contentsOf: moveOperations(chain: file.chain,
                                                         destination: destinationChain,
                                                         category: file.kind,
                                                         phase: phase,
                                                         partition: partition))
            operations.append(contentsOf: commitOperations(cluster: destination,
                                                           phase: phase,
                                                           partition: partition))
            volume.rewrite(file.id, chain: destinationChain)
            movedClusters += need
            filesMoved += 1

            frontier = destination + need
        }

        // MARK: Phase finale — réécriture complète des tables

        operations.append(contentsOf: commitAllOperations(partition: partition, phase: 5))

        return DefragPlan(
            partition: partition,
            initialMap: initialMap,
            operations: operations,
            phases: phases,
            before: before,
            after: stats(of: volume),
            movedBytes: movedClusters * partition.clusterBytes,
            filesMoved: filesMoved,
            filesAlreadyInPlace: alreadyInPlace,
            evacuations: evacuations
        )
    }

    // MARK: - Fabriques d'opérations

    /// L'analyse lit les deux copies de la FAT, la racine, puis chaque
    /// répertoire. Elle est étalée sur quelques secondes : à l'époque le coût
    /// dominant n'était pas le disque mais le parcours des chaînes en mémoire.
    private static func analysisOperations(partition: PartitionGeometry,
                                           directoryCount: Int) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        let span = 4.5

        ops.append(DiskOperation(kind: .scan, phase: 0, lba: partition.startLBA, sectors: 1,
                                 isWrite: false, issueTime: 0.30, cluster: nil, mutations: []))
        ops.append(DiskOperation(kind: .scan, phase: 0, lba: partition.fat1LBA,
                                 sectors: partition.fatSectors, isWrite: false,
                                 issueTime: 0.55, cluster: nil, mutations: []))
        ops.append(DiskOperation(kind: .scan, phase: 0, lba: partition.fat2LBA,
                                 sectors: partition.fatSectors, isWrite: false,
                                 issueTime: 1.20, cluster: nil, mutations: []))
        ops.append(DiskOperation(kind: .scan, phase: 0, lba: partition.rootLBA,
                                 sectors: partition.rootSectorCount, isWrite: false,
                                 issueTime: 1.70, cluster: nil, mutations: []))

        // Parcours des répertoires : leurs clusters sont dispersés dans la zone
        // de données, chaque lecture est un seek isolé au milieu du silence.
        var rng = SeededGenerator(seed: 0xDEF7_A61C)
        for index in 0..<max(directoryCount, 1) {
            let t = 2.0 + span * Double(index) / Double(max(directoryCount, 1)) * 0.55
            let cluster = rng.uniform(0...(partition.clusterCount - 1))
            ops.append(DiskOperation(kind: .scan, phase: 0,
                                     lba: partition.lba(ofCluster: cluster),
                                     sectors: partition.clusterSectors, isWrite: false,
                                     issueTime: t, cluster: cluster, mutations: []))
        }
        return ops
    }

    /// Déplacement d'une chaîne vers une autre, par tampons successifs.
    ///
    /// Chaque tampon est une lecture d'un fragment source suivie de l'écriture
    /// du fragment destination correspondant — les deux ne coïncident jamais,
    /// d'où le découpage sur la plus longue portion contiguë des deux côtés.
    private static func moveOperations(chain: [Int],
                                       destination: [Int],
                                       category: ClusterCategory,
                                       phase: Int,
                                       partition: PartitionGeometry) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        let bufferClusters = max(bufferBytes / partition.clusterBytes, 1)
        let destinationSet = Set(destination)
        var i = 0

        while i < chain.count {
            var length = 1
            while length < bufferClusters,
                  i + length < chain.count,
                  chain[i + length] == chain[i + length - 1] + 1,
                  destination[i + length] == destination[i + length - 1] + 1 {
                length += 1
            }

            ops.append(DiskOperation(
                kind: .readExtent, phase: phase,
                lba: partition.lba(ofCluster: chain[i]),
                sectors: length * partition.clusterSectors,
                isWrite: false, issueTime: 0, cluster: chain[i], mutations: []))

            // Les clusters source libérés qui ne servent pas de destination à ce
            // même fichier repassent en « libre » sur la carte.
            var mutations = [MapMutation(start: destination[i], count: length, category: category)]
            var freeStart: Int?
            var freeLength = 0
            for k in i..<(i + length) {
                if destinationSet.contains(chain[k]) {
                    if let start = freeStart {
                        mutations.append(MapMutation(start: start, count: freeLength, category: .free))
                        freeStart = nil
                        freeLength = 0
                    }
                } else if let start = freeStart, chain[k] == start + freeLength {
                    freeLength += 1
                } else {
                    if let start = freeStart {
                        mutations.append(MapMutation(start: start, count: freeLength, category: .free))
                    }
                    freeStart = chain[k]
                    freeLength = 1
                }
            }
            if let start = freeStart {
                mutations.append(MapMutation(start: start, count: freeLength, category: .free))
            }

            ops.append(DiskOperation(
                kind: .writeExtent, phase: phase,
                lba: partition.lba(ofCluster: destination[i]),
                sectors: length * partition.clusterSectors,
                isWrite: true, issueTime: 0, cluster: destination[i], mutations: mutations))

            i += length
        }
        return ops
    }

    /// Validation d'un déplacement : les deux copies de la FAT et l'entrée de
    /// répertoire, toutes au début de la partition.
    private static func commitOperations(cluster: Int,
                                         phase: Int,
                                         partition: PartitionGeometry) -> [DiskOperation] {
        let sector = partition.fatSector(forCluster: cluster)
        return [
            DiskOperation(kind: .metadata, phase: phase,
                          lba: partition.fat1LBA + sector, sectors: 2,
                          isWrite: true, issueTime: 0, cluster: nil, mutations: []),
            DiskOperation(kind: .metadata, phase: phase,
                          lba: partition.fat2LBA + sector, sectors: 2,
                          isWrite: true, issueTime: 0, cluster: nil, mutations: []),
            DiskOperation(kind: .metadata, phase: phase,
                          lba: partition.rootLBA + (cluster % partition.rootSectorCount),
                          sectors: 1,
                          isWrite: true, issueTime: 0, cluster: nil, mutations: []),
        ]
    }

    private static func commitAllOperations(partition: PartitionGeometry,
                                            phase: Int) -> [DiskOperation] {
        [
            DiskOperation(kind: .metadata, phase: phase, lba: partition.fat1LBA,
                          sectors: partition.fatSectors, isWrite: true,
                          issueTime: 0, cluster: nil, mutations: []),
            DiskOperation(kind: .metadata, phase: phase, lba: partition.fat2LBA,
                          sectors: partition.fatSectors, isWrite: true,
                          issueTime: 0, cluster: nil, mutations: []),
            DiskOperation(kind: .metadata, phase: phase, lba: partition.rootLBA,
                          sectors: partition.rootSectorCount, isWrite: true,
                          issueTime: 0, cluster: nil, mutations: []),
            DiskOperation(kind: .scan, phase: phase, lba: partition.fat1LBA,
                          sectors: partition.fatSectors, isWrite: false,
                          issueTime: 0, cluster: nil, mutations: []),
        ]
    }

    // MARK: - Placement

    /// Première position ≥ `from` où `need` clusters consécutifs ne heurtent
    /// aucun cluster intouchable.
    private static func destination(from: Int, need: Int, blocked: [Bool]) -> Int? {
        var start = from
        while start + need <= blocked.count {
            var conflict: Int?
            var index = start + need - 1
            while index >= start {
                if blocked[index] { conflict = index; break }
                index -= 1
            }
            guard let bad = conflict else { return start }
            start = bad + 1
        }
        return nil
    }

    /// Clusters libres où évacuer un occupant : au-delà de la zone déjà
    /// empaquetée et de la destination en cours de préparation.
    private static func freeClusters(volume: Volume,
                                     count: Int,
                                     from: Int,
                                     blocked: [Bool],
                                     excludingBelow: Int,
                                     excludingRange: Range<Int>) -> [Int]? {
        var result: [Int] = []
        result.reserveCapacity(count)
        var cluster = max(from, excludingBelow)
        let total = volume.partition.clusterCount

        while cluster < total && result.count < count {
            if !blocked[cluster], !excludingRange.contains(cluster), volume.ownerOf(cluster) == nil {
                result.append(cluster)
            }
            cluster += 1
        }
        return result.count == count ? result : nil
    }

    // MARK: - Mesures

    private static func directoryCount(of volume: Volume) -> Int {
        Set(volume.files.values.map(\.directory)).count
    }

    static func stats(of volume: Volume) -> VolumeStats {
        VolumeStats(fill: volume.fill,
                    fragmentedFiles: volume.fragmentedFileCount,
                    fileCount: volume.files.count,
                    extentsPerFile: volume.extentsPerFile,
                    freeHoles: volume.freeHoleCount)
    }
}
