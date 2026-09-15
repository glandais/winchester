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

    var clusterCount: UInt32 { extents.reduce(0) { $0 + $1.length } }

    /// Nombre de morceaux **réels** du fichier sur le plateau.
    ///
    /// Ce n'est pas `extents.count` : deux extents qui se touchent bout à bout
    /// ne font qu'un seul morceau pour la tête de lecture, qui les traverse
    /// sans un seul seek. La règle vient de `IsFragmented` dans JKDefrag
    /// (`ALGO.md` §4.2), et le §8 la range parmi les cinq choses à transposer :
    /// sans elle, les compteurs de fragmentation sont faux.
    ///
    /// Le cas n'est pas théorique. Un fichier écrit en deux fois par un
    /// allocateur next-fit qui n'a bougé entre-temps sort en deux extents
    /// adjacents ; et sur NTFS, un fichier dont la description déborde d'un
    /// enregistrement de MFT est découpé pour des raisons de format, pas de
    /// placement. Les compter comme fragmentés, c'est promettre au
    /// défragmenteur du travail qui n'existe pas.
    var fragmentCount: Int {
        guard extents.count > 1 else { return extents.count }
        let ordered = extents.sorted { $0.start < $1.start }
        var count = 1
        for (previous, next) in zip(ordered, ordered.dropFirst()) where previous.end != next.start {
            count += 1
        }
        return count
    }

    var isContiguous: Bool { fragmentCount <= 1 }

    var firstCluster: UInt32? { extents.first?.start }
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

    private struct Entry {
        let start: UInt32
        let length: UInt32
        let file: Int
        var end: UInt32 { start &+ length }
    }

    private let blockShift: UInt32
    private var blocks: [[Entry]]

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

    init(partition: PartitionGeometry, files: [DefragFile],
         mftZone: Range<UInt32>? = nil) {
        self.partition = partition
        self.files = files
        self.mftZone = mftZone
        var bitmap = ClusterBitmap(clusterCount: UInt32(partition.clusterCount))
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

    /// Déplace un fichier vers une nouvelle suite d'extents, comme le fait la
    /// validation d'un déplacement dans les tables.
    mutating func relocate(_ position: Int, to extents: [Extent]) {
        let old = files[position].extents
        for extent in old { bitmap.free(extent) }
        index.remove(old, file: position)
        for extent in extents { bitmap.allocate(extent) }
        index.insert(extents, file: position)
        files[position].extents = extents
    }

    /// Les fichiers qui occupent la plage demandée.
    func occupants(of range: Range<UInt32>) -> [Int] { index.files(in: range) }

    // MARK: - Mesures

    var stats: VolumeStats {
        VolumeStats(fill: fill,
                    fragmentedFiles: files.filter { !$0.isContiguous }.count,
                    fileCount: files.count,
                    extentsPerFile: files.isEmpty
                        ? 0
                        : Double(files.reduce(0) { $0 + $1.extents.count }) / Double(files.count),
                    freeHoles: bitmap.freeRunCount())
    }

    /// Carte des catégories, une valeur par cluster.
    ///
    /// Ne la demander que pour un volume dont la carte sera réellement affichée
    /// cluster par cluster : sur un volume de 320 Go elle pèse 80 Mo.
    func categoryMap() -> [UInt8] {
        var map = [UInt8](repeating: ClusterCategory.free.rawValue, count: partition.clusterCount)
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
                       isMovable: file.kind != .swap)
        }
        return DefragVolume(partition: partition, files: files)
    }
}
