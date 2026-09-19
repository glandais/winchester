import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un volume dont on choisit le placement au cluster près. Le fichier
/// d'échange est le seul immobile.
private func volume(_ format: VolumeFormat, clusterCount: Int,
                    files: [(category: ClusterCategory, extents: [Extent])],
                    mftZone: Range<UInt32>? = nil) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: format)
    let records = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\F\(position).DAT", category: file.category,
                   walkOrder: position, extents: file.extents, isMovable: file.category != .swap)
    }
    return DefragVolume(partition: partition, files: records, mftZone: mftZone)
}

/// La stratégie, munie de l'ordre de lecture d'un démarrage.
private func smart(reading ids: [UInt32]) -> SmartDefragStrategy {
    SmartDefragStrategy().informed(by: BootLayout(files: ids))
}

@Suite("Rangement intelligent")
struct SmartDefragStrategyTests {

    /// Cinq fichiers entrelacés ; le démarrage lit le quatrième, le deuxième
    /// puis le cinquième. Ils finissent en tête, dans cet ordre, et bout à
    /// bout.
    @Test("Ce que lit le démarrage est posé en tête, dans l'ordre où il le lit")
    func theBootBlockFollowsTheReadingOrder() {
        // 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
        // A B C D E A B C D E .  .  .  .  .  .
        let files: [(category: ClusterCategory, extents: [Extent])] = (0..<5).map { index in
            (.system, [Extent(start: UInt32(index), length: 1), Extent(start: UInt32(5 + index), length: 1)])
        }
        let plan = smart(reading: [3, 1, 4]).plan(volume: volume(.fat16, clusterCount: 16, files: files))
        let places = Dictionary(uniqueKeysWithValues: plan.arrangement.map { ($0.id, $0.extents) })

        #expect(places[3] == [Extent(start: 0, length: 2)])
        #expect(places[1] == [Extent(start: 2, length: 2)])
        #expect(places[4] == [Extent(start: 4, length: 2)])
        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.after.freeHoles == 1)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Le fichier d'échange est en morceaux à la fin du volume, et tout
    /// l'espace libre tomberait entre eux. Les fenêtres de queue sont remplies
    /// d'abord : il n'en reste qu'un trou, devant elles.
    @Test("Les fenêtres entre les morceaux du fichier d'échange sont remplies")
    func theTailWindowsAreFilled() {
        var files: [(category: ClusterCategory, extents: [Extent])] = [
            (.swap, [Extent(start: 60, length: 4), Extent(start: 70, length: 4), Extent(start: 80, length: 4)]),
        ]
        // Vingt fichiers de deux clusters, épars sous le fichier d'échange.
        for index in 0..<20 {
            files.append((.document, [Extent(start: UInt32(index) * 3, length: 2)]))
        }
        let before = volume(.fat16, clusterCount: 90, files: files)
        let frontier = FrontierCompactionStrategy().plan(volume: before)
        let plan = smart(reading: []).plan(volume: before)

        #expect(frontier.after.freeHoles > 1)
        #expect(plan.after.freeHoles == 1)
        #expect(plan.after.fragmentedFiles == 1, "seul le fichier d'échange reste en morceaux")
        #expect(plan.before.fill == plan.after.fill)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Une zone MFT que les fichiers occupent aux trois quarts ne réserve plus
    /// rien : la passe la tasse. Une zone vide est respectée.
    @Test("La zone MFT n'est respectée que tant qu'elle réserve quelque chose")
    func aSpentMFTZoneIsCompacted() {
        var files: [(category: ClusterCategory, extents: [Extent])] = [(.system, [Extent(start: 0, length: 10)])]
        for index in 0..<30 {
            files.append((.document, [Extent(start: 10 + UInt32(index) * 4, length: 3)]))
        }
        let spent = volume(.ntfs, clusterCount: 300, files: files, mftZone: 10..<130)
        #expect(SmartDefragStrategy.withoutSpentZone(spent).mftZone == nil)
        let plan = smart(reading: []).plan(volume: spent)
        #expect(plan.after.freeHoles == 1)

        let reserved = volume(.ntfs, clusterCount: 300, files: [
            (.system, [Extent(start: 0, length: 10)]),
            (.document, [Extent(start: 200, length: 5), Extent(start: 250, length: 5)]),
        ], mftZone: 10..<130)
        #expect(SmartDefragStrategy.withoutSpentZone(reserved).mftZone == 10..<130)
        let kept = smart(reading: [1]).plan(volume: reserved)
        for mutation in kept.mutations where mutation.category != .free {
            #expect(!(mutation.start < 130 && mutation.start + mutation.count > 10), "écrit dans la zone MFT")
        }
        #expect(kept.after.fragmentedFiles == 0)
    }

    /// Le volume vieilli des autres tests, avec un démarrage qui lit un
    /// fichier sur dix.
    @Test("Une passe complète range tout, sans écrire sur une donnée encore référencée")
    func aFullPassPacksTheVolume() {
        let partition = PartitionGeometry(startLBA: 0, sectors: 180_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        let aged = VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
        let reading = aged.files.filter(\.isMovable).map(\.id).enumerated()
            .filter { $0.offset % 10 == 0 }.map(\.element).reversed()
        let plan = smart(reading: Array(reading)).plan(volume: aged)

        #expect(plan.before.fill == plan.after.fill, "des clusters se sont perdus ou dupliqués")
        #expect(plan.before.fileCount == plan.after.fileCount)
        let swap = aged.files.filter { !$0.isMovable && !$0.isContiguous }.count
        #expect(plan.after.fragmentedFiles == swap)
        expectWritesOnlyOnReleasedClusters(plan)
    }
}

@Suite("Layout.ini")
struct BootLayoutTests {

    /// Le démarrage de `dev-1996` lit ses fichiers et, sur FAT, les
    /// répertoires qui les mènent : chacun une fois, dans l'ordre de la
    /// première lecture.
    @Test("L'ordre de lecture nomme chaque élément une fois, répertoires compris")
    func theReadingOrderNamesEachItemOnce() throws {
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "dev-1996" })
        let disk = try DiskGenerator.generate(spec)
        let layout = BootLayout(disk: disk)

        #expect(Set(layout.files).count == layout.files.count)
        #expect(layout.files.contains { FileCatalog.directory(ofItem: $0) != nil })
        let files = layout.files.filter { FileCatalog.directory(ofItem: $0) == nil }
        #expect(files.count <= BootPlanner.plan(disk: disk).filesRead)
        #expect(files.count > 100)
    }
}
