import Foundation
import DiskCore

/// Le format d'un volume, vu du seul point de vue qui intéresse un
/// défragmenteur : **où sont les métadonnées, et combien coûte une validation**.
///
/// C'est là que se joue la signature sonore d'une passe, bien plus que dans
/// l'algorithme. Valider un déplacement sur FAT, c'est trois écritures au tout
/// début de la partition — les deux copies de la table et l'entrée de
/// répertoire — donc un retour du bras au bord du plateau à peu près une fois
/// par fichier : le « clac … clac … clac » régulier. Sur NTFS, c'est un
/// enregistrement de la MFT, qui est un fichier comme un autre et vit là où il
/// a été alloué ; le bras n'a aucune raison de revenir au bord.
enum VolumeFormat: Sendable {
    case fat16
    case fat32
    case ntfs

    /// Octets décrivant un cluster dans la table d'allocation. NTFS n'a pas de
    /// table de chaînage : il décrit les fichiers par extents dans la MFT.
    var fatEntryBytes: Int {
        switch self {
        case .fat16: return 2
        case .fat32: return 4
        case .ntfs:  return 0
        }
    }

    var isFAT: Bool { self != .ntfs }

    /// Secteurs réservés en tête de partition, avant la première table.
    ///
    /// Un seul sur FAT16 — le secteur d'amorçage — mais **trente-deux** sur
    /// FAT32 : l'amorçage y tient sur trois secteurs, `FSINFO` suit, une copie
    /// de secours de l'ensemble est posée au secteur 6, et `FORMAT` réserve le
    /// reste. Sur NTFS, `$Boot` occupe les huit premiers kilo-octets du volume,
    /// et une copie du secteur d'amorçage est au tout dernier secteur.
    var reservedSectors: Int {
        switch self {
        case .fat16: return 1
        case .fat32: return 32
        case .ntfs:  return 16
        }
    }

    var label: String {
        switch self {
        case .fat16: return "FAT16"
        case .fat32: return "FAT32"
        case .ntfs:  return "NTFS"
        }
    }
}

/// Une lecture ou une écriture de métadonnées, en secteurs.
struct MetadataAccess {
    let lba: Int
    let sectors: Int
}

/// Géométrie d'une partition posée sur le disque.
///
/// Pour les formats FAT, le calcul du nombre de clusters est circulaire — la
/// taille de la table dépend du nombre de clusters, qui dépend de la place
/// restante après la table — et se résout par quelques itérations, exactement
/// comme le fait `FORMAT`. Le cluster 0 de ce modèle est le premier cluster de
/// **données** : les tables sont en dehors, comme dans la bitmap du générateur.
///
/// Sur NTFS il n'y a rien de tout cela : le volume est une suite de clusters
/// depuis le premier, et les fichiers système — `$Boot`, `$MFT`, `$Bitmap` —
/// en occupent une partie comme n'importe quel fichier.
struct PartitionGeometry {

    let startLBA: Int
    let clusterSectors: Int
    let clusterCount: Int
    let format: VolumeFormat
    /// Secteurs d'une copie de la table d'allocation. Nul sur NTFS.
    let fatSectors: Int

    /// 512 entrées de 32 octets : la racine d'un FAT16, de taille fixe. FAT32
    /// et NTFS n'en ont pas — leur racine est un fichier ordinaire.
    private static let fat16RootSectors = 32

    /// Partition occupant un nombre de secteurs donné, dimensionnée comme
    /// l'aurait fait l'outil de formatage du système.
    init(startLBA: Int, sectors: Int, clusterSectors: Int, format: VolumeFormat = .fat16) {
        self.startLBA = startLBA
        self.clusterSectors = clusterSectors
        self.format = format

        switch format {
        case .fat16, .fat32:
            let root = format == .fat16 ? Self.fat16RootSectors : 0
            let overhead = format.reservedSectors + root
            let entryBytes = format.fatEntryBytes
            var n = (sectors - overhead) / clusterSectors
            var fat = 0
            for _ in 0..<3 {
                fat = Int(ceil(Double(n) * Double(entryBytes) / Double(DriveGeometry.bytesPerSector)))
                n = (sectors - overhead - 2 * fat) / clusterSectors
            }
            self.fatSectors = fat
            self.clusterCount = n
        case .ntfs:
            self.fatSectors = 0
            self.clusterCount = (sectors - format.reservedSectors) / clusterSectors
        }

        precondition(clusterCount > 0, "partition vide")
        precondition(format != .fat16 || clusterCount < 65_525, "hors des bornes FAT16")
    }

    /// Partition qui contient exactement un nombre de clusters donné, tables
    /// comprises. C'est par là qu'entre un volume venu du générateur : son
    /// nombre de clusters de données est déjà fixé, on lui construit la
    /// partition qui va autour.
    init(startLBA: Int, clusterCount: Int, clusterSectors: Int, format: VolumeFormat) {
        self.startLBA = startLBA
        self.clusterSectors = clusterSectors
        self.clusterCount = clusterCount
        self.format = format
        self.fatSectors = format.isFAT
            ? Int(ceil(Double(clusterCount) * Double(format.fatEntryBytes)
                       / Double(DriveGeometry.bytesPerSector)))
            : 0
        precondition(clusterCount > 0, "partition vide")
    }

    // MARK: - Plan du volume

    var fat1LBA: Int { startLBA + format.reservedSectors }
    var fat2LBA: Int { fat1LBA + fatSectors }
    var rootLBA: Int { fat2LBA + fatSectors }
    var rootSectorCount: Int { format == .fat16 ? Self.fat16RootSectors : 0 }

    var dataStartLBA: Int {
        switch format {
        case .fat16, .fat32: return rootLBA + rootSectorCount
        case .ntfs:          return startLBA + format.reservedSectors
        }
    }

    var clusterBytes: Int { clusterSectors * DriveGeometry.bytesPerSector }
    var capacityBytes: Int { clusterCount * clusterBytes }

    /// Secteurs occupés par la partition, tables comprises : le disque qui la
    /// porte doit en compter au moins autant.
    var totalSectors: Int { dataStartLBA - startLBA + clusterCount * clusterSectors }

    func lba(ofCluster cluster: Int) -> Int {
        dataStartLBA + cluster * clusterSectors
    }

    /// Secteur de la table d'allocation qui décrit ce cluster.
    func fatSector(forCluster cluster: Int) -> Int {
        guard format.isFAT else { return 0 }
        return cluster * format.fatEntryBytes / DriveGeometry.bytesPerSector
    }

    func clusters(forBytes bytes: Int) -> Int {
        max(1, Int(ceil(Double(bytes) / Double(clusterBytes))))
    }

    var capacityDescription: String {
        let bytes = Double(capacityBytes)
        return bytes >= 1_000_000_000
            ? String(format: "%.1f Go", bytes / 1_000_000_000).replacingOccurrences(of: ".", with: ",")
            : String(format: "%.0f Mo", bytes / 1_000_000)
    }
}

// MARK: - Ce que coûte une validation

extension PartitionGeometry {

    /// Emplacement de la MFT : au tout début de la zone de données, juste
    /// derrière `$Boot`, et suivie de la zone que NTFS lui réserve.
    ///
    /// Un enregistrement fait un kilo-octet, et c'est cette granularité-là qui
    /// compte : déplacer un fichier réécrit **un** enregistrement, pas une
    /// table entière.
    var mftRecordSectors: Int { max(1_024 / DriveGeometry.bytesPerSector, 1) }

    /// Les écritures qui valident le déplacement d'un fichier.
    ///
    /// - Parameters:
    ///   - cluster: premier cluster de sa nouvelle position — c'est lui qui
    ///     désigne le secteur de table à réécrire ;
    ///   - fileIndex: rang du fichier, qui désigne son enregistrement MFT.
    func commitAccesses(forCluster cluster: Int, fileIndex: Int) -> [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            // Les deux copies de la table et l'entrée de répertoire, toutes au
            // tout début de la partition : le bras y revient une fois par
            // fichier déplacé.
            let sector = fatSector(forCluster: cluster)
            return [
                MetadataAccess(lba: fat1LBA + sector, sectors: 2),
                MetadataAccess(lba: fat2LBA + sector, sectors: 2),
                MetadataAccess(lba: rootLBA + (rootSectorCount > 0 ? cluster % rootSectorCount : 0),
                               sectors: 1),
            ]
        case .ntfs:
            // Un seul enregistrement MFT réécrit, et la bitmap du volume. La
            // MFT est au début de la zone de données, mais un enregistrement
            // n'est pas la table entière : c'est un kilo-octet.
            return [
                MetadataAccess(lba: dataStartLBA + fileIndex * mftRecordSectors,
                               sectors: mftRecordSectors),
                MetadataAccess(lba: dataStartLBA + bitmapOffsetSectors + cluster / (8 * DriveGeometry.bytesPerSector),
                               sectors: 1),
            ]
        }
    }

    /// Décalage de `$Bitmap` depuis le début de la zone de données : elle vient
    /// après la MFT et la zone qui lui est réservée.
    private var bitmapOffsetSectors: Int {
        Int(Double(clusterCount) * 0.125) * clusterSectors
    }

    /// Ce que coûte l'**ouverture** d'un fichier, avant d'en lire un octet.
    ///
    /// Sur FAT, presque rien : la table est lue une fois au montage et tient en
    /// mémoire, et l'entrée de répertoire a été lue en même temps que celles de
    /// ses voisines. Seule la première ouverture dans un répertoire coûte une
    /// lecture — et elle se paie là où vit ce répertoire, c'est-à-dire près des
    /// fichiers qu'il contient, faute de savoir où l'allocateur a posé ses
    /// clusters : c'est une approximation, et la seule de ce modèle.
    ///
    /// Sur NTFS, chaque ouverture lit l'enregistrement de MFT qui décrit le
    /// fichier. La MFT est en tête de la zone de données, les données sont
    /// ailleurs : c'est cet aller-retour, une fois par fichier, qui donne à un
    /// démarrage NTFS son bruit à lui.
    func openAccesses(fileIndex: Int, directoryFirstCluster: UInt32?) -> [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            guard let cluster = directoryFirstCluster else { return [] }
            return [MetadataAccess(lba: lba(ofCluster: Int(cluster)), sectors: clusterSectors)]
        case .ntfs:
            return [MetadataAccess(lba: dataStartLBA + fileIndex * mftRecordSectors,
                                   sectors: mftRecordSectors)]
        }
    }

    /// Ce que lit l'analyse initiale : les tables, puis l'arborescence.
    var scanAccesses: [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            var accesses = [MetadataAccess(lba: startLBA, sectors: 1),
                            MetadataAccess(lba: fat1LBA, sectors: fatSectors),
                            MetadataAccess(lba: fat2LBA, sectors: fatSectors)]
            if rootSectorCount > 0 {
                accesses.append(MetadataAccess(lba: rootLBA, sectors: rootSectorCount))
            }
            return accesses
        case .ntfs:
            // `$Boot`, puis sa copie — qui est au **tout dernier secteur du
            // volume**, et non à côté de l'original. Monter un NTFS commence
            // donc par une course complète du bras jusqu'au fond du disque,
            // aller et retour : c'est un accès isolé, et il s'entend.
            //
            // La MFT se lit ensuite d'une traite : c'est elle qui décrit tout
            // le volume.
            let mftSectors = max(clusterCount / 8, 1) * mftRecordSectors / 8
            return [MetadataAccess(lba: startLBA, sectors: 16),
                    MetadataAccess(lba: startLBA + totalSectors - 1, sectors: 1),
                    MetadataAccess(lba: dataStartLBA, sectors: min(mftSectors, 4_096))]
        }
    }

    /// La réécriture complète des tables, une fois la passe terminée.
    var finalAccesses: [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            var accesses = [MetadataAccess(lba: fat1LBA, sectors: fatSectors),
                            MetadataAccess(lba: fat2LBA, sectors: fatSectors)]
            if rootSectorCount > 0 {
                accesses.append(MetadataAccess(lba: rootLBA, sectors: rootSectorCount))
            }
            return accesses
        case .ntfs:
            return [MetadataAccess(lba: dataStartLBA, sectors: 64)]
        }
    }
}
