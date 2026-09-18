import Foundation

/// Allocateur des systèmes FAT.
///
/// Toute la famille partage le même mécanisme — servir les premiers clusters
/// libres rencontrés, sans jamais rien réserver — et ne se distingue que par le
/// point de départ du scan. Cette seule différence produit deux textures
/// opposées :
///
/// - **à partir du début du volume** (MS-DOS, FAT16) : chaque trou est rebouché
///   à l'instant même où il s'ouvre. Le début du volume devient un gruyère
///   dense, les fichiers récents sont éclatés en miettes, et le scan complet
///   ramène systématiquement le bras vers le bord du plateau ;
/// - **à partir du dernier cluster alloué** (VFAT, puis le hint `next-free` de
///   FSINFO en FAT32) : l'écriture est globalement séquentielle et propre,
///   jusqu'au moment où le curseur atteint la fin du volume et repart au début.
///   Les trous laissés derrière sont alors remplis d'un coup, par-dessus des
///   fichiers d'âges très différents : la fragmentation arrive par vagues.
///
/// Aucune des deux ne réserve quoi que ce soit à la fin d'un fichier. C'est
/// pour cela qu'un `.doc` réenregistré finit en deux ou trois extents sur FAT
/// là où il reste contigu sur NTFS.
public struct FATAllocator: Allocator {

    public enum Scan: Sendable {
        /// Scan complet depuis le premier cluster de données, à chaque
        /// allocation. Le cluster 2 de la FAT, ici le cluster 0 : la bitmap ne
        /// représente que la zone de données.
        case fromVolumeStart
        /// Reprise au dernier cluster alloué, avec retour au début en fin de
        /// volume.
        case fromLastAllocated
    }

    public let profile: any FileSystemProfile
    public let scan: Scan
    public private(set) var bitmap: ClusterBitmap

    /// Le hint `next-free` : dernier cluster servi, plus un.
    public private(set) var nextFreeHint: UInt32 = 0

    /// Nombre de fois que le curseur est revenu au début du volume. Sans intérêt
    /// pour l'allocation, très parlant pour comprendre un volume FAT32 : chaque
    /// retour est une vague de fragmentation.
    public private(set) var wrapCount: Int = 0

    public init(profile: any FileSystemProfile, clusterCount: UInt32, scan: Scan) {
        precondition(profile.supports(clusterCount: clusterCount),
                     "\(profile.name) n'adresse pas \(clusterCount) clusters")
        self.profile = profile
        self.scan = scan
        self.bitmap = ClusterBitmap(clusterCount: clusterCount)
    }

    /// FAT16 tel que le servait MS-DOS.
    public static func fat16(clusterKB: UInt32, clusterCount: UInt32) -> FATAllocator {
        FATAllocator(profile: FAT16Profile(clusterKB: clusterKB),
                     clusterCount: clusterCount,
                     scan: .fromVolumeStart)
    }

    /// FAT16 servi par VFAT, le pilote de Windows 95 : le format est celui de
    /// MS-DOS, la stratégie est déjà celle de FAT32.
    public static func vfat(clusterKB: UInt32, clusterCount: UInt32) -> FATAllocator {
        FATAllocator(profile: FAT16Profile(clusterKB: clusterKB),
                     clusterCount: clusterCount,
                     scan: .fromLastAllocated)
    }

    public static func fat32(clusterKB: UInt32 = 4, clusterCount: UInt32) -> FATAllocator {
        FATAllocator(profile: FAT32Profile(clusterKB: clusterKB),
                     clusterCount: clusterCount,
                     scan: .fromLastAllocated)
    }

    // MARK: - Allocation

    private var wraps: Bool { scan == .fromLastAllocated }

    private func origin(for hint: AllocationHint) -> UInt32 {
        switch hint {
        // `IO.SYS` doit tomber au premier cluster libre du volume, quel que soit
        // l'état du curseur : c'est une contrainte du chargeur d'amorçage, pas
        // une préférence.
        case .boot: return 0
        // `.system` n'est pas cette contrainte-là. C'est le hint de
        // `FileCategory.systemCore`, c'est-à-dire de **toutes** les DLL, de tous
        // les pilotes et de tous les fichiers des vagues de mise à jour — une
        // population que ni VFAT ni FAT32 ne distinguent du reste : ils servent
        // leur curseur `next-free`, pour tout le monde. Le forcer au cluster 0
        // re-mitait le devant du volume en permanence, par un mécanisme qui n'a
        // jamais existé.
        case .system, .normal, .temporary, .reservedContiguous:
            return scan == .fromVolumeStart ? 0 : nextFreeHint
        }
    }

    public mutating func allocate(clusterCount count: UInt32, hint: AllocationHint) -> [Extent] {
        guard count > 0, count <= bitmap.freeCount else { return [] }
        let start = origin(for: hint)

        if hint == .reservedContiguous {
            // Le fichier d'échange à taille fixe est posé d'un seul tenant, dans
            // le premier trou capable de l'accueillir. S'il n'y en a plus, le
            // volume est trop mité pour ce fichier-là et on le morcelle comme le
            // reste — c'est ce que faisait Windows quand il n'avait plus le
            // choix.
            if let run = bitmap.firstFitRun(minLength: count, maxLength: count,
                                            from: start, wrap: wraps) {
                take(run, from: start)
                return [run]
            }
        }

        var extents: [Extent] = []
        var remaining = count
        var position = start
        var wrapped = false

        while remaining > 0 {
            guard let run = bitmap.firstFitRun(minLength: 1, maxLength: remaining,
                                               from: position, wrap: wraps && !wrapped)
            else { break }

            if run.start < position && !wrapped { wrapped = true; wrapCount += 1 }
            bitmap.allocate(run)
            extents.appendRun(start: run.start, length: run.length)
            remaining -= run.length
            position = run.end
            if position >= bitmap.clusterCount {
                // Le curseur a atteint la fin du volume : c'est le retour au
                // début, celui qui fait repasser l'écriture par-dessus des trous
                // laissés par des fichiers bien plus anciens.
                position = 0
                if !wrapped { wrapped = true; wrapCount += 1 }
            }
        }

        guard remaining == 0 else {
            // Tout ou rien : un fichier à moitié écrit n'existe pas.
            bitmap.free(extents)
            return []
        }
        nextFreeHint = position
        return extents
    }

    private mutating func take(_ run: Extent, from origin: UInt32) {
        if run.start < origin { wrapCount += 1 }
        bitmap.allocate(run)
        nextFreeHint = run.end >= bitmap.clusterCount ? 0 : run.end
    }

    /// FAT ne réserve rien : agrandir un fichier, c'est allouer à nouveau, là où
    /// le curseur se trouve. La suite d'un fichier peut donc atterrir à l'autre
    /// bout du volume, et c'est exactement ce qui est arrivé à tous les
    /// documents réenregistrés de l'époque.
    @discardableResult
    public mutating func extend(file: inout FileEntry, byClusters count: UInt32) -> Bool {
        guard count > 0 else { return true }
        let added = allocate(clusterCount: count, hint: file.hint)
        guard !added.isEmpty else { return false }
        file.extents.append(contentsOf: added)
        file.extents = file.extents.coalesced()
        return true
    }


    /// Prise d'une plage imposée, pour un défragmenteur.
    @discardableResult
    public mutating func claim(_ extent: Extent) -> Bool {
        guard bitmap.isFree(extent) else { return false }
        bitmap.allocate(extent)
        return true
    }

    /// Libération immédiate. En scan depuis le début, le trou ainsi ouvert sera
    /// servi à la toute prochaine allocation, fût-elle sans rapport : c'est le
    /// mécanisme qui a mité les volumes DOS.
    public mutating func free(_ extents: [Extent]) {
        bitmap.free(extents)
    }
}
