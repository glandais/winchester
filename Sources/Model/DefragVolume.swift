import Foundation
import DiskCore

/// Un fichier tel qu'un défragmenteur le voit : une catégorie, une suite
/// d'extents, et le droit ou non d'y toucher.
struct DefragFile {

    let id: UInt32
    let path: String
    let category: ClusterCategory
    /// Rang dans le parcours de l'arborescence — l'ordre dans lequel l'outil
    /// d'époque les rencontre, et le seul dont il dispose.
    let walkOrder: Int
    var extents: [Extent]
    /// Le fichier d'échange est ouvert par le système : il ne bouge pas, et
    /// tout est tassé autour de lui.
    let isMovable: Bool

    /// Taille logique, en octets, quand la source la connaît. Sans elle, la
    /// taille allouée en tient lieu.
    var bytes: UInt64? = nil
    /// Jour de création et jour de la dernière écriture, comptés depuis le
    /// début de l'histoire du volume. Les tris de JkDefrag les lisent ; aucun
    /// autre outil ne s'en sert.
    var createdDay: UInt32 = 0
    var modifiedDay: UInt32 = 0
    /// Où est son entrée de répertoire, quand la source le sait : le
    /// répertoire qui la porte — un autre élément du volume, puisque sur FAT un
    /// répertoire est un fichier qu'on défragmente aussi — et à quel octet.
    var entry: DirectoryEntryPlace? = nil
    /// Sur NTFS, son enregistrement dans la MFT, quand la source le sait
    /// (`MFTNumbering`) : c'est lui que la validation d'un déplacement réécrit.
    var mftRecord: Int? = nil

    var clusterCount: UInt32 { extents.reduce(0) { $0 + $1.length } }

    /// Nombre de morceaux **réels** du fichier sur le plateau.
    ///
    /// Ce n'est pas `extents.count` : deux extents qui se touchent bout à bout
    /// ne font qu'un seul morceau pour la tête de lecture, qui les traverse
    /// sans un seul seek. La règle vient de `IsFragmented` dans JKDefrag
    /// (`ALGO.md` §4.2), et le §8 la range parmi les cinq choses à transposer :
    /// sans elle, les compteurs de fragmentation sont faux.
    ///
    /// « Bout à bout » s'entend **dans l'ordre du fichier** : un extent
    /// prolonge le précédent de la liste, pas son voisin sur le plateau. Si B
    /// est posé juste avant A, la tête lit A puis revient en arrière chercher
    /// B — deux morceaux. C'est la règle de JKDefrag (`NextLcn`,
    /// `JkDefragLib.cpp:1348`) comme d'UltraDefrag (`ftw_ntfs.c:1098`).
    ///
    /// Le cas n'est pas théorique. Un fichier écrit en deux fois par un
    /// allocateur next-fit qui n'a bougé entre-temps sort en deux extents
    /// adjacents ; et sur NTFS, un fichier dont la description déborde d'un
    /// enregistrement de MFT est découpé pour des raisons de format, pas de
    /// placement. Les compter comme fragmentés, c'est promettre au
    /// défragmenteur du travail qui n'existe pas.
    var fragmentCount: Int {
        guard extents.count > 1 else { return extents.count }
        var count = 1
        for (previous, next) in zip(extents, extents.dropFirst()) where previous.end != next.start {
            count += 1
        }
        return count
    }

    var isContiguous: Bool { fragmentCount <= 1 }

    var firstCluster: UInt32? { extents.first?.start }
}

/// L'entrée d'un nom dans son répertoire.
struct DirectoryEntryPlace {
    /// Rang du répertoire dans `DefragVolume.files` ; `nil` pour la racine d'un
    /// FAT16, qui vit dans sa région à elle, avant les données.
    let directory: Int?
    /// Octet de l'entrée depuis le début du répertoire.
    let offset: UInt64
}

/// Index des extents occupés, par blocs.
///
/// Le défragmenteur pose sans arrêt la même question : « qui occupe les clusters
/// que je veux ? ». Un tableau d'un identifiant par cluster y répondrait en
/// temps constant, mais coûterait 320 Mo sur un volume de 320 Go — c'est
/// exactement ce que `ClusterBitmap` évite déjà pour l'occupation.
///
/// Le volume est donc découpé en quelques milliers de blocs, chacun portant la
/// liste des extents qui le traversent. Une question ne visite que les blocs de
/// la plage demandée, et un déplacement ne met à jour que ceux qu'il touche.
/// Sur le plus gros volume de la galerie, cela fait 178 000 extents répartis sur
/// 4 096 blocs, soit une quarantaine d'entrées par bloc.
struct ExtentIndex {

    fileprivate struct Entry {
        let start: UInt32
        let length: UInt32
        let file: Int
        var end: UInt32 { start &+ length }
    }

    fileprivate let blockShift: UInt32
    fileprivate var blocks: [[Entry]]

    init(clusterCount: UInt32, targetBlocks: Int = 4_096) {
        // Puissance de deux la plus proche qui donne à peu près le nombre de
        // blocs visé : un décalage plutôt qu'une division.
        var shift: UInt32 = 0
        while (clusterCount >> shift) > UInt32(targetBlocks) && shift < 31 { shift += 1 }
        self.blockShift = shift
        self.blocks = Array(repeating: [], count: Int(clusterCount >> shift) + 1)
    }

    private func blockRange(start: UInt32, length: UInt32) -> ClosedRange<Int> {
        let first = Int(start >> blockShift)
        let last = Int((start &+ max(length, 1) &- 1) >> blockShift)
        return first...min(last, blocks.count - 1)
    }

    mutating func insert(_ extent: Extent, file: Int) {
        guard extent.length > 0 else { return }
        let entry = Entry(start: extent.start, length: extent.length, file: file)
        for block in blockRange(start: extent.start, length: extent.length) {
            blocks[block].append(entry)
        }
    }

    mutating func remove(_ extent: Extent, file: Int) {
        guard extent.length > 0 else { return }
        for block in blockRange(start: extent.start, length: extent.length) {
            if let index = blocks[block].firstIndex(where: {
                $0.start == extent.start && $0.length == extent.length && $0.file == file
            }) {
                blocks[block].remove(at: index)
            }
        }
    }

    mutating func insert(_ extents: [Extent], file: Int) {
        for extent in extents { insert(extent, file: file) }
    }

    mutating func remove(_ extents: [Extent], file: Int) {
        for extent in extents { remove(extent, file: file) }
    }

    /// Les fichiers qui occupent au moins un cluster de la plage, dans l'ordre
    /// où on les rencontre et sans doublon.
    func files(in range: Range<UInt32>) -> [Int] {
        guard !range.isEmpty else { return [] }
        var found: [Int] = []
        var seen = Set<Int>()
        for block in blockRange(start: range.lowerBound,
                                length: range.upperBound - range.lowerBound) {
            for entry in blocks[block]
            where entry.start < range.upperBound && entry.end > range.lowerBound {
                if seen.insert(entry.file).inserted { found.append(entry.file) }
            }
        }
        return found
    }
}

extension ExtentIndex {

    /// L'extent qui commence le plus bas à partir de `from`, parmi les fichiers
    /// que `accept` retient.
    ///
    /// Un extent qui traverse plusieurs blocs figure dans chacun ; on ne le
    /// considère que dans celui où il **commence**. Le premier bloc qui en
    /// propose un tient alors le minimum : tout ce qui commence plus loin
    /// commence dans un bloc plus loin.
    func firstExtent(from: UInt32, where accept: (Int) -> Bool) -> (extent: Extent, file: Int)? {
        var block = Int(from >> blockShift)
        while block < blocks.count {
            var best: Entry?
            for entry in blocks[block]
            where entry.start >= from && Int(entry.start >> blockShift) == block && accept(entry.file) {
                if best == nil || entry.start < best!.start { best = entry }
            }
            if let best { return (Extent(start: best.start, length: best.length), best.file) }
            block += 1
        }
        return nil
    }

    /// L'extent qui commence le plus haut **strictement sous** `before`, parmi
    /// les fichiers que `accept` retient. Même lecture par bloc de départ, en
    /// descendant.
    func lastExtent(before: UInt32, where accept: (Int) -> Bool) -> (extent: Extent, file: Int)? {
        guard before > 0 else { return nil }
        var block = min(Int((before - 1) >> blockShift), blocks.count - 1)
        while block >= 0 {
            var best: Entry?
            for entry in blocks[block]
            where entry.start < before && Int(entry.start >> blockShift) == block && accept(entry.file) {
                if best == nil || entry.start > best!.start { best = entry }
            }
            if let best { return (Extent(start: best.start, length: best.length), best.file) }
            block -= 1
        }
        return nil
    }
}

/// Un volume prêt à être défragmenté : son plan, son occupation, ses fichiers.
///
/// C'est la seule représentation que connaissent les planificateurs. Elle ne
/// suppose rien du format — ni FAT16, ni ses 65 524 clusters — et ne stocke rien
/// qui soit proportionnel au nombre de clusters en dehors de la bitmap. Un
/// volume de 320 Go y tient dans une dizaine de mégaoctets, contre plus d'un
/// gigaoctet pour la représentation par chaîne de clusters qu'elle remplace.
struct DefragVolume {

    let partition: PartitionGeometry
    private(set) var bitmap: ClusterBitmap
    private(set) var files: [DefragFile]
    private(set) var index: ExtentIndex

    /// La plage que NTFS tient à l'écart pour que la MFT puisse grandir, ou
    /// `nil` sur un volume FAT, qui n'a rien de tel.
    ///
    /// Elle est **libre dans la bitmap et pourtant interdite** : aucun fichier
    /// n'y est, mais l'allocateur n'y met personne tant que le volume n'est pas
    /// plein à 87 %. Sans cette information, un défragmenteur y verrait le plus
    /// grand trou du volume et s'y précipiterait — en condamnant la MFT à se
    /// fragmenter à la première création de fichier. C'est ce que JKDefrag
    /// appelle `MftExcludes`, et qu'il retire de toute recherche de trou tant
    /// qu'on ne lui passe pas `IgnoreMftExcludes`.
    let mftZone: Range<UInt32>?

    /// Ce que le système de fichiers occupe sans qu'aucun fichier ne le
    /// décrive : la MFT, sa copie, le secteur d'amorçage.
    ///
    /// Occupé dans la bitmap, donc jamais proposé comme trou ; absent de
    /// `files`, donc jamais déplacé ni compté. Tant que la zone MFT gardait sa
    /// taille d'origine, elle recouvrait la MFT et le cachait. Depuis qu'elle
    /// rétrécit, une MFT hors zone paraissait libre, et un défragmenteur
    /// pouvait écrire dessus.
    private(set) var systemExtents: [Extent]

    /// Les extents de `$MFT` elle-même, parmi `systemExtents`, dans l'ordre
    /// des enregistrements — ce qu'un défragmenteur qui sait la recoller
    /// regarde (`WindowsXPStrategy`, `MFTDefrag`). Vide quand le volume ne
    /// les publie pas.
    private(set) var mftExtents: [Extent]

    /// Le secteur qui porte l'entrée de répertoire du fichier `position`, là
    /// où son répertoire est **en ce moment** — il a pu être déplacé plus tôt
    /// dans la passe. `nil` hors FAT, ou si le volume ne connaît pas ses
    /// répertoires.
    func entrySector(of position: Int) -> Int? {
        guard partition.format.isFAT, let entry = files[position].entry else { return nil }
        let sectorBytes = UInt64(DriveGeometry.bytesPerSector)
        guard let directory = entry.directory else {
            let root = max(partition.rootSectorCount, 1)
            return partition.rootLBA + Int(entry.offset / sectorBytes) % root
        }
        let extents = files[directory].extents
        let clusterBytes = UInt64(partition.clusterBytes)
        var wanted = UInt32(min(entry.offset / clusterBytes, UInt64(max(files[directory].clusterCount, 1) - 1)))
        for extent in extents {
            if wanted < extent.length {
                return partition.lba(ofCluster: Int(extent.start + wanted))
                    + Int(entry.offset % clusterBytes / sectorBytes)
            }
            wanted -= extent.length
        }
        return nil
    }

    /// L'enregistrement de MFT du fichier `position`. Un volume qui ne le sait
    /// pas — ceux que les tests fabriquent — prend son rang dans le parcours.
    func mftRecord(of position: Int) -> Int {
        files[position].mftRecord ?? 16 + position
    }

    init(partition: PartitionGeometry, files: [DefragFile],
         mftZone: Range<UInt32>? = nil, systemExtents: [Extent] = [],
         mftExtents: [Extent] = []) {
        self.partition = partition
        self.files = files
        self.mftZone = mftZone
        self.systemExtents = systemExtents
        self.mftExtents = mftExtents
        var bitmap = ClusterBitmap(clusterCount: UInt32(partition.clusterCount))
        for extent in systemExtents where !extent.isEmpty && extent.end <= UInt32(partition.clusterCount) {
            bitmap.allocate(extent)
        }
        var index = ExtentIndex(clusterCount: UInt32(partition.clusterCount))
        for (position, file) in files.enumerated() {
            for extent in file.extents {
                bitmap.allocate(extent)
            }
            index.insert(file.extents, file: position)
        }
        self.bitmap = bitmap
        self.index = index
    }

    var clusterCount: Int { partition.clusterCount }

    var fill: Double { bitmap.fill }

    // MARK: - Déplacer

    /// Si `FSCTL_MOVE_FILE` accepte de déplacer la plage de ce fichier qui
    /// commence au cluster logique `vcn`.
    ///
    /// Une règle de Windows, donc des seuls outils qui passent par son API — XP,
    /// JkDefrag, UltraDefrag ; ni `DEFRAG.EXE`, qui écrivait lui-même sur le
    /// disque, ni les deux passes écrites pour ce projet. Sur FAT, **le premier
    /// cluster d'un répertoire ne se déplace pas** : `FatMoveFile` rend
    /// `STATUS_INVALID_PARAMETER` pour un répertoire dès que `StartingVcn` vaut
    /// zéro, « because sub-directories have this cluster number in them and
    /// there is no safe way to simultaneously update them all » — c'est le
    /// numéro que porte l'entrée `..` de chaque enfant (`fastfat/fsctrl.c`,
    /// l'échantillon de pilote que Microsoft publie). Le reste de sa chaîne se
    /// déplace. D'où « FAT directories cannot be moved entirely » dans le
    /// journal d'UltraDefrag, et « Directories cannot be moved on FAT
    /// volumes. This is a known Windows limitation » dans JkDefrag.
    func moveFileAccepts(_ position: Int, fromVCN vcn: UInt32) -> Bool {
        !(partition.format.isFAT && files[position].category == .directory && vcn == 0)
    }

    /// Si ce que quitte un déplacement attend le prochain point de contrôle
    /// avant de redevenir libre.
    ///
    /// C'est une propriété du **volume**, pas de l'outil qui le défragmente.
    /// NTFS ne laisse pas réutiliser un cluster désalloué tant que ses données
    /// de reprise ne sont pas sur le disque : « NTFS prevents deallocated
    /// clusters from being used again until NTFS checkpoints the drive's
    /// state. Once every few seconds, NTFS ensures that all its crash recovery
    /// data is safely on disk; only then can deallocated clusters be reused »
    /// (Mark Russinovich, *Inside Windows NT Disk Defragmenting*, Windows NT
    /// Magazine, 1997). Un `FSCTL_MOVE_FILE` vers ces clusters échoue en
    /// `STATUS_ALREADY_COMMITTED`, et le bitmap que relit un défragmenteur les
    /// montre occupés. FAT n'a pas de journal : ce qu'un déplacement quitte
    /// est libre dès qu'il est validé.
    var releaseWaitsForCheckpoint: Bool { partition.format == .ntfs }

    /// Déplace un fichier vers une nouvelle suite d'extents, comme le fait la
    /// validation d'un déplacement dans les tables, et rend aussitôt ce qu'il
    /// quitte.
    ///
    /// **Refusé sur NTFS**, où rien n'est rendu aussitôt : une stratégie y
    /// passe par `relocateHoldingReleased`, et choisit sa cadence de points de
    /// contrôle (`releaseHeldClusters`). La règle ne peut pas être oubliée par
    /// un outil — c'est ce qui était arrivé à deux sur cinq.
    ///
    /// - Parameter changesOnly: ne toucher la bitmap et l'index que pour les
    ///   extents qui changent. Retirer et réinsérer tous les extents du fichier
    ///   est quadratique pour qui déplace un fichier en trois mille morceaux
    ///   **un morceau à la fois**, comme le fait `Vacate` : la moitié du temps
    ///   d'un tri complet. Le résultat est le même, à un détail près : les
    ///   extents inchangés gardent leur rang dans les listes de l'index.
    ///   `occupants` rend alors ses fichiers dans un autre ordre, et Windows 95
    ///   évacue dans cet ordre-là : il déplace tout.
    mutating func relocate(_ position: Int, to extents: [Extent], changesOnly: Bool = false) {
        precondition(!releaseWaitsForCheckpoint,
                     "sur NTFS, ce qu'un déplacement quitte attend le point de contrôle : relocateHoldingReleased")
        replace(position, with: extents, changesOnly: changesOnly)
    }

    /// Les clusters qu'un déplacement a libérés mais qu'on s'interdit encore de
    /// réutiliser : occupés dans la bitmap, portés par aucun fichier. Dans
    /// l'ordre où ils ont été retenus.
    ///
    /// Sur NTFS c'est la règle du volume (`releaseWaitsForCheckpoint`) ; sur
    /// FAT, un choix de l'outil — `FrontierCompactionStrategy` retient ce
    /// qu'elle quitte jusqu'à ce que les tables soient écrites.
    private(set) var heldClusters: [Extent] = []

    /// Le déplacement, en retenant ce que le fichier quitte au lieu de le
    /// rendre aussitôt aux recherches de trou.
    ///
    /// Ce qui est retenu, c'est ce que l'empreinte d'origine a de libre une
    /// fois le déplacement fait : la plage déplacée, et pas ce qui est resté en
    /// place.
    mutating func relocateHoldingReleased(_ position: Int, to extents: [Extent],
                                          changesOnly: Bool = false) {
        let removed = replace(position, with: extents, changesOnly: changesOnly)
        for extent in removed where !extent.isEmpty {
            var cursor = extent.start
            // Le run est borné à l'extent : un trou voisin, déjà libre avant le
            // déplacement, n'a rien à attendre.
            while let found = bitmap.nextFreeRun(from: cursor, limit: extent.end - cursor,
                                                 before: extent.end) {
                let run = Extent(start: found.start, length: min(found.end, extent.end) - found.start)
                bitmap.allocate(run)
                heldClusters.append(run)
                cursor = run.end
            }
        }
    }

    /// Déplace la queue de `$MFT` — tout sauf son premier extent — vers une
    /// place neuve, comme le fait `MFTDefrag` de XP. Ce qu'elle quitte attend
    /// le point de contrôle, comme pour un fichier.
    mutating func relocateMFTTail(to extent: Extent) {
        guard mftExtents.count > 1 else { return }
        let tail = Array(mftExtents.dropFirst())
        for old in tail {
            bitmap.free(old)
            if let at = systemExtents.firstIndex(of: old) { systemExtents.remove(at: at) }
        }
        for old in tail where !old.isEmpty {
            bitmap.allocate(old)
            heldClusters.append(old)
        }
        bitmap.allocate(extent)
        systemExtents.append(extent)
        mftExtents = [mftExtents[0], extent]
    }

    /// Le point de contrôle : tout ce qui était retenu redevient libre.
    mutating func releaseHeldClusters() {
        releaseHeldClusters(first: heldClusters.count)
    }

    /// Un point de contrôle tombé pendant la passe : ce qui avait été retenu
    /// **avant lui** — les `count` premiers extents retenus — redevient libre,
    /// et ce que les déplacements suivants ont quitté attend le prochain.
    mutating func releaseHeldClusters(first count: Int) {
        let count = min(count, heldClusters.count)
        guard count > 0 else { return }
        for extent in heldClusters[..<count] { bitmap.free(extent) }
        heldClusters.removeFirst(count)
    }

    /// Remplace les extents du fichier et rend ceux qu'il a quittés, déjà
    /// libérés dans la bitmap.
    @discardableResult
    private mutating func replace(_ position: Int, with extents: [Extent],
                                  changesOnly: Bool) -> ArraySlice<Extent> {
        let old = files[position].extents
        var prefix = 0
        var suffix = 0
        if changesOnly {
            // Un déplacement ne change qu'une plage de VCN : ce qui la précède
            // et ce qui la suit sont les mêmes extents, dans le même ordre.
            while prefix < old.count && prefix < extents.count && old[prefix] == extents[prefix] {
                prefix += 1
            }
            while suffix < old.count - prefix && suffix < extents.count - prefix
                    && old[old.count - 1 - suffix] == extents[extents.count - 1 - suffix] {
                suffix += 1
            }
        }
        let removed = old[prefix..<(old.count - suffix)]
        let added = extents[prefix..<(extents.count - suffix)]
        if changesOnly {
            for extent in removed {
                bitmap.free(extent)
                index.remove(extent, file: position)
            }
            for extent in added {
                bitmap.allocate(extent)
                index.insert(extent, file: position)
            }
        } else {
            for extent in removed { bitmap.free(extent) }
            index.remove(old, file: position)
            for extent in added { bitmap.allocate(extent) }
            index.insert(extents, file: position)
        }
        files[position].extents = extents
        return removed
    }

    /// Les fichiers qui occupent la plage demandée.
    func occupants(of range: Range<UInt32>) -> [Int] { index.files(in: range) }

    // MARK: - Mesures

    /// Où est chaque fichier, dans l'ordre du volume.
    var arrangement: [FileArrangement] {
        files.map { FileArrangement(id: $0.id, extents: $0.extents) }
    }

    /// Le même volume, chaque fichier posé là où `arrangement` le dit. Un
    /// fichier que l'arrangement ne nomme pas garde sa place.
    func rearranged(_ arrangement: [FileArrangement]) -> DefragVolume {
        let places = Dictionary(arrangement.map { ($0.id, $0.extents) },
                                uniquingKeysWith: { _, last in last })
        let moved = files.map { file -> DefragFile in
            guard let extents = places[file.id] else { return file }
            var copy = file
            copy.extents = extents
            return copy
        }
        return DefragVolume(partition: partition, files: moved, mftZone: mftZone,
                            systemExtents: systemExtents, mftExtents: mftExtents)
    }

    var stats: VolumeStats {
        let broken = files.filter { !$0.isContiguous }
        return VolumeStats(fill: fill,
                           fragmentedFiles: broken.count,
                           fragments: broken.reduce(0) { $0 + $1.fragmentCount },
                           fileCount: files.count,
                           extentsPerFile: files.isEmpty
                               ? 0
                               : Double(files.reduce(0) { $0 + $1.extents.count }) / Double(files.count),
                           freeHoles: bitmap.freeRunCount())
    }

    /// Les plages occupées, avec leur catégorie, triées par cluster de début.
    ///
    /// C'est la description que le rejeu de la carte attend : ce qui n'y figure
    /// pas est libre. Elle coûte le nombre d'extents — cent soixante-dix-huit
    /// mille sur le plus gros volume de la galerie — là où `categoryMap()`
    /// coûte le nombre de clusters, soit quatre cent quarante fois plus.
    ///
    /// Les extents système y figurent en `.reserved`, la couleur des tables
    /// FAT : sans eux, la MFT paraissait libre à l'écran alors que la bitmap la
    /// tient occupée, et une zone MFT qui cède montrait un trou là où aucun
    /// défragmenteur n'a le droit d'écrire.
    func categoryRuns() -> [MapRun] {
        var runs: [MapRun] = []
        runs.reserveCapacity(files.reduce(systemExtents.count) { $0 + $1.extents.count })
        let reserved = ClusterCategory.reserved.rawValue
        for extent in systemExtents where !extent.isEmpty {
            runs.append(MapRun(start: extent.start, count: extent.length, category: reserved))
        }
        for file in files {
            let raw = file.category.rawValue
            let contiguous = file.isContiguous
            for extent in file.extents where !extent.isEmpty {
                runs.append(MapRun(start: extent.start, count: extent.length, category: raw,
                                   contiguous: contiguous))
            }
        }
        runs.sort { $0.start < $1.start }
        return runs
    }

    /// Carte des catégories, une valeur par cluster.
    ///
    /// Ne la demander que pour un volume dont la carte sera réellement affichée
    /// cluster par cluster : sur un volume de 320 Go elle pèse 80 Mo. Depuis
    /// que le rejeu travaille par plages, plus personne ne l'appelle en dehors
    /// des tests, qui s'en servent de référence sur de petits volumes.
    func categoryMap() -> [UInt8] {
        var map = [UInt8](repeating: ClusterCategory.free.rawValue, count: partition.clusterCount)
        for extent in systemExtents {
            let end = min(Int(extent.end), map.count)
            guard Int(extent.start) < end else { continue }
            for cluster in Int(extent.start)..<end { map[cluster] = ClusterCategory.reserved.rawValue }
        }
        for file in files {
            let raw = file.category.rawValue
            for extent in file.extents {
                let end = min(Int(extent.end), map.count)
                for cluster in Int(extent.start)..<end { map[cluster] = raw }
            }
        }
        return map
    }
}

// MARK: - D'un volume vieilli sur place

extension Volume {

    /// Le volume livré, tel que le défragmenteur le voit.
    func defragVolume() -> DefragVolume {
        let order = directoryWalkOrder()
        let files = order.enumerated().map { position, file in
            DefragFile(id: UInt32(file.id),
                       path: file.path,
                       category: file.kind,
                       walkOrder: position,
                       extents: file.extents.map {
                           Extent(start: UInt32($0.start), length: UInt32($0.count))
                       },
                       isMovable: file.kind != .swap,
                       // Le volume livré ne date pas ses fichiers : le rang de
                       // création est la seule chronologie qu'il porte.
                       createdDay: UInt32(file.created),
                       modifiedDay: UInt32(file.created))
        }
        return DefragVolume(partition: partition, files: files)
    }
}
