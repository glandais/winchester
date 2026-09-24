import Foundation

/// Ce que l'appelant sait du fichier qu'il place, et que l'allocateur seul ne
/// peut pas deviner.
///
/// Il n'y en a que trois, et c'est tout ce que les systèmes de l'époque
/// distinguaient. Il n'y a pas d'indice « de démarrage » : `IO.SYS` tombe en
/// tête parce que `FORMAT /S` l'écrit le premier sur un volume vide, et
/// `Layout.ini` est l'affaire du défragmenteur, qui repasse plus tard. Ni
/// d'indice « temporaire » : aucun système de fichiers de l'époque ne
/// ségrégeait les temporaires, et ce sont eux qui creusent les trous **parce
/// qu'ils sont placés comme les autres** et effacés plus tôt. (Les deux ont
/// existé ici, sans rien exercer : `LEDGER.md`, chantier 27.)
public enum AllocationHint: Sendable, Hashable {

    /// Zone système : proche du début, mais sans la contrainte du premier
    /// cluster libre.
    case system

    /// Refuse la fragmentation. `386SPART.PAR`, `pagefile.sys` à taille fixe,
    /// `hiberfil.sys` : ces fichiers sont posés d'un seul tenant, et si le
    /// volume n'a plus de bloc assez grand, c'est le volume qui a un problème,
    /// pas le fichier.
    case reservedContiguous

    case normal
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

    /// Écrit `count` clusters de plus au bout d'un fichier dont le programme ne
    /// connaît pas la taille finale : par paquets de
    /// `profile.writePacketClusters`, chacun pris là où l'allocateur en est au
    /// moment où il est demandé, comme autant d'`extend` successifs.
    ///
    /// Personne ne s'intercale pendant l'appel. L'entrelacement de deux
    /// programmes se fait au-dessus, en appelant cette fonction un paquet à la
    /// fois pour chacun (`Simulator`) ; appelée pour tout un fichier, elle
    /// décrit un programme qui écrit seul.
    ///
    /// Tout ou rien, comme `extend` : si un paquet ne trouve pas de place, ce
    /// que les précédents ont pris est rendu et le fichier ressort inchangé.
    ///
    /// `growth` dit comment le programme fait grandir le fichier ; seul le
    /// NTFS de XP le distingue (`NTFSAllocator.stream`).
    /// - Returns: `false` si la place manquait.
    @discardableResult
    mutating func stream(file: inout FileEntry, clusters count: UInt32, growth: StreamedGrowth) -> Bool

    /// La taille que prend un fichier écrit ainsi quand son programme veut y
    /// mettre `bytes` : `bytes`, sauf sous XP pour `index.dat`, que `wininet`
    /// tient à un multiple de 16 Ko (`StreamedGrowth.fileBytes`).
    func streamedFileBytes(_ bytes: UInt64, growth: StreamedGrowth) -> UInt64

    /// Prend `count` clusters dans l'ordre exact où `count` paquets d'un
    /// cluster, demandés l'un après l'autre par des fichiers différents, les
    /// auraient pris — ou rien, et `nil`, si ce format ne le garantit pas.
    ///
    /// C'est ce qui permet de jouer d'un bloc plusieurs programmes qui écrivent
    /// en même temps (`Simulator.next`) : sur FAT, chaque paquet est un cluster,
    /// et c'est le premier libre au curseur partagé, quel que soit le fichier
    /// qui le demande. Sur NTFS, un paquet cherche d'abord à prolonger **son**
    /// fichier : l'ordre des demandes compte, et rien ne se joue d'avance.
    mutating func takeInWritingOrder(_ count: UInt32, hints: [AllocationHint]) -> [Extent]?

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

    /// Ce que le système de fichiers occupe pour lui-même, hors de tout fichier
    /// du catalogue : `$Boot`, la MFT et sa copie sur NTFS. Vide sur FAT, dont
    /// les tables vivent avant la zone de données.
    var metadataExtents: [Extent] { get }

    /// Les clusters que le formatage a déjà donnés à l'index du répertoire
    /// racine, et que la racine reprend à sa création : l'allocation de
    /// l'index racine que `FORMAT` de XP pose au milieu du volume. `nil`
    /// partout ailleurs, où la racine prend ses clusters comme tout
    /// répertoire.
    var formattedRootIndex: Extent? { get }

    /// La plage qu'un défragmenteur laisse vide : la zone MFT de NTFS, telle
    /// que le pilote la publie à l'instant (`FSCTL_GET_NTFS_VOLUME_DATA`,
    /// `MftZoneStart` et `MftZoneEnd`). `nil` sur FAT, ou quand la zone est
    /// vide. Seule la défragmentation de l'histoire la lit
    /// (`Simulator.defragment`) ; l'allocateur, lui, la gère.
    var defragmentExcludedZone: Range<UInt32>? { get }

    /// Le volume est monté : la machine a démarré. Le simulateur l'annonce au
    /// premier événement de chaque journée. Sans effet hors NTFS de XP, dont
    /// le pilote rebâtit alors son cache de runs libres.
    mutating func mount()

    /// Un point de contrôle du journal. Le simulateur l'annonce entre deux
    /// événements. Sans effet hors NTFS de XP, qui masque les clusters
    /// libérés jusque-là.
    mutating func checkpoint()

    /// Donne un enregistrement de métadonnées à un fichier ou un répertoire
    /// qui naît, et le reprend quand il disparaît. `nil` quand le format ne
    /// les désigne pas — tout sauf le NTFS de XP, où le plus petit libre est
    /// repris (`NtfsAllocateRecord`).
    mutating func takeRecord() -> UInt32?
    mutating func releaseRecord(_ record: UInt32)
}

extension Allocator {

    public mutating func mount() {}
    public mutating func checkpoint() {}
    public mutating func takeRecord() -> UInt32? { nil }
    public mutating func releaseRecord(_ record: UInt32) {}
    public mutating func noteFileCreated(logicalSize: UInt64) {}
    public mutating func noteFileDeleted() {}
    public var metadataExtents: [Extent] { [] }
    public var formattedRootIndex: Extent? { nil }
    public var defragmentExcludedZone: Range<UInt32>? { nil }

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

    public mutating func takeInWritingOrder(_ count: UInt32, hints: [AllocationHint]) -> [Extent]? { nil }

    public mutating func stream(file: inout FileEntry, clusters count: UInt32, growth: StreamedGrowth) -> Bool {
        streamByPackets(file: &file, clusters: count)
    }

    public func streamedFileBytes(_ bytes: UInt64, growth: StreamedGrowth) -> UInt64 { bytes }

    /// `stream` d'un programme qui écrit par `WriteFile` (`.buffered`).
    @discardableResult
    public mutating func stream(file: inout FileEntry, clusters count: UInt32) -> Bool {
        stream(file: &file, clusters: count, growth: .buffered)
    }

    /// `stream` par paquets fixes de `profile.writePacketClusters`, chacun un
    /// `extend` : ce que fait tout allocateur qui n'a pas sa propre règle.
    public mutating func streamByPackets(file: inout FileEntry, clusters count: UInt32) -> Bool {
        let packet = profile.writePacketClusters
        // Ce qui a été ajouté, et non une copie des extents d'avant : gardée,
        // elle ferait recopier le tableau à chaque paquet.
        var added: UInt32 = 0
        while added < count {
            let size = min(packet, count - added)
            guard extend(file: &file, byClusters: size) else {
                // Les paquets précédents ont tous été ajoutés au bout du
                // fichier : les rendre par la fin rend au fichier ses extents
                // d'avant, dernier compris.
                releaseTail(of: &file, keeping: file.clusterCount - added)
                return false
            }
            added += size
        }
        return true
    }

    /// Rend les clusters d'un fichier au-delà des `kept` premiers, par la fin,
    /// sans toucher à sa taille logique.
    public mutating func releaseTail(of file: inout FileEntry, keeping kept: UInt32) {
        var excess = file.clusterCount > kept ? file.clusterCount - kept : 0
        while excess > 0, var last = file.extents.last {
            let taken = min(last.length, excess)
            free([Extent(start: last.end - taken, length: taken)])
            last.length -= taken
            if last.length == 0 { file.extents.removeLast() } else { file.extents[file.extents.count - 1] = last }
            excess -= taken
        }
    }

    /// Place un fichier dont le programme ne connaissait pas la taille : il
    /// naît vide et grandit par paquets jusqu'à sa taille finale. La résidence
    /// se décide comme pour `place` — sur la taille à laquelle il arrive.
    /// - Returns: `false` si la place manquait ; rien n'est alors pris.
    public mutating func placeStreamed(file: inout FileEntry, growth: StreamedGrowth = .buffered) -> Bool {
        file.logicalSize = streamedFileBytes(file.logicalSize, growth: growth)
        if profile.isResident(bytes: file.logicalSize) {
            place(file: &file)
            return true
        }
        file.isResident = false
        file.extents = []
        let written = stream(file: &file, clusters: profile.clusters(forBytes: file.logicalSize), growth: growth)
        noteFileCreated(logicalSize: file.logicalSize)
        return written
    }

    /// `grow` pour un fichier qu'on allonge sans en connaître la fin : un
    /// journal, `index.dat`, le `.pst` d'Outlook. Le complément arrive par
    /// paquets.
    public mutating func growStreamed(file: inout FileEntry, toLogicalSize bytes: UInt64,
                                      growth: StreamedGrowth = .buffered) {
        let bytes = streamedFileBytes(bytes, growth: growth)
        guard bytes > file.logicalSize else { return }
        if file.isResident, !profile.isResident(bytes: bytes) {
            var moved = file
            moved.extents = []
            guard stream(file: &moved, clusters: profile.clusters(forBytes: bytes), growth: growth) else { return }
            file.isResident = false
            file.logicalSize = bytes
            file.extents = moved.extents
            return
        }
        if file.isResident {
            file.logicalSize = bytes
            return
        }
        let before = profile.clusters(forBytes: file.logicalSize)
        let after = profile.clusters(forBytes: bytes)
        if after > before {
            guard stream(file: &file, clusters: after - before, growth: growth) else { return }
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
