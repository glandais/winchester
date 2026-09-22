import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que le pilote lit pour monter un volume, ce qu'une lecture coûte vraiment,
/// et où NTFS écrit son journal.
///
/// Chacune de ces propriétés change une durée de démarrage, et `ThinkModel` a
/// été recalé par-dessus : si l'une d'elles régressait, le total pourrait
/// rester juste et le son être faux. Les chiffres sont donc vérifiés en octets
/// et en positions, pas en durées.
@Suite("Montage, lecture et journal")
struct MountAndJournalTests {

    private static func spec(_ id: String) throws -> ProfileSpec {
        try #require(try ScenarioLibrary.loadAll().first { $0.id == id })
    }

    /// La partition d'un profil de la galerie, sans générer le volume.
    private static func partition(_ id: String) throws -> PartitionGeometry {
        let spec = try spec(id)
        let format: VolumeFormat = switch spec.fileSystem.type {
        case .fat16, .vfat: .fat16
        case .fat32: .fat32
        case .ntfs: .ntfs
        }
        var partition = PartitionGeometry(
            startLBA: 0, clusterCount: Int(spec.clusterCount),
            clusterSectors: Int(spec.resolvedFileSystem().clusterBytes) / DriveGeometry.bytesPerSector,
            format: format)
        partition.ntfsPlacement = DiskGenerator.mirrorPlacement(for: spec)
        return partition
    }

    private static func bytes(_ accesses: [MetadataAccess]) -> Int {
        accesses.reduce(0) { $0 + $1.sectors } * DriveGeometry.bytesPerSector
    }

    // MARK: - Le montage

    /// La copie de secours n'est consultée que si la première table est
    /// illisible, et le pilote met la table FAT32 en cache à la demande : au
    /// montage, il ne lit que l'amorçage, `FSINFO`, l'état du volume et la
    /// racine. Sur `gamer-1999`, c'était 8,6 Mo de table, deux fois.
    @Test("Monter un FAT32 lit une dizaine de kilo-octets, et jamais FAT2",
          arguments: ["dev-1999", "famille-1999", "gamer-1999", "secretaire-1999"])
    func fat32Mount(id: String) throws {
        let partition = try Self.partition(id)
        #expect(partition.format == .fat32)
        let mount = partition.mountAccesses
        let bytes = Self.bytes(mount)
        #expect(bytes >= 4 * 1_024 && bytes <= 16 * 1_024,
                "\(id) : \(bytes) octets lus au montage")
        let fat2 = partition.fat2LBA..<(partition.fat2LBA + partition.fatSectors)
        for access in mount {
            #expect(!fat2.overlaps(access.lba..<(access.lba + access.sectors)),
                    "le montage lit FAT2 en \(access.lba)")
        }
        // Ce que lit l'analyse d'un défragmenteur, elle, n'a pas bougé : elle
        // doit connaître chaque cluster.
        #expect(Self.bytes(partition.scanAccesses) > 2 * partition.fatSectors * DriveGeometry.bytesPerSector - 1)
    }

    /// FAT16 garde sa table entière en mémoire — c'est ce qui dispense la
    /// lecture d'un fichier fragmenté de tout retour à la table —, mais une
    /// seule copie.
    @Test("Monter un FAT16 lit la première table entière, pas la seconde")
    func fat16Mount() throws {
        let partition = try Self.partition("dev-1996")
        let mount = partition.mountAccesses
        #expect(mount.contains { $0.lba == partition.fat1LBA && $0.sectors == partition.fatSectors })
        #expect(!mount.contains { $0.lba == partition.fat2LBA })
    }

    /// `$Boot`, les seize premiers enregistrements de la MFT, `$MFTMirr` et la
    /// zone de redémarrage du journal en tête ; `$Bitmap` derrière la zone MFT ;
    /// la copie du secteur d'amorçage au fond du disque. Quelques dizaines de
    /// kilo-octets en trois endroits, là où le modèle lisait 2 Mo d'un trait.
    @Test("Monter un NTFS touche trois zones du volume, pas une plage de 2 Mo",
          arguments: ["dev-2003", "famille-2007"])
    func ntfsMount(id: String) throws {
        let partition = try Self.partition(id)
        let mount = partition.mountAccesses
        let bytes = Self.bytes(mount)
        #expect(bytes <= 64 * 1_024, "\(id) : \(bytes) octets lus au montage")
        #expect(mount.allSatisfy { $0.sectors * DriveGeometry.bytesPerSector <= 16 * 1_024 })

        // Deux accès sont dans la même zone s'ils sont à moins d'un centième
        // du volume l'un de l'autre.
        let span = partition.totalSectors / 100
        var zones: [Int] = []
        for lba in mount.map(\.lba).sorted() {
            if let last = zones.last, lba - last < span { zones[zones.count - 1] = lba } else { zones.append(lba) }
        }
        #expect(zones.count == 3, "\(id) : zones \(zones)")
        #expect(mount.contains { $0.lba == partition.startLBA + partition.totalSectors - 1 })
    }

    /// Le modèle de volume et le générateur appliquent la même règle : le
    /// montage lit la MFT et le journal là où ils ont été posés.
    @Test("Le simulateur écrit le journal là où le générateur l'a posé")
    func logFileAgreesWithGenerator() throws {
        var small = try Self.spec("secretaire-2003")
        small.disk.sizeMB = 2_000
        small.timeline.end = small.timeline.start.adding(days: 30)
        let disk = try DiskGenerator.generate(small)
        let partition = GeneratedVolumeBridge.partition(of: disk)
        let layout = partition.ntfsLayout

        #expect(disk.systemExtents.contains(layout.logFile))
        #expect(disk.systemExtents.contains(layout.mirror))
        let log = layout.logFile.start..<layout.logFile.end
        #expect(disk.catalog.files.allSatisfy { record in
            !record.extents.contains { log.overlaps($0.start..<$0.end) }
        }, "un fichier est posé sur le journal")
        #expect(partition.logFileLBA == partition.lba(ofCluster: Int(layout.logFile.start)))
        #expect(partition.mftLBA == partition.lba(ofCluster: Int(layout.mftStart)))
        // 2 Go : sous les 12 Gio au-delà desquels le journal fait 64 Mio.
        #expect(Int(layout.logFile.length) * partition.clusterBytes == 4 << 20)

        // `$Bitmap`, que la validation d'un déplacement réécrit : posée par le
        // générateur, lue au même endroit, et aucun fichier dessus.
        #expect(disk.systemExtents.contains(layout.bitmap))
        let bitmap = layout.bitmap.start..<layout.bitmap.end
        #expect(disk.catalog.files.allSatisfy { record in
            !record.extents.contains { bitmap.overlaps($0.start..<$0.end) }
        }, "un fichier est posé sur $Bitmap")
        #expect(partition.bitmapLBA == partition.lba(ofCluster: Int(layout.bitmap.start)))
        // `$Boot` est le cluster 0 : le montage le lit là, et nulle part avant.
        #expect(partition.dataStartLBA == partition.startLBA)
        #expect(partition.mountAccesses.contains { $0.lba == partition.lba(ofCluster: 0) })
    }

    /// Le générateur et le simulateur décrivent le même volume : la partition
    /// posée autour des clusters générés, tables comprises, tient sur le
    /// disque que décrit le profil — sur `gamer-1999`, elle le dépassait des
    /// 17 Mo de ses deux tables.
    @Test("La partition tient sur le disque du profil")
    func partitionFitsTheDisk() throws {
        for spec in try ScenarioLibrary.loadAll() {
            let partition = try Self.partition(spec.id)
            let sectors = Int(spec.disk.sizeBytes) / DriveGeometry.bytesPerSector
            #expect(partition.totalSectors <= sectors,
                    "\(spec.id) : \(partition.totalSectors) secteurs pour \(sectors)")
            // Et la partition dimensionnée par le simulateur à partir du disque
            // compte les mêmes clusters que le générateur.
            let rebuilt = PartitionGeometry(startLBA: 0, sectors: sectors,
                                            clusterSectors: partition.clusterSectors,
                                            format: partition.format)
            #expect(rebuilt.clusterCount == partition.clusterCount, "\(spec.id)")
        }
    }

    // MARK: - La granularité de lecture

    /// Le cluster est l'unité d'allocation, pas de lecture. Sur `dev-1996`, en
    /// clusters de 32 Ko, lire les 2 Ko d'un fichier émettait une requête de
    /// 32 Ko ; le cache de Windows n'en lit qu'une page.
    @Test("Lire 2 Ko ne coûte pas un cluster de 32 Ko, et jamais plus d'une page de trop")
    func readGranularity() throws {
        let partition = try Self.partition("dev-1996")
        #expect(partition.clusterBytes == 32 * 1_024)
        #expect(PartitionGeometry.readSectors(forBytes: 2_048, granularity: 4_096) == 8)
        // MS-DOS lit les secteurs demandés.
        #expect(PartitionGeometry.readSectors(forBytes: 2_048, granularity: 512) == 4)
        for bytes in stride(from: 1, through: 200_000, by: 997) {
            let read = PartitionGeometry.readSectors(forBytes: bytes, granularity: 4_096)
                * DriveGeometry.bytesPerSector
            #expect(read >= bytes && read - bytes < 4_096, "\(bytes) octets → \(read)")
        }
        #expect(BootScript.Era.all.first!.readGranularity == DriveGeometry.bytesPerSector)
        #expect(BootScript.Era.all.dropFirst().allSatisfy { $0.readGranularity == 4_096 })
    }

    // MARK: - Le journal

    /// NTFS journalise en écriture anticipée : toute validation y écrit. Mais
    /// le *lazy writer* remplit une page de plusieurs validations avant de
    /// l'écrire — N validations ne font pas N écritures de `$LogFile`.
    @Test("Une validation NTFS écrit dans le journal, et le journal est groupé")
    func journalIsGrouped() throws {
        let partition = try Self.partition("dev-2003")
        let log = partition.logFileLBA..<(partition.logFileLBA
                                          + Int(partition.ntfsLayout.logFile.length) * partition.clusterSectors)
        let sink = OperationSink()
        let validations = 100
        for index in 0..<validations {
            DefragOperations.commit(extents: [Extent(start: UInt32(1_000_000 + index * 64), length: 1)],
                                    fileIndex: 40 + index, phase: 1,
                                    partition: partition, into: sink)
        }
        DefragOperations.final(partition: partition, phase: 2, into: sink)

        let logWrites = sink.operations.filter { $0.isWrite && log.contains($0.lba) }
        let pages = (validations + PartitionGeometry.validationsPerLogPage - 1)
            / PartitionGeometry.validationsPerLogPage
        #expect(logWrites.count == pages, "\(logWrites.count) écritures de journal pour \(validations) validations")
        #expect(logWrites.count < validations / 4)
        // Le journal avance : deux pages successives ne sont pas au même endroit.
        #expect(Set(logWrites.map(\.lba)).count == logWrites.count)
        // Et FAT n'a pas de journal : trois écritures par validation, toujours.
        let fat = try Self.partition("dev-1996")
        #expect(fat.commitAccesses(for: [Extent(start: 100, length: 1)], fileIndex: 3, validation: 7).count == 3)
    }

    /// Un cache qui vide ses tables à son rythme — installation, journée —
    /// écrit une page de journal par vidage, avant les tables qu'elle décrit.
    @Test("Monter un NTFS le déclare en service dans son journal")
    func mountWritesTheRestartArea() throws {
        let partition = try Self.partition("gamer-2007")
        #expect(partition.mountWrite.lba == partition.logFileLBA)
        #expect(partition.mountAccesses.contains { $0.lba == partition.logFileLBA })
        let fat = try Self.partition("gamer-1999")
        #expect(fat.mountWrite.lba == fat.fat1LBA)
    }
}
