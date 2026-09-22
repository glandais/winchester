import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Les répertoires vus d'en haut : ce que la défragmentation, la validation
/// d'un déplacement et le démarrage font d'objets qui ont enfin une place.
@Suite("Répertoires à leur place")
struct DirectoryItemsTests {

    /// `CalculateZones` range les répertoires en zone 0, les gros fichiers en
    /// zone 2, le reste en zone 1. Sans répertoires, la zone 0 ne contenait
    /// que la réserve d'espace libre : le découpage en trois bandes qui fait la
    /// signature de JkDefrag en était un en deux.
    @Test("JkDefrag range les répertoires dans la zone 0")
    func directoriesFillZoneZero() {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 1_000, clusterSectors: 8, format: .fat16)
        let files = [
            DefragFile(id: FileCatalog.itemID(ofDirectory: 1), path: "\\DOSSIER", category: .directory,
                       walkOrder: 0, extents: [Extent(start: 500, length: 30)], isMovable: true),
            DefragFile(id: 0, path: "\\DOSSIER\\A.DAT", category: .application,
                       walkOrder: 1, extents: [Extent(start: 200, length: 100)], isMovable: true),
        ]
        var strategy = JKDefragStrategy()
        strategy.freeSpacePercent = 0
        let report = strategy.run(volume: DefragVolume(partition: partition, files: files)).report
        #expect(report.zones.regular == 30)
        #expect(report.zones.spaceHogs == 130)
    }

    /// Trente répertoires en deux morceaux chacun, et un fichier ordinaire.
    private static func brokenDirectories(format: VolumeFormat) -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 1_000, clusterSectors: 8, format: format)
        var files = (0..<30).map { index in
            let start = UInt32(100 + index * 4)
            return DefragFile(id: FileCatalog.itemID(ofDirectory: UInt32(index + 1)),
                              path: "\\D\(index)", category: .directory, walkOrder: index,
                              extents: [Extent(start: start, length: 1), Extent(start: start + 2, length: 1)],
                              isMovable: true)
        }
        files.append(DefragFile(id: 0, path: "\\D0\\A.DAT", category: .document, walkOrder: 30,
                                extents: [Extent(start: 600, length: 10), Extent(start: 700, length: 10)],
                                isMovable: true))
        return DefragVolume(partition: partition, files: files)
    }

    /// `MoveItem` (`JkDefragLib.cpp:2482-2545`) : Windows ne sait pas déplacer
    /// le premier cluster d'un répertoire FAT, JkDefrag essaie quand même, et
    /// compte. Chaque échec déclare le répertoire immobile et recalcule les
    /// zones ; au-delà de vingt — `CannotMoveDirs > 20`, donc au vingt et
    /// unième —, les répertoires suivants ne sont plus essayés.
    @Test("JkDefrag sur FAT abandonne ses répertoires après vingt et un échecs")
    func jkDefragGivesUpFATDirectories() throws {
        let volume = Self.brokenDirectories(format: .fat16)
        let (plan, report) = JKDefragStrategy().run(volume: volume)
        #expect(report.directoryFailures == 21)
        #expect(report.zoneRecalculations == 21)
        #expect(report.failedMoves == 21)
        #expect(report.directoriesGivenUp == 9)
        // Aucun répertoire n'a bougé ; le fichier ordinaire, si.
        for file in volume.files where file.category == .directory {
            #expect(plan.arrangement.first { $0.id == file.id }?.extents == file.extents)
        }
        let document = try #require(plan.arrangement.first { $0.id == 0 })
        #expect(document.extents.count == 1)
    }

    /// Sur NTFS, rien de tel : un répertoire est un index qui se déplace.
    @Test("JkDefrag sur NTFS déplace ses répertoires")
    func jkDefragMovesNTFSDirectories() {
        let volume = Self.brokenDirectories(format: .ntfs)
        let (plan, report) = JKDefragStrategy().run(volume: volume)
        #expect(report.directoryFailures == 0)
        #expect(report.directoriesGivenUp == 0)
        #expect(plan.after.fragmentedFiles == 0)
    }

    /// UltraDefrag les saute d'emblée (`can_defragment`, `defrag.c:139`), et la
    /// passe de XP, qui déplace les fichiers entiers, échoue sur chacun.
    @Test("UltraDefrag et XP laissent les répertoires FAT en place", arguments: ["ultraDefrag", "windowsXP"])
    func apiToolsLeaveFATDirectories(strategyID: String) throws {
        let volume = Self.brokenDirectories(format: .fat16)
        let plan = try #require(DefragPlanner.strategy(named: strategyID)).plan(volume: volume)
        #expect(plan.after.fragmentedFiles == 30)
        #expect(plan.filesMoved == 1)
    }

    /// Le pont adopte chaque répertoire qui a des clusters, avant ce qu'il
    /// contient, sous un identifiant qui ne peut pas être celui d'un fichier.
    @Test("Le volume à défragmenter porte les répertoires du disque généré")
    func bridgeCarriesDirectories() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("secretaire-1999"))
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let directories = volume.files.filter { $0.category == .directory }
        let placed = disk.catalog.directories.filter { !$0.extents.isEmpty }
        #expect(directories.count == placed.count)
        #expect(directories.allSatisfy { FileCatalog.directory(ofItem: $0.id) != nil })
        #expect(Set(volume.files.map(\.id)).count == volume.files.count)
        // Chaque répertoire vient avant ses fichiers.
        for (position, file) in volume.files.enumerated() {
            guard let parent = file.entry?.directory else { continue }
            #expect(parent < position)
            #expect(volume.files[parent].category == .directory)
        }
    }

    /// Valider le déplacement d'un fichier réécrit son entrée **là où est son
    /// répertoire**, et non plus dans la racine. Sur FAT32, où seules les deux
    /// copies de la table sont au début du volume, le bras cesse d'y revenir
    /// pour l'entrée.
    @Test("Sur FAT, la validation écrit l'entrée dans le répertoire du fichier")
    func commitWritesTheEntryWhereTheDirectoryIs() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("secretaire-1999"))
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let partition = volume.partition
        var checked = 0
        for (position, file) in volume.files.enumerated() where file.category != .directory {
            guard let parent = file.entry?.directory, checked < 200 else { continue }
            let sector = try #require(volume.entrySector(of: position))
            let inside = volume.files[parent].extents.contains { extent in
                let first = partition.lba(ofCluster: Int(extent.start))
                return (first..<(first + Int(extent.length) * partition.clusterSectors)).contains(sector)
            }
            #expect(inside)
            let accesses = partition.commitAccesses(for: file.extents, fileIndex: position,
                                                    entrySector: sector, validation: 0)
            #expect(accesses.last?.lba == sector)
            #expect(sector != partition.rootLBA)
            checked += 1
        }
        #expect(checked > 100)
    }

    /// Ouvrir un fichier au démarrage, c'est d'abord lire son chemin : les
    /// répertoires sont lus là où l'allocateur les a posés, et un répertoire
    /// en plusieurs morceaux se lit en plusieurs requêtes.
    @Test("Le démarrage lit les répertoires là où ils sont")
    func bootReadsDirectoriesInPlace() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("secretaire-1999"))
        let partition = GeneratedVolumeBridge.partition(of: disk)
        var directorySectors = IndexSet()
        for directory in disk.catalog.directories {
            for extent in directory.extents {
                let first = partition.lba(ofCluster: Int(extent.start))
                directorySectors.insert(integersIn: first..<(first + Int(extent.length) * partition.clusterSectors))
            }
        }
        let plan = BootPlanner.plan(disk: disk)
        let reads = plan.requests.filter { !$0.isWrite && directorySectors.contains($0.lba) }
        print("secretaire-1999 — \(reads.count) lectures de répertoire sur \(plan.requests.count) requêtes")
        #expect(reads.count > 10)
    }
}
