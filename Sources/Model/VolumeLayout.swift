import Foundation
import DiskCore

/// Le format d'un volume, vu du seul point de vue qui intéresse un
/// défragmenteur : **où sont les métadonnées, et combien coûte une validation**.
///
/// C'est là que se joue la signature sonore d'une passe, bien plus que dans
/// l'algorithme. Valider un déplacement sur FAT, c'est trois écritures au tout
/// début de la partition — les deux copies de la table et l'entrée de
/// répertoire — donc un retour du bras au bord du plateau à peu près une fois
/// par fichier : le « clac … clac … clac » régulier.
///
/// Sur NTFS, c'est un enregistrement de la MFT et un secteur de `$Bitmap`,
/// **et le journal**. NTFS journalise en écriture anticipée : aucune
/// modification de métadonnées n'atteint le disque avant que son
/// enregistrement de journal y soit, et `$LogFile` est un bloc fixe, posé au
/// formatage. Le bras y revient donc, lui aussi — mais pas à chaque
/// validation : le *lazy writer* remplit une page de journal de plusieurs
/// validations avant de l'écrire. En lecture, rien de tout cela n'existe, et le
/// bras n'a aucune raison de revenir au bord ; en écriture, il y revient par
/// **rafales espacées**, et non régulièrement comme sur FAT.
enum VolumeFormat: Sendable {
    case fat16
    case fat32
    case ntfs

    /// Le format tel que le générateur le nomme : la place que prennent ses
    /// tables se calcule au même endroit pour les deux (`FormatOverhead`).
    var kind: FileSystemKind {
        switch self {
        case .fat16: return .fat16
        case .fat32: return .fat32
        case .ntfs:  return .ntfs
        }
    }

    /// Octets décrivant un cluster dans la table d'allocation. NTFS n'a pas de
    /// table de chaînage : il décrit les fichiers par extents dans la MFT.
    var fatEntryBytes: Int { FormatOverhead.entryBytes(kind) }

    var isFAT: Bool { self != .ntfs }

    /// Secteurs réservés en tête de partition, avant la première table.
    ///
    /// Un seul sur FAT16 — le secteur d'amorçage — mais **trente-deux** sur
    /// FAT32 : l'amorçage y tient sur trois secteurs, `FSINFO` suit, une copie
    /// de secours de l'ensemble est posée au secteur 6, et `FORMAT` réserve le
    /// reste. Sur NTFS, aucun : `$Boot` est le cluster 0 du volume, un
    /// métafichier comme les autres, et seule la copie du secteur d'amorçage,
    /// au tout dernier secteur, est hors des clusters. Jusqu'au lot 8, le
    /// modèle réservait ici les seize secteurs de `$Boot` **en plus** des deux
    /// clusters que le générateur lui donne.
    var reservedSectors: Int { FormatOverhead.reservedSectors(kind) }

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
    /// Où `FORMAT` a posé les métafichiers d'un NTFS : près du début depuis
    /// Windows 2000, au milieu du volume avant. Sans objet sur FAT.
    var ntfsPlacement: NTFSAllocator.MirrorPlacement = .nearStart

    /// Partition occupant un nombre de secteurs donné, dimensionnée comme
    /// l'aurait fait l'outil de formatage du système — et comme le générateur
    /// compte ses clusters (`FormatOverhead`).
    init(startLBA: Int, sectors: Int, clusterSectors: Int, format: VolumeFormat = .fat16) {
        self.startLBA = startLBA
        self.clusterSectors = clusterSectors
        self.format = format
        let count = FormatOverhead.clusterCount(volumeSectors: sectors,
                                                clusterSectors: clusterSectors,
                                                kind: format.kind)
        self.clusterCount = count
        self.fatSectors = FormatOverhead.tableSectors(clusterCount: count, kind: format.kind)

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
        self.fatSectors = FormatOverhead.tableSectors(clusterCount: clusterCount, kind: format.kind)
        precondition(clusterCount > 0, "partition vide")
    }

    // MARK: - Plan du volume

    var fat1LBA: Int { startLBA + format.reservedSectors }
    var fat2LBA: Int { fat1LBA + fatSectors }
    var rootLBA: Int { fat2LBA + fatSectors }
    var rootSectorCount: Int { FormatOverhead.rootSectors(format.kind) }

    var dataStartLBA: Int {
        switch format {
        case .fat16, .fat32: return rootLBA + rootSectorCount
        case .ntfs:          return startLBA + format.reservedSectors
        }
    }

    var clusterBytes: Int { clusterSectors * DriveGeometry.bytesPerSector }
    var capacityBytes: Int { clusterCount * clusterBytes }

    /// Secteurs occupés par la partition, tables comprises : le disque qui la
    /// porte doit en compter au moins autant. Sur NTFS, la copie du secteur
    /// d'amorçage suit le dernier cluster.
    var totalSectors: Int {
        dataStartLBA - startLBA + clusterCount * clusterSectors + (format == .ntfs ? 1 : 0)
    }

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

    /// Secteurs à lire pour obtenir `bytes` octets d'un fichier, quand le
    /// système lit par unités de `granularity` octets — la page du cache, ou
    /// le secteur. Le cluster n'y entre pas : c'est l'unité d'allocation, pas
    /// de lecture.
    static func readSectors(forBytes bytes: Int, granularity: Int) -> Int {
        let unit = max(granularity, DriveGeometry.bytesPerSector)
        let rounded = (max(bytes, 1) + unit - 1) / unit * unit
        return (rounded + DriveGeometry.bytesPerSector - 1) / DriveGeometry.bytesPerSector
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

    /// Taille d'un enregistrement de la MFT.
    ///
    /// Un enregistrement fait un kilo-octet, et c'est cette granularité-là qui
    /// compte : déplacer un fichier réécrit **un** enregistrement, pas une
    /// table entière.
    var mftRecordSectors: Int { max(1_024 / DriveGeometry.bytesPerSector, 1) }

    /// Les métafichiers de NTFS, là où le générateur les a posés : la règle
    /// est la même (`NTFSAllocator.layout`), et elle ne se recopie pas.
    var ntfsLayout: NTFSAllocator.Layout {
        NTFSAllocator.layout(profile: NTFSProfile(clusterKB: UInt32(max(clusterBytes / 1_024, 1))),
                             clusterCount: UInt32(clusterCount),
                             mirrorPlacement: ntfsPlacement)
    }

    /// Premier secteur de `$MFT`. Son enregistrement *n* est `n` kilo-octets
    /// plus loin.
    var mftLBA: Int {
        format == .ntfs ? lba(ofCluster: Int(ntfsLayout.mftStart)) : dataStartLBA
    }

    // MARK: - Le journal

    /// Une page de journal : 4 Ko, l'unité dans laquelle NTFS écrit
    /// `$LogFile`.
    static let logPageSectors = 8

    /// Validations dont les enregistrements remplissent une page de journal.
    ///
    /// Déplacer ou créer un fichier journalise la modification de son
    /// enregistrement de MFT et celle des bits de `$Bitmap`, en *redo* et en
    /// *undo* : quelques enregistrements de cent à deux cents octets, soit de
    /// l'ordre du demi-kilo-octet par validation, et huit validations par
    /// page de 4 Ko. C'est un ordre de grandeur, pas une mesure — et c'est lui
    /// qui fixe le rythme des rafales.
    static let validationsPerLogPage = 8

    /// Premier secteur de `$LogFile`, là où le générateur l'a posé. Ses deux
    /// premières pages sont la zone de redémarrage, que le montage lit et que
    /// le pilote réécrit quand il déclare le volume propre ou sale.
    var logFileLBA: Int { lba(ofCluster: Int(ntfsLayout.logFile.start)) }

    /// La page `index` de la zone circulaire du journal, qui suit les deux
    /// pages de redémarrage et reboucle à la fin du fichier.
    func logPage(_ index: Int) -> MetadataAccess {
        let sectors = Int(ntfsLayout.logFile.length) * clusterSectors
        let pages = max(sectors / Self.logPageSectors - 2, 1)
        return MetadataAccess(lba: logFileLBA + (2 + index % pages) * Self.logPageSectors,
                              sectors: Self.logPageSectors)
    }

    /// La page où tombent les enregistrements de la validation `validation`.
    func logPage(forValidation validation: Int) -> MetadataAccess {
        logPage(max(validation, 0) / Self.validationsPerLogPage)
    }

    /// Ce que le pilote écrit en montant le volume, pour le déclarer en
    /// service : l'octet d'état de la table sur FAT, la zone de redémarrage du
    /// journal sur NTFS.
    var mountWrite: MetadataAccess {
        format.isFAT
            ? MetadataAccess(lba: fat1LBA, sectors: 1)
            : MetadataAccess(lba: logFileLBA, sectors: Self.logPageSectors)
    }

    /// Les écritures qui valident le déplacement d'un fichier.
    ///
    /// - Parameters:
    ///   - cluster: premier cluster de sa nouvelle position — c'est lui qui
    ///     désigne le secteur de table à réécrire ;
    ///   - fileIndex: rang du fichier, qui désigne son enregistrement MFT ;
    ///   - entrySector: sur FAT, le secteur de son répertoire qui porte son
    ///     entrée, là où l'allocateur a posé ce répertoire
    ///     (`DefragVolume.entrySector`). `nil` pour un volume qui ne connaît pas
    ///     ses répertoires — un volume d'essai : l'entrée est alors écrite dans
    ///     la racine, comme le faisait le modèle avant d'en avoir ;
    ///   - validation: rang de cette validation dans la passe. Sur NTFS, la
    ///     page de journal n'est écrite que par la validation qui la remplit —
    ///     une sur `validationsPerLogPage` —, et `nil` laisse l'écriture du
    ///     journal à l'appelant, quand c'est un cache qui vide ses tables à
    ///     son propre rythme (`MachineWriter`).
    func commitAccesses(forCluster cluster: Int, fileIndex: Int, entrySector: Int? = nil,
                        validation: Int?) -> [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            // Les deux copies de la table, au tout début de la partition, puis
            // l'entrée de répertoire, là où vit le répertoire : dans la racine
            // pour un fichier de la racine d'un FAT16, ailleurs pour tous les
            // autres — souvent loin du bord, parfois tout près du fichier.
            let sector = fatSector(forCluster: cluster)
            let entry = entrySector
                ?? rootLBA + (rootSectorCount > 0 ? cluster % rootSectorCount : 0)
            return [
                MetadataAccess(lba: fat1LBA + sector, sectors: 2),
                MetadataAccess(lba: fat2LBA + sector, sectors: 2),
                MetadataAccess(lba: entry, sectors: 1),
            ]
        case .ntfs:
            // Un seul enregistrement MFT réécrit, et la bitmap du volume. La
            // MFT est en tête du volume, mais un enregistrement n'est pas la
            // table entière : c'est un kilo-octet. Et, une validation sur
            // huit, la page de journal que les précédentes ont remplie.
            var accesses = [
                MetadataAccess(lba: mftLBA + fileIndex * mftRecordSectors,
                               sectors: mftRecordSectors),
                MetadataAccess(lba: bitmapLBA + cluster / (8 * DriveGeometry.bytesPerSector),
                               sectors: 1),
            ]
            if let validation, (validation + 1) % Self.validationsPerLogPage == 0 {
                accesses.append(logPage(forValidation: validation))
            }
            return accesses
        }
    }

    /// Premier secteur de `$Bitmap`, là où le générateur l'a posée : derrière
    /// la zone MFT d'origine (`NTFSAllocator.Layout.bitmap`).
    var bitmapLBA: Int { lba(ofCluster: Int(ntfsLayout.bitmap.start)) }

    /// Ce que coûte l'**ouverture** d'un fichier, une fois son répertoire lu.
    ///
    /// Sur FAT, rien de plus : l'entrée est dans le répertoire qu'on vient de
    /// parcourir. La table, elle, n'est pas lue ici : sur FAT16 elle a été lue
    /// entière au montage et tient en mémoire ; sur FAT32 elle se lit par pages
    /// au fil des chaînes que suit la lecture des données (`BootPlanner`).
    ///
    /// Sur NTFS, chaque ouverture lit l'enregistrement de MFT qui décrit le
    /// fichier. La MFT est en tête de la zone de données, les données sont
    /// ailleurs : c'est cet aller-retour, une fois par fichier, qui donne à un
    /// démarrage NTFS son bruit à lui.
    ///
    /// Le répertoire se lit avant, là où l'allocateur l'a posé
    /// (`directoryAccesses`) : c'est l'appelant qui sait lequel, et jusqu'où.
    func openAccesses(fileIndex: Int) -> [MetadataAccess] {
        switch format {
        case .fat16, .fat32:
            return []
        case .ntfs:
            return [MetadataAccess(lba: mftLBA + fileIndex * mftRecordSectors,
                                   sectors: mftRecordSectors)]
        }
    }

    /// Sur FAT, le secteur où s'écrit l'entrée d'un fichier créé ou modifié
    /// dans ce répertoire, quand on ne sait pas à quel octet : son dernier
    /// cluster, là où s'ajoutent les nouvelles entrées — ou la racine d'un
    /// FAT16. `nil` hors FAT, ou pour un répertoire qui n'est pas sur le
    /// disque.
    func entrySector(inDirectory directory: DirectoryRecord?) -> Int? {
        guard format.isFAT, let directory, directory.exists else { return nil }
        if let last = directory.extents.last { return lba(ofCluster: Int(last.end - 1)) }
        if directory.parent == nil, rootSectorCount > 0 { return rootLBA }
        return nil
    }

    /// La lecture des clusters `range` d'un répertoire — rangs dans sa chaîne,
    /// dans l'ordre du répertoire —, morceau par morceau : un répertoire en
    /// trois morceaux coûte trois lectures, et deux déplacements du bras.
    func directoryAccesses(_ extents: [Extent], clusters range: Range<UInt32>) -> [MetadataAccess] {
        var accesses: [MetadataAccess] = []
        var offset: UInt32 = 0
        for extent in extents {
            defer { offset += extent.length }
            let low = max(range.lowerBound, offset)
            let high = min(range.upperBound, offset + extent.length)
            guard low < high else { continue }
            accesses.append(MetadataAccess(lba: lba(ofCluster: Int(extent.start + (low - offset))),
                                           sectors: Int(high - low) * clusterSectors))
        }
        return accesses
    }

    /// Ce que lit le pilote pour **monter** le volume, avant d'ouvrir le
    /// premier fichier.
    ///
    /// Ce n'est pas l'analyse d'un défragmenteur (`scanAccesses`), qui a
    /// besoin de connaître chaque cluster et lit donc toute la table : un
    /// pilote ne lit que ce qui lui permet de servir la première ouverture, et
    /// va chercher le reste à la demande.
    ///
    /// Sur aucun format la copie de secours n'est lue : FAT2 n'est consultée
    /// que si FAT1 est illisible.
    var mountAccesses: [MetadataAccess] {
        switch format {
        case .fat16:
            // Le secteur d'amorçage, la première table **entière**, la racine.
            // Une table FAT16 fait au plus 128 Ko et tient en mémoire : c'est
            // pour cela que lire un fichier fragmenté n'y coûte aucun retour à
            // la table (`openAccesses`). La lire au montage est le prix de
            // cette hypothèse, et il est payé une fois.
            return [MetadataAccess(lba: startLBA, sectors: 1),
                    MetadataAccess(lba: fat1LBA, sectors: fatSectors),
                    MetadataAccess(lba: rootLBA, sectors: rootSectorCount)]
        case .fat32:
            // Le secteur d'amorçage et `FSINFO` — qui donne le nombre de
            // clusters libres et le curseur `next-free`, précisément pour que
            // le pilote n'ait pas à parcourir la table —, le premier secteur de
            // la table, qui porte les bits d'état du volume, et le premier
            // cluster de la racine. Une table FAT32 fait des mégaoctets : VFAT
            // en met les secteurs en cache **à la demande**, au fil des
            // chaînes qu'il suit.
            return [MetadataAccess(lba: startLBA, sectors: 2),
                    MetadataAccess(lba: fat1LBA, sectors: 1),
                    MetadataAccess(lba: dataStartLBA, sectors: clusterSectors)]
        case .ntfs:
            // Monter un NTFS, ce n'est pas lire la MFT : c'est lire `$Boot`,
            // aller vérifier sa copie au **tout dernier secteur du volume**,
            // lire les seize premiers enregistrements de la MFT — ceux des
            // métafichiers —, les comparer à `$MFTMirr`, puis ouvrir `$Bitmap`.
            // Quelques dizaines de kilo-octets, répartis sur trois zones du
            // volume : le début, la bitmap derrière la zone MFT, et le fond du
            // disque. Peu de transfert, beaucoup de seeks. Le reste de la MFT
            // se lit à la demande, enregistrement par enregistrement.
            //
            // Entre les deux, la zone de redémarrage de `$LogFile` : c'est elle
            // qui dit si le volume a été démonté proprement. S'il ne l'a pas
            // été, le journal est rejoué — un démarrage de la galerie suit
            // toujours un arrêt propre, et ne rejoue rien.
            let layout = ntfsLayout
            return [MetadataAccess(lba: startLBA, sectors: 16),
                    MetadataAccess(lba: startLBA + totalSectors - 1, sectors: 1),
                    MetadataAccess(lba: mftLBA, sectors: 16 * mftRecordSectors),
                    MetadataAccess(lba: lba(ofCluster: Int(layout.mirror.start)),
                                   sectors: 4 * mftRecordSectors),
                    MetadataAccess(lba: logFileLBA, sectors: 2 * Self.logPageSectors),
                    MetadataAccess(lba: bitmapLBA, sectors: 8)]
        }
    }

    /// Ce que lit l'analyse initiale d'un défragmenteur : les tables, puis
    /// l'arborescence.
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
            // volume**, et non à côté de l'original : une course complète du
            // bras jusqu'au fond du disque, aller et retour.
            //
            // La MFT se lit ensuite d'une traite : c'est elle qui décrit tout
            // le volume, et un défragmenteur doit la connaître entière.
            let mftSectors = max(clusterCount / 8, 1) * mftRecordSectors / 8
            return [MetadataAccess(lba: startLBA, sectors: 16),
                    MetadataAccess(lba: startLBA + totalSectors - 1, sectors: 1),
                    MetadataAccess(lba: mftLBA, sectors: min(mftSectors, 4_096))]
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
            return [MetadataAccess(lba: mftLBA, sectors: 64)]
        }
    }
}
