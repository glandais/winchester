import Foundation
import DiskCore

/// Projection de la taxonomie du générateur sur les huit couleurs que la carte
/// des clusters sait afficher.
///
/// Le noyau distingue douze natures de fichiers parce que leurs **motifs
/// d'écriture** diffèrent ; la vue n'en distingue que huit parce que c'est ce
/// que le défragmenteur d'époque coloriait. Le rapprochement se fait ici, et
/// nulle part ailleurs.
extension ClusterCategory {

    init(_ category: FileCategory) {
        switch category {
        case .systemCore:                 self = .system
        case .application:                self = .application
        case .source, .document:          self = .document
        case .buildArtifact, .temporary, .cache: self = .churn
        case .media, .gameAsset:          self = .application
        case .archive:                    self = .archive
        case .swap:                       self = .swap
        case .metadata:                   self = .reserved
        }
    }
}

/// Passerelle entre un disque généré et le modèle de volume de l'application.
///
/// Le planificateur de défragmentation, le rejeu de la carte et toute la chaîne
/// audio travaillent sur `Volume`. Plutôt que de les réécrire, on leur donne un
/// `Volume` bâti à partir d'un disque généré : ils ne voient pas la différence,
/// et le générateur n'a pas à connaître leur existence.
///
/// La conversion n'est possible que pour un volume que `PartitionGeometry` sait
/// décrire, c'est-à-dire un FAT16 de moins de 65 524 clusters. Les volumes NTFS
/// de 2003 et 2007 s'affichent par leur carte de catégories, qui ne demande
/// rien de tout cela — un disque de 320 Go n'a de toute façon pas vocation à
/// passer par un défragmenteur de Windows 95.
enum GeneratedVolumeBridge {

    enum BridgeError: Error, CustomStringConvertible {
        case unsupportedGeometry(clusterCount: UInt32)

        var description: String {
            switch self {
            case let .unsupportedGeometry(count):
                return "un volume de \(count) clusters ne se décrit pas en FAT16"
            }
        }
    }

    /// Construit un `Volume` équivalent au disque généré.
    ///
    /// Les fichiers sont adoptés dans l'ordre du parcours de l'arborescence, et
    /// gardent exactement les clusters que l'allocateur leur a donnés : c'est
    /// bien le volume généré qu'on défragmente, pas une approximation.
    static func volume(from disk: GeneratedDisk) throws -> Volume {
        let clusterSectors = Int(disk.clusterBytes) / DriveGeometry.bytesPerSector
        guard disk.clusterCount < 65_525, clusterSectors > 0 else {
            throw BridgeError.unsupportedGeometry(clusterCount: disk.clusterCount)
        }

        // Une partition qui contient exactement ce volume, tables comprises.
        let dataSectors = Int(disk.clusterCount) * clusterSectors
        let fatSectors = Int(ceil(Double(disk.clusterCount) * 2 / Double(DriveGeometry.bytesPerSector)))
        let total = dataSectors + 2 * fatSectors + 33 + clusterSectors
        let partition = PartitionGeometry(startLBA: 0, sectors: total, clusterSectors: clusterSectors)

        let volume = Volume(partition: partition)
        for record in disk.catalog.directoryWalkOrder() where !record.isResident {
            guard !record.extents.isEmpty else { continue }
            var chain: [Int] = []
            chain.reserveCapacity(Int(record.entry.clusterCount))
            for extent in record.extents {
                for cluster in extent.start..<extent.end where Int(cluster) < partition.clusterCount {
                    chain.append(Int(cluster))
                }
            }
            guard !chain.isEmpty else { continue }
            volume.adopt(path: disk.catalog.path(of: record),
                         kind: ClusterCategory(record.category),
                         chain: chain)
        }
        return volume
    }
}
