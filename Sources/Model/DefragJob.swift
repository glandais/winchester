import Foundation
import DiskCore

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
        /// Validation d'un déplacement : tables d'allocation et entrée de
        /// répertoire sur FAT, enregistrement MFT sur NTFS.
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
    /// Plage de `DefragPlan.mutations` que cette opération applique.
    ///
    /// Les mutations sont rangées à plat dans le plan et non dans chaque
    /// opération : une passe sur un volume de 6 Go en compte un million, et un
    /// million de petits tableaux Swift coûtait à lui seul plusieurs centaines
    /// de mégaoctets — pour une ou deux mutations par opération.
    let mutationStart: Int32
    let mutationCount: Int32

    init(kind: Kind, phase: Int, lba: Int, sectors: Int, isWrite: Bool,
         issueTime: Double, cluster: Int?,
         mutationStart: Int32 = 0, mutationCount: Int32 = 0) {
        self.kind = kind
        self.phase = phase
        self.lba = lba
        self.sectors = sectors
        self.isWrite = isWrite
        self.issueTime = issueTime
        self.cluster = cluster
        self.mutationStart = mutationStart
        self.mutationCount = mutationCount
    }
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
    /// Toutes les mutations de la carte, à plat. Chaque opération en désigne
    /// une tranche.
    let mutations: [MapMutation]
    let phases: [PhaseDescriptor]
    let before: VolumeStats
    let after: VolumeStats
    let movedBytes: Int
    let filesMoved: Int
    let filesAlreadyInPlace: Int
    let evacuations: Int

    /// Le même plan, sans les opérations ni les mutations.
    ///
    /// Une fois la passe simulée et datée, l'écran n'a plus besoin que de la
    /// carte de départ et des compteurs. Les opérations, elles, se comptent en
    /// millions sur un volume d'époque réellement dimensionné.
    func summarized() -> DefragPlan {
        DefragPlan(partition: partition, initialMap: initialMap,
                   operations: [], mutations: [], phases: phases,
                   before: before, after: after, movedBytes: movedBytes,
                   filesMoved: filesMoved, filesAlreadyInPlace: filesAlreadyInPlace,
                   evacuations: evacuations)
    }
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
/// - chaque déplacement validé réécrit les métadonnées, dont l'emplacement
///   dépend du format : sur FAT, les deux copies de la table et l'entrée de
///   répertoire, toutes trois au tout début de la partition. D'où le retour
///   systématique du bras vers le bord du plateau, à peu près une fois par
///   fichier : le « clac … clac … clac » régulier d'une défragmentation.
///
/// Le fichier d'échange n'est pas déplaçable : Windows l'a ouvert, et le
/// défragmenteur tasse tout autour de lui.
///
/// Tout le travail se fait en **extents** et jamais cluster par cluster : c'est
/// ce qui permet de planifier une passe sur un volume de 320 Go, où les 80
/// millions de clusters ne portent en tout que 178 000 extents.
enum DefragPlanner {

    /// Tampon de déplacement. L'outil d'époque travaillait sur quelques
    /// centaines de kilo-octets à la fois : c'est cette taille qui fixe le
    /// rythme des allers-retours lecture/écriture, donc le tempo de la passe.
    static let bufferBytes = 256 * 1024

    static let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Lecture des tables d'allocation et parcours de l'arborescence"),
        PhaseDescriptor(id: "system", label: "Fichiers système",
                        detail: "\\WINDOWS — les premiers du parcours, souvent déjà en place"),
        PhaseDescriptor(id: "apps", label: "Applications",
                        detail: "\\PROGRA~1 — gros fichiers, évacuations en cascade"),
        PhaseDescriptor(id: "docs", label: "Documents",
                        detail: "Fichiers réenregistrés des dizaines de fois, très éclatés"),
        PhaseDescriptor(id: "churn", label: "Temporaires et cache",
                        detail: "Des milliers de fragments d'un cluster : le martèlement"),
        PhaseDescriptor(id: "commit", label: "Écriture des tables d'allocation",
                        detail: "Réécriture complète des tables et de la racine"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le volume ne tourne plus que pour lui-même"),
    ]

    static func plan(volume input: DefragVolume) -> DefragPlan {

        var volume = input
        let partition = volume.partition
        let total = UInt32(partition.clusterCount)
        let before = volume.stats
        let initialMap = volume.categoryMap()

        // Trois opérations par fichier au minimum — une lecture, une écriture,
        // une validation — et bien plus dès que les fichiers sont éclatés.
        var operations: [DiskOperation] = []
        operations.reserveCapacity(volume.files.count * 8)
        var mutations: [MapMutation] = []
        mutations.reserveCapacity(volume.files.count * 8)
        var movedClusters = 0
        var filesMoved = 0
        var alreadyInPlace = 0
        var evacuations = 0

        // MARK: Phase 0 — analyse

        operations.append(contentsOf: analysisOperations(partition: partition,
                                                         directoryCount: directoryCount(of: volume)))

        // MARK: Clusters intouchables

        // Ils tiennent en quelques extents — le fichier d'échange, et lui seul :
        // aucune raison d'en faire un tableau de booléens de la taille du volume.
        let blocked = volume.files
            .filter { !$0.isMovable }
            .flatMap(\.extents)
            .sorted { $0.start < $1.start }

        // MARK: Empaquetage

        var frontier: UInt32 = 0
        var phase = 1

        for position in volume.files.indices {
            let file = volume.files[position]
            guard file.isMovable, file.clusterCount > 0 else { continue }
            phase = max(phase, file.category.packingGroup + 1)

            let need = file.clusterCount
            guard let destination = destination(from: frontier, need: need,
                                                blocked: blocked, total: total)
            else { break }
            let target = Extent(start: destination, length: need)

            // Déjà contigu et déjà au bon endroit : le défragmenteur ne le
            // touche pas. C'est pour cela qu'une passe démarre dans le calme,
            // puis s'emballe dès qu'elle atteint la zone remuée.
            if file.extents.count == 1 && file.extents[0] == target {
                frontier = target.end
                alreadyInPlace += 1
                continue
            }

            // 1. Évacuer ce qui occupe la destination.
            let reserved = frontier..<target.end
            for occupantPosition in volume.occupants(of: target.start..<target.end)
            where occupantPosition != position {
                let occupant = volume.files[occupantPosition]
                guard occupant.isMovable else { continue }
                guard let refuge = freeRuns(in: volume, count: occupant.clusterCount,
                                            from: target.end, excluding: reserved, total: total)
                else { continue }

                moveOperations(source: occupant.extents, destination: refuge,
                               category: occupant.category, phase: phase,
                               partition: partition, into: &operations, mutations: &mutations)
                commitOperations(cluster: Int(refuge[0].start), fileIndex: occupantPosition,
                                 phase: phase, partition: partition, into: &operations)
                volume.relocate(occupantPosition, to: refuge)
                movedClusters += Int(occupant.clusterCount)
                evacuations += 1
            }

            // 2. Déplacer le fichier vers sa destination définitive.
            moveOperations(source: volume.files[position].extents, destination: [target],
                           category: file.category, phase: phase,
                           partition: partition, into: &operations, mutations: &mutations)
            commitOperations(cluster: Int(target.start), fileIndex: position,
                             phase: phase, partition: partition, into: &operations)
            volume.relocate(position, to: [target])
            movedClusters += Int(need)
            filesMoved += 1

            frontier = target.end
        }

        // MARK: Phase finale — réécriture complète des tables

        operations.append(contentsOf: finalOperations(partition: partition, phase: 5))

        return DefragPlan(
            partition: partition,
            initialMap: initialMap,
            operations: operations,
            mutations: mutations,
            phases: phases,
            before: before,
            after: volume.stats,
            movedBytes: movedClusters * partition.clusterBytes,
            filesMoved: filesMoved,
            filesAlreadyInPlace: alreadyInPlace,
            evacuations: evacuations
        )
    }

    // MARK: - Fabriques d'opérations

    /// L'analyse lit les tables d'allocation, la racine, puis chaque
    /// répertoire. Elle est étalée sur quelques secondes : à l'époque le coût
    /// dominant n'était pas le disque mais le parcours des chaînes en mémoire.
    private static func analysisOperations(partition: PartitionGeometry,
                                           directoryCount: Int) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        let span = 4.5

        for (index, access) in partition.scanAccesses.enumerated() {
            ops.append(DiskOperation(kind: .scan, phase: 0, lba: access.lba,
                                     sectors: access.sectors, isWrite: false,
                                     issueTime: 0.30 + 0.45 * Double(index),
                                     cluster: nil))
        }

        // Parcours des répertoires : leurs clusters sont dispersés dans la zone
        // de données, chaque lecture est un seek isolé au milieu du silence.
        var rng = SeededGenerator(seed: 0xDEF7_A61C)
        let count = max(directoryCount, 1)
        for index in 0..<count {
            let t = 2.0 + span * Double(index) / Double(count) * 0.55
            let cluster = rng.uniform(0...(partition.clusterCount - 1))
            ops.append(DiskOperation(kind: .scan, phase: 0,
                                     lba: partition.lba(ofCluster: cluster),
                                     sectors: partition.clusterSectors, isWrite: false,
                                     issueTime: t, cluster: cluster))
        }
        return ops
    }

    /// Déplacement d'une suite d'extents vers une autre, par tampons successifs.
    ///
    /// Chaque tampon est une lecture d'une portion de la source suivie de
    /// l'écriture de la portion de destination correspondante. Les deux
    /// découpages ne coïncident jamais — c'est tout le problème d'un fichier
    /// fragmenté — d'où le pas à pas sur la plus longue portion contiguë des
    /// deux côtés, plafonnée à la taille du tampon.
    private static func moveOperations(source: [Extent],
                                       destination: [Extent],
                                       category: ClusterCategory,
                                       phase: Int,
                                       partition: PartitionGeometry,
                                       into ops: inout [DiskOperation],
                                       mutations store: inout [MapMutation]) {
        let buffer = UInt32(max(bufferBytes / partition.clusterBytes, 1))

        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var destinationIndex = 0
        var destinationOffset: UInt32 = 0

        // Ce que la destination recouvre de la source : ces clusters-là ne
        // repassent pas en « libre », ils changent simplement de contenu.
        let kept = destination

        while sourceIndex < source.count && destinationIndex < destination.count {
            let from = source[sourceIndex]
            let to = destination[destinationIndex]
            let length = min(from.length - sourceOffset, to.length - destinationOffset, buffer)
            guard length > 0 else { break }

            let readStart = from.start + sourceOffset
            let writeStart = to.start + destinationOffset

            ops.append(DiskOperation(
                kind: .readExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(readStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: false, issueTime: 0, cluster: Int(readStart)))

            let first = Int32(store.count)
            store.append(MapMutation(start: Int(writeStart), count: Int(length),
                                     category: category))
            store.append(contentsOf: freedMutations(start: readStart, length: length, kept: kept))

            ops.append(DiskOperation(
                kind: .writeExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(writeStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: true, issueTime: 0, cluster: Int(writeStart),
                mutationStart: first, mutationCount: Int32(store.count) - first))

            sourceOffset += length
            destinationOffset += length
            if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
            if destinationOffset == to.length { destinationIndex += 1; destinationOffset = 0 }
        }
    }

    /// Les clusters d'une portion de source qui redeviennent libres : tout ce
    /// qui n'est pas recouvert par la destination du même fichier.
    private static func freedMutations(start: UInt32, length: UInt32,
                                       kept: [Extent]) -> [MapMutation] {
        var mutations: [MapMutation] = []
        var cursor = start
        let end = start + length

        while cursor < end {
            // Le premier extent conservé qui couvre `cursor` ?
            if let covering = kept.first(where: { $0.start <= cursor && $0.end > cursor }) {
                cursor = min(covering.end, end)
                continue
            }
            // Jusqu'où peut-on libérer sans heurter un extent conservé ?
            let next = kept.filter { $0.start > cursor }.map(\.start).min() ?? end
            let stop = min(next, end)
            if stop > cursor {
                mutations.append(MapMutation(start: Int(cursor), count: Int(stop - cursor),
                                             category: .free))
            }
            cursor = max(stop, cursor + 1)
        }
        return mutations
    }

    /// Validation d'un déplacement — ce que le format fait payer, et où.
    private static func commitOperations(cluster: Int,
                                         fileIndex: Int,
                                         phase: Int,
                                         partition: PartitionGeometry,
                                         into ops: inout [DiskOperation]) {
        for access in partition.commitAccesses(forCluster: cluster, fileIndex: fileIndex) {
            ops.append(DiskOperation(kind: .metadata, phase: phase, lba: access.lba,
                                     sectors: access.sectors, isWrite: true,
                                     issueTime: 0, cluster: nil))
        }
    }

    private static func finalOperations(partition: PartitionGeometry,
                                        phase: Int) -> [DiskOperation] {
        var ops = partition.finalAccesses.map {
            DiskOperation(kind: .metadata, phase: phase, lba: $0.lba, sectors: $0.sectors,
                          isWrite: true, issueTime: 0, cluster: nil)
        }
        // Une dernière relecture, pour le point final.
        if let first = partition.finalAccesses.first {
            ops.append(DiskOperation(kind: .scan, phase: phase, lba: first.lba,
                                     sectors: first.sectors, isWrite: false,
                                     issueTime: 0, cluster: nil))
        }
        return ops
    }

    // MARK: - Placement

    /// Première position ≥ `from` où `need` clusters consécutifs ne heurtent
    /// aucun cluster intouchable.
    private static func destination(from: UInt32, need: UInt32,
                                    blocked: [Extent], total: UInt32) -> UInt32? {
        var start = from
        while UInt64(start) + UInt64(need) <= UInt64(total) {
            if let hit = blocked.first(where: { $0.start < start + need && $0.end > start }) {
                start = hit.end
            } else {
                return start
            }
        }
        return nil
    }

    /// Des clusters libres où évacuer un occupant : au-delà de la zone en cours
    /// d'empaquetage, et sans toucher à la destination en préparation.
    ///
    /// L'occupant ressort souvent en plusieurs morceaux, et c'est normal : il
    /// n'est là qu'en transit, et sera relu puis redéplacé quand viendra son
    /// tour dans le parcours.
    private static func freeRuns(in volume: DefragVolume, count: UInt32,
                                 from: UInt32, excluding reserved: Range<UInt32>,
                                 total: UInt32) -> [Extent]? {
        var result: [Extent] = []
        var remaining = count
        var cursor = max(from, reserved.upperBound)

        while remaining > 0, cursor < total {
            guard let run = volume.bitmap.nextFreeRun(from: cursor) else { break }
            guard run.start < total else { break }
            let take = min(run.length, remaining)
            result.append(Extent(start: run.start, length: take))
            remaining -= take
            cursor = run.start + run.length
        }
        return remaining == 0 ? result : nil
    }

    // MARK: - Mesures

    private static func directoryCount(of volume: DefragVolume) -> Int {
        var directories = Set<String>()
        for file in volume.files {
            guard let slash = file.path.lastIndex(of: "\\") else { continue }
            directories.insert(String(file.path[file.path.startIndex..<slash]))
        }
        return max(directories.count, 1)
    }

    static func stats(of volume: DefragVolume) -> VolumeStats { volume.stats }
}
