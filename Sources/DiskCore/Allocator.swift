import Foundation

/// Ce que l'appelant sait du fichier qu'il place, et que l'allocateur seul ne
/// peut pas deviner.
public enum AllocationHint: Sendable, Hashable {

    /// Doit être au plus près du début du volume : `IO.SYS` sur FAT, les
    /// fichiers listés dans `Layout.ini` sur XP. Les cylindres extérieurs
    /// portent le plus de secteurs par piste, donc le meilleur débit.
    case boot

    /// Zone système : proche du début, mais sans la contrainte du premier
    /// cluster libre.
    case system

    /// Refuse la fragmentation. `386SPART.PAR`, `pagefile.sys` à taille fixe,
    /// `hiberfil.sys` : ces fichiers sont posés d'un seul tenant, et si le
    /// volume n'a plus de bloc assez grand, c'est le volume qui a un problème,
    /// pas le fichier.
    case reservedContiguous

    case normal

    /// Durée de vie courte : `.obj` de compilation, cache du navigateur,
    /// `~WRD0001.TMP`. Ce sont eux qui creusent les trous, et les placer à part
    /// change la texture du volume.
    case temporary
}

/// Un fichier vu par l'allocateur : sa taille logique, la place qu'il occupe
/// réellement, et rien d'autre. Le nom, le répertoire et les dates appartiennent
/// au catalogue.
public struct FileEntry: Sendable, Identifiable {

    public var id: UInt32
    /// Taille en octets telle que l'utilisateur la voit.
    public var logicalSize: UInt64
    /// Clusters occupés, **dans l'ordre logique du fichier**.
    public var extents: [Extent]
    public var hint: AllocationHint
    /// NTFS : le fichier tient dans son enregistrement MFT et n'occupe aucun
    /// cluster de données.
    public var isResident: Bool

    public init(id: UInt32,
                logicalSize: UInt64,
                extents: [Extent] = [],
                hint: AllocationHint = .normal,
                isResident: Bool = false) {
        self.id = id
        self.logicalSize = logicalSize
        self.extents = extents
        self.hint = hint
        self.isResident = isResident
    }

    public var clusterCount: UInt32 { extents.clusterCount }

    /// Un fichier est fragmenté dès qu'il faut plus d'un extent pour le lire.
    public var isFragmented: Bool { extents.count > 1 }

    public func allocatedBytes(clusterBytes: UInt32) -> UInt64 {
        UInt64(clusterCount) * UInt64(clusterBytes)
    }
}

/// Stratégie de placement d'un système de fichiers.
///
/// Les trois implémentations ne diffèrent que par la façon dont elles
/// choisissent un trou — et c'est pourtant de là que vient toute la différence
/// de texture entre un volume DOS mité et un NTFS propre. C'est le point le
/// plus important du lot : la fragmentation n'est jamais un paramètre, elle est
/// ce que ces quelques lignes produisent au bout de quelques milliers
/// d'événements.
public protocol Allocator {

    var profile: any FileSystemProfile { get }
    var bitmap: ClusterBitmap { get }

    /// Alloue `clusterCount` clusters, en respectant la stratégie du système de
    /// fichiers.
    ///
    /// - Returns: les extents dans l'ordre logique du fichier. Une liste vide
    ///   signifie que le volume n'a pas pu satisfaire la demande ; une liste
    ///   plus courte que demandé n'arrive jamais — soit tout est placé, soit
    ///   rien ne l'est.
    mutating func allocate(clusterCount: UInt32, hint: AllocationHint) -> [Extent]

    /// Agrandit un fichier existant. C'est ici que se joue la différence entre
    /// un `.doc` réenregistré qui reste contigu et un autre qui finit en trois
    /// morceaux : FAT reprend l'allocation ordinaire, NTFS essaie d'abord de
    /// prolonger le dernier extent.
    ///
    /// Tout ou rien : si le volume ne peut pas fournir la place, le fichier
    /// ressort **inchangé**. Un disque plein refuse l'écriture, il ne la fait
    /// pas à moitié.
    /// - Returns: `false` si la place manquait.
    @discardableResult
    mutating func extend(file: inout FileEntry, byClusters count: UInt32) -> Bool

    mutating func free(_ extents: [Extent])

    /// Prend une plage précise, si elle est entièrement libre.
    ///
    /// Réservé aux outils qui décident eux-mêmes du placement — un
    /// défragmenteur ne demande pas de la place à l'allocateur, il lui dicte où
    /// poser chaque fichier. Aucun chemin d'écriture ordinaire ne passe par là.
    @discardableResult
    mutating func claim(_ extent: Extent) -> Bool

    /// Signale la création d'un fichier, pour que les systèmes qui tiennent une
    /// table de métadonnées la fassent grandir. Sans effet sur FAT, dont les
    /// entrées de répertoire vivent dans des fichiers ordinaires ; sur NTFS,
    /// c'est ce qui fait enfler la MFT d'un profil développeur.
    mutating func noteFileCreated(logicalSize: UInt64)

    /// Signale la disparition d'un fichier. NTFS **réutilise** l'enregistrement
    /// MFT qu'il libère : sans cela, un développeur qui crée et détruit des
    /// centaines de milliers de fichiers objets se retrouverait avec une table
    /// de métadonnées de plusieurs gigaoctets.
    mutating func noteFileDeleted()
}

extension Allocator {

    public mutating func noteFileCreated(logicalSize: UInt64) {}
    public mutating func noteFileDeleted() {}

    /// Place un fichier entier et renseigne son entrée. La résidence est
    /// décidée ici : un fichier résident ne passe jamais par l'allocateur.
    public mutating func place(file: inout FileEntry) {
        if profile.isResident(bytes: file.logicalSize) {
            file.isResident = true
            file.extents = []
            noteFileCreated(logicalSize: file.logicalSize)
            return
        }
        file.isResident = false
        file.extents = allocate(clusterCount: profile.clusters(forBytes: file.logicalSize),
                                hint: file.hint)
        noteFileCreated(logicalSize: file.logicalSize)
    }

    /// Porte un fichier à une nouvelle taille logique, en n'allouant que le
    /// complément. C'est le motif d'écriture le plus fragmentant qui soit : le
    /// journal qui grossit, le `.pst` d'Outlook sur trois ans, `index.dat` en
    /// append permanent.
    public mutating func grow(file: inout FileEntry, toLogicalSize bytes: UInt64) {
        guard bytes > file.logicalSize else { return }

        // Un fichier résident qui dépasse le seuil quitte son enregistrement
        // MFT d'un coup : tout son contenu part sur le disque.
        if file.isResident, !profile.isResident(bytes: bytes) {
            let extents = allocate(clusterCount: profile.clusters(forBytes: bytes), hint: file.hint)
            guard !extents.isEmpty else { return }   // disque plein : rien ne bouge
            file.isResident = false
            file.logicalSize = bytes
            file.extents = extents
            return
        }
        if file.isResident {
            file.logicalSize = bytes
            return
        }

        let before = profile.clusters(forBytes: file.logicalSize)
        let after = profile.clusters(forBytes: bytes)
        if after > before {
            guard extend(file: &file, byClusters: after - before) else { return }
        }
        file.logicalSize = bytes
    }

    /// Réduit un fichier : les clusters en trop sont rendus **par la fin**,
    /// comme le ferait une troncature. C'est le mouvement du fichier d'échange
    /// qui se dégonfle.
    public mutating func shrink(file: inout FileEntry, toLogicalSize bytes: UInt64) {
        guard bytes < file.logicalSize, !file.isResident else {
            if file.isResident { file.logicalSize = bytes }
            return
        }
        let wanted = profile.clusters(forBytes: bytes)
        var current = file.clusterCount
        file.logicalSize = bytes

        while current > wanted, var last = file.extents.last {
            let excess = current - wanted
            if last.length <= excess {
                free([last])
                file.extents.removeLast()
                current -= last.length
            } else {
                free([Extent(start: last.end - excess, length: excess)])
                last.length -= excess
                file.extents[file.extents.count - 1] = last
                current -= excess
            }
        }
    }

    public mutating func release(file: inout FileEntry) {
        free(file.extents)
        file.extents = []
    }

    /// Cherche un bloc d'un seul tenant. Sert aux fichiers à placement
    /// contraint, et la règle est stricte : tant que le volume a un run libre
    /// assez grand, le fichier est en un seul extent.
    func contiguousRun(for count: UInt32, in range: Range<UInt32>? = nil) -> Extent? {
        guard let run = bitmap.bestFitRun(minLength: count, in: range) else { return nil }
        return Extent(start: run.start, length: count)
    }
}
