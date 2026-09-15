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

/// Passerelle entre un disque généré et le volume que défragmente l'application.
///
/// Le planificateur, le rejeu de la carte et toute la chaîne audio travaillent
/// sur un `DefragVolume` : une bitmap d'occupation et des fichiers décrits par
/// leurs extents. C'est exactement ce que produit le générateur, à la
/// nomenclature près — la conversion ne recopie donc que des extents, sans
/// jamais dérouler un cluster.
///
/// C'est ce qui a levé la limite des 65 524 clusters : la passerelle
/// construisait autrefois un volume FAT16 dont chaque fichier portait la liste
/// de ses clusters, ce qu'un volume de 320 Go — quatre-vingts millions de
/// clusters pour cent soixante-dix-huit mille extents — ne pouvait pas payer.
enum GeneratedVolumeBridge {

    enum BridgeError: Error, CustomStringConvertible {
        case unsupportedFormat(FileSystemKind)

        var description: String {
            switch self {
            case let .unsupportedFormat(kind):
                return "le défragmenteur simulé ne range pas un volume "
                    + "\(kind.rawValue.uppercased())"
            }
        }
    }

    /// Format de partition correspondant à celui du disque généré.
    static func format(of disk: GeneratedDisk) -> VolumeFormat {
        switch disk.spec.fileSystem.type {
        case .fat16, .vfat: return .fat16
        case .fat32:        return .fat32
        case .ntfs:         return .ntfs
        }
    }

    /// Construit le volume à défragmenter à partir du disque généré.
    ///
    /// Les fichiers sont adoptés dans l'ordre du parcours de l'arborescence et
    /// gardent exactement les extents que l'allocateur leur a donnés : c'est
    /// bien ce volume-là qu'on défragmente, pas une approximation.
    static func volume(from disk: GeneratedDisk) throws -> DefragVolume {
        let clusterSectors = Int(disk.clusterBytes) / DriveGeometry.bytesPerSector
        // Le refus ne vit pas que dans l'écran qui grise le bouton : un
        // appelant qui passerait outre — le rendu hors-ligne, par exemple — doit
        // obtenir la même réponse.
        guard isSupported(disk), clusterSectors > 0 else {
            throw BridgeError.unsupportedFormat(disk.spec.fileSystem.type)
        }

        let partition = PartitionGeometry(startLBA: 0,
                                          clusterCount: Int(disk.clusterCount),
                                          clusterSectors: clusterSectors,
                                          format: format(of: disk))

        var files: [DefragFile] = []
        files.reserveCapacity(disk.catalog.files.count)
        for record in disk.catalog.directoryWalkOrder()
        where !record.isResident && !record.extents.isEmpty {
            let category = ClusterCategory(record.category)
            files.append(DefragFile(id: record.id,
                                    path: disk.catalog.path(of: record),
                                    category: category,
                                    walkOrder: files.count,
                                    extents: record.extents,
                                    isMovable: category != .swap))
        }
        return DefragVolume(partition: partition, files: files)
    }
}

extension GeneratedVolumeBridge {

    /// Ce volume se défragmente-t-il ?
    ///
    /// Ce n'est plus une question de taille — le planificateur travaille en
    /// extents et un volume de 320 Go ne lui coûte pas plus qu'un de 180 Mo —
    /// mais de **format** : le défragmenteur simulé est celui de Windows 95,
    /// puis de Windows 98 pour FAT32. NTFS demande une autre stratégie, qui ne
    /// déplace pas les fichiers de la même façon et ne valide pas au même
    /// endroit.
    static func isSupported(_ disk: GeneratedDisk) -> Bool {
        format(of: disk) != .ntfs
            && Int(disk.clusterBytes) >= DriveGeometry.bytesPerSector
    }

    /// Pourquoi ce disque ne se défragmente pas, en une phrase d'écran. `nil`
    /// s'il se défragmente.
    static func refusal(for disk: GeneratedDisk) -> String? {
        guard !isSupported(disk) else { return nil }
        return "Volume NTFS de \(disk.spec.disk.sizeMB) Mo : le défragmenteur simulé est "
            + "celui de Windows 95, qui range les fichiers par la table d'allocation."
    }

    /// Matériel décrit par le profil : géométrie zonée et loi de seek.
    ///
    /// La fiche d'un scénario donne une capacité, un régime, un seek moyen —
    /// et, par sa chronologie, une **année**. C'est ce quatrième nombre qui
    /// fait le gros du travail : la géométrie est celle qu'avaient les disques
    /// vendus cette année-là (`DriveCatalog`), pas une interpolation sur la
    /// seule capacité. Un gigaoctet de 1996, c'est un disque entier de 3 835
    /// pistes ; le même gigaoctet en 2003, c'est un coin de plateau lu cinq
    /// fois plus vite.
    ///
    /// - Parameter atLeast: nombre de secteurs que le disque doit au minimum
    ///   porter, c'est-à-dire la taille de la partition qu'on y pose. Les
    ///   arrondis du formatage peuvent la faire dépasser d'un cheveu la
    ///   capacité nominale, et un LBA hors disque serait silencieusement ramené
    ///   au dernier cylindre.
    static func drive(for spec: ProfileSpec,
                      atLeast sectors: Int) -> (geometry: DriveGeometry, seek: SeekModel) {
        let capacity = max(spec.disk.sizeBytes,
                           UInt64(sectors) * UInt64(DriveGeometry.bytesPerSector))
        // Même typographie que les deux disques écrits à la main : espace fine
        // insécable dans le régime, virgule décimale.
        let size = spec.disk.sizeMB >= 1_024
            ? String(format: "%.1f Go", Double(spec.disk.sizeMB) / 1_024)
                .replacingOccurrences(of: ".", with: ",")
            : "\(spec.disk.sizeMB) Mo"
        let rpm = String(format: "%d\u{202F}%03d", spec.disk.rpm / 1_000, spec.disk.rpm % 1_000)
        let label = "IDE \(size) · \(rpm) tr/min"
        let year = spec.timeline.start.year
        let geometry = DriveGeometry.era(model: label,
                                         capacityBytes: capacity,
                                         rpm: spec.disk.rpm,
                                         year: year,
                                         zbr: spec.disk.zbr)
        let seek = SeekModel.calibrated(averageSeekMs: spec.disk.averageSeekMs,
                                        trackToTrackMs: spec.disk.trackToTrackMs
                                            ?? DriveCatalog.trackToTrackMs(year: year),
                                        cylinders: geometry.cylinders)
        return (geometry, seek)
    }
}
