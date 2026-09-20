import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Les caches du système au démarrage : `SMARTDRV` sous MS-DOS, VCACHE sous
/// Windows 98. Chiffrés en requêtes et en pages relues, pas en durées : un
/// recalage de `ThinkModel` absorberait un cache faux sans que rien ne le dise.
@Suite("Caches du système")
struct SoftwareCacheTests {

    // MARK: - La file

    @Test("La page la moins récemment servie cède la place, les données poussent")
    func leastRecentlyUsedGivesWay() {
        var cache = PageLRU(capacity: 4)
        for page in 0..<4 { cache.touch(page) }
        let present = cache.touch(0)          // servie : la plus récente
        #expect(present)
        cache.touch(4)                        // chasse la 1, la plus ancienne
        #expect(!cache.contains(1))
        #expect(cache.contains(0))
        cache.fill(anonymous: 3)              // trois pages de données
        #expect(!cache.contains(2) && !cache.contains(3) && !cache.contains(0))
        #expect(cache.contains(4))
        cache.fill(anonymous: 10)             // plus que la taille : tout part
        #expect(!cache.contains(4))
    }

    @Test("Un cache sans taille ne cède jamais")
    func unboundedNeverEvicts() {
        var cache = PageLRU(capacity: .max)
        cache.touch(7)
        cache.fill(anonymous: 1_000_000)
        #expect(cache.contains(7))
    }

    // MARK: - SMARTDRV

    /// Une fois `SMARTDRV` chargé, le disque ne voit plus que des éléments de
    /// 8 Ko ; avant, les lectures de MS-DOS au secteur. Et une partie de ce qui
    /// est lu ne va plus au disque du tout.
    @Test("SMARTDRV lit par éléments de 8 Ko, et en sert une partie")
    func smartDriveReadsByElements() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("gamer-1993"))
        let plan = BootPlanner.plan(disk: disk)
        let reads = plan.requests.filter { !$0.isWrite }
        let before = reads.filter { $0.phaseIndex < 4 }
        let after = reads.filter { $0.phaseIndex >= 4 }
        #expect(!before.isEmpty && !after.isEmpty)
        #expect(after.allSatisfy { $0.lba % SmartDrive.elementSectors == 0
                                   && $0.sectorCount % SmartDrive.elementSectors == 0 })
        #expect(before.contains { $0.sectorCount % SmartDrive.elementSectors != 0 })
        let report = try #require(plan.softwareCache)
        #expect(report.hasPrefix("SMARTDRV"))
        let served = Int(report.split(separator: " ")[2]) ?? 0
        #expect(served > 0, "\(report)")
    }

    // MARK: - VCACHE

    /// Sur FAT32, les pages de table lues au début du démarrage sont chassées
    /// par les données qui suivent, et relues quand une chaîne y repasse : le
    /// va-et-vient d'un Windows 98 qui lit cent mégaoctets.
    /// Une lecture de zéro secteur ne va pas au disque. Aucun appelant n'en
    /// fait ; sans la garde, elle faisait planter `SMARTDRV` sur une plage à
    /// l'envers.
    @Test("SMARTDRV ne demande rien pour une lecture vide")
    func smartDriveIgnoresAnEmptyRead() {
        var cache = SmartDrive(loadedFromAct: 0, windowsFromAct: 5)
        #expect(cache.read(lba: 1_000, sectors: 0, act: 1).isEmpty)
        #expect(cache.hits == 0 && cache.misses == 0)
    }

    @Test("VCACHE rend à la table FAT32 ses retours périodiques")
    func vcacheBringsTheTableBack() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("secretaire-1999"))
        let plan = BootPlanner.plan(disk: disk)
        let partition = plan.partition
        let table = partition.fat1LBA..<(partition.fat1LBA + partition.fatSectors)
        let tableReads = plan.requests.filter { !$0.isWrite && table.contains($0.lba) }
        var seen: Set<Int> = []
        let rereads = tableReads.filter { !seen.insert($0.lba).inserted }.count
        #expect(rereads > 0, "\(tableReads.count) lectures de table, aucune relue")
        let report = try #require(plan.softwareCache)
        #expect(report.contains("relues après éviction"))
        print("  secretaire-1999 : \(report)")
    }

    /// Sous NT, pas de VCACHE : le cache garde tout le démarrage.
    @Test("NTFS n'a ni SMARTDRV ni VCACHE")
    func ntfsHasNeither() throws {
        #expect(VCache.pages(os: "winxp-sp1") == nil)
        #expect(VCache.pages(os: "win98se") == 16 * 1_048_576 / VCache.pageBytes)
        #expect(VCache.pages(os: "win95-osr1") == 4 * 1_048_576 / VCache.pageBytes)
    }
}
