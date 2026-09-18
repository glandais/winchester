import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un volume NTFS de clusters de 4 Ko, dont on choisit le placement au cluster
/// près : 1 024 clusters font les 4 Mo d'un « petit » morceau.
private func ntfsVolume(clusterCount: Int,
                        files: [(category: ClusterCategory, extents: [Extent])],
                        mftZone: Range<UInt32>? = nil) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: .ntfs)
    let records = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\F\(position).DAT", category: file.category,
                   walkOrder: position, extents: file.extents, isMovable: file.category != .swap)
    }
    return DefragVolume(partition: partition, files: records, mftZone: mftZone)
}

/// Les opérations de lecture ou d'écriture de données qui touchent `extent`.
private func dataAccesses(_ plan: DefragPlan, touching extent: Extent) -> Int {
    let start = plan.partition.lba(ofCluster: Int(extent.start))
    let end = plan.partition.lba(ofCluster: Int(extent.end))
    return plan.operations.filter {
        ($0.kind == .readExtent || $0.kind == .writeExtent) && $0.lba < end && $0.lba + $0.sectors > start
    }.count
}

@Suite("Recollage économe")
struct FragmentMergeStrategyTests {

    /// Un volume vieilli à la main : des fichiers en morceaux entrelacés avec
    /// de petits fichiers, un gros fichier en trois gros morceaux, un fichier
    /// d'échange, une zone MFT libre, et l'espace libre éparpillé.
    private static func agedVolume() -> DefragVolume {
        var files: [(category: ClusterCategory, extents: [Extent])] = []
        var fragments = [[Extent]](repeating: [], count: 12)
        var big: [Extent] = []
        var cursor: UInt32 = 10_000
        for round in 0..<30 {
            if round % 10 == 0 {
                big.append(Extent(start: cursor, length: 1_500))
                cursor += 1_500
            }
            for file in 0..<12 {
                let length = UInt32(3 + (round * 7 + file * 5) % 10)
                fragments[file].append(Extent(start: cursor, length: length))
                cursor += length
                if (round + file) % 4 == 0 {
                    files.append((.document, [Extent(start: cursor, length: 4)]))
                    cursor += 4
                }
                if (round * 3 + file) % 7 == 0 { cursor += UInt32(1 + (round + file) % 5) }
            }
        }
        for extents in fragments { files.append((.archive, extents)) }
        files.append((.application, big))
        files.append((.swap, [Extent(start: 30_000, length: 2_000)]))
        return ntfsVolume(clusterCount: 60_000, files: files, mftZone: 1_000..<9_000)
    }

    @Test("Une passe complète recolle et consolide, sans écrire sur une donnée encore référencée")
    func aFullPass() {
        let volume = Self.agedVolume()
        let (plan, report) = FragmentMergeStrategy().run(volume: volume)

        #expect(plan.before.fill == plan.after.fill, "des clusters se sont perdus ou dupliqués")
        #expect(plan.before.fileCount == plan.after.fileCount)
        #expect(plan.after.fragments * 4 < plan.before.fragments)
        #expect(plan.after.freeHoles < plan.before.freeHoles)
        #expect(report.rounds < FragmentMergeStrategy().maximumRounds)

        // La copie du secteur d'amorçage suit le dernier cluster.
        let end = plan.partition.startLBA + plan.partition.totalSectors
        for operation in plan.operations {
            #expect(operation.lba + operation.sectors <= end, "opération hors de la partition")
        }
        #expect(dataAccesses(plan, touching: Extent(start: 30_000, length: 2_000)) == 0,
                "le fichier d'échange a été touché")
        for mutation in plan.mutations where mutation.category != .free {
            #expect(!(mutation.start < 9_000 && mutation.start + mutation.count > 1_000),
                    "une écriture tombe dans la zone MFT")
        }
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Deux petits morceaux entre deux gros : ils rejoignent le premier, dans
    /// le trou qui le suit, et aucun des gros n'est lu ni écrit.
    @Test("Les petits morceaux rejoignent un gros morceau, qui ne bouge pas")
    func smallPiecesJoinALargeOne() {
        let first = Extent(start: 100, length: 1_200)
        let last = Extent(start: 2_000, length: 1_200)
        let volume = ntfsVolume(clusterCount: 8_000, files: [
            (.archive, [first, Extent(start: 5_000, length: 10), Extent(start: 5_100, length: 10), last]),
            (.document, [Extent(start: 1_320, length: 80)]),
            (.document, [Extent(start: 1_400, length: 600)]),
            (.document, [Extent(start: 3_200, length: 1_800)]),
            (.document, [Extent(start: 5_010, length: 90)]),
        ])
        let (plan, report) = FragmentMergeStrategy().run(volume: volume)

        #expect(report.runsBesideNeighbour == 1)
        #expect(plan.after.fragments == 2)
        #expect(dataAccesses(plan, touching: first) == 0)
        #expect(dataAccesses(plan, touching: last) == 0)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// La zone MFT est le seul grand trou du volume : les morceaux restent
    /// où ils sont plutôt que d'y entrer.
    @Test("La zone MFT n'est jamais une destination")
    func theMftZoneIsNeverUsed() {
        var files: [(category: ClusterCategory, extents: [Extent])] = [
            (.system, [Extent(start: 0, length: 100)]),
            (.system, [Extent(start: 2_100, length: 100)]),
        ]
        let pieces = (0..<6).map { Extent(start: 2_200 + UInt32($0) * 20, length: 10) }
        let others = (0..<6).map { Extent(start: 2_210 + UInt32($0) * 20, length: 10) }
        files.append((.archive, pieces))
        files.append((.document, others))
        files.append((.document, [Extent(start: 2_320, length: 1_180)]))
        files.append((.document, [Extent(start: 3_505, length: 495)]))
        let volume = ntfsVolume(clusterCount: 4_000, files: files, mftZone: 100..<2_100)
        let (plan, _) = FragmentMergeStrategy().run(volume: volume)

        for mutation in plan.mutations where mutation.category != .free {
            #expect(!(mutation.start < 2_100 && mutation.start + mutation.count > 100),
                    "une écriture tombe dans la zone MFT")
        }
        #expect(plan.after.fragments == plan.before.fragments)
    }

    /// Un petit fichier entre deux trous part dans un trou à sa taille : les
    /// deux trous qu'il séparait n'en font plus qu'un.
    @Test("Un petit fichier entre deux trous est déplacé, et les trous réunis")
    func aFileBetweenTwoHolesMoves() {
        let volume = ntfsVolume(clusterCount: 1_000, files: [
            (.system, [Extent(start: 0, length: 100)]),
            (.document, [Extent(start: 110, length: 10)]),
            (.application, [Extent(start: 130, length: 370)]),
            (.application, [Extent(start: 510, length: 480)]),
        ])
        let (plan, report) = FragmentMergeStrategy().run(volume: volume)

        #expect(report.consolidations >= 1)
        #expect(plan.after.freeHoles < plan.before.freeHoles)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Trois morceaux de deux clusters vers une destination d'un seul tenant,
    /// par blocs de quatre : deux lectures, une écriture, puis la dernière
    /// lecture et la dernière écriture.
    @Test("Un bloc plein se lit morceau par morceau et s'écrit une fois")
    func gatheredMoveReadsThenWrites() {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 100, clusterSectors: 8, format: .ntfs)
        let sink = OperationSink()
        DefragOperations.gatheredMove(source: [Extent(start: 0, length: 2), Extent(start: 10, length: 2),
                                               Extent(start: 20, length: 2)],
                                      destination: [Extent(start: 50, length: 6)],
                                      category: .document, contiguous: true, phase: 1,
                                      partition: partition, bufferBytes: 4 * partition.clusterBytes,
                                      into: sink)
        let steps = sink.operations.map { ($0.kind == .writeExtent ? "W" : "R") + "\($0.cluster ?? -1)" }
        #expect(steps == ["R0", "R10", "W50", "R20", "W54"])

        let freed = sink.mutations.filter { $0.category == .free }.map(\.start)
        #expect(freed == [0, 10, 20])
    }

    @Test("Le recollage économe ne se choisit pas tout seul")
    func itIsNeverThePeriodTool() {
        #expect(DefragPlanner.strategy(for: .ntfs).id == "windowsXP")
        #expect(DefragPlanner.strategy(named: "fragmentMerge")?.label == "Recollage économe")
    }
}

@Suite("Blocs pleins sur les autres outils")
struct FullBlocksOptionTests {

    /// Un fichier en huit morceaux de deux clusters, entrelacés avec de petits
    /// fichiers, et un trou où il tient : les mêmes lectures, mais une seule
    /// écriture.
    @Test("L'option regroupe les écritures sans changer le résultat",
          arguments: ["windowsXP", "ultraDefrag", "jkDefrag"])
    func sameResultFewerWrites(strategyID: String) throws {
        let pieces = (0..<8).map { Extent(start: 100 + UInt32($0) * 4, length: 2) }
        var files: [(category: ClusterCategory, extents: [Extent])] = [
            (.system, [Extent(start: 0, length: 100)]),
            (.archive, pieces),
            (.application, [Extent(start: 132, length: 500)]),
        ]
        for index in 0..<8 {
            files.append((.document, [Extent(start: 102 + UInt32(index) * 4, length: 2)]))
        }
        let volume = ntfsVolume(clusterCount: 1_000, files: files)
        let strategy = try #require(DefragPlanner.strategy(named: strategyID))
        let full = try #require(DefragPlanner.withFullBlocks(strategy))

        let cut = DefragPlanner.plan(volume: volume, using: strategy)
        let gathered = DefragPlanner.plan(volume: volume, using: full)
        func count(_ plan: DefragPlan, _ kind: DiskOperation.Kind) -> Int {
            plan.operations.filter { $0.kind == kind }.count
        }

        #expect(gathered.after.fragments == cut.after.fragments)
        #expect(gathered.after.freeHoles == cut.after.freeHoles)
        #expect(count(gathered, .readExtent) == count(cut, .readExtent))
        #expect(count(gathered, .writeExtent) < count(cut, .writeExtent))
        // JkDefrag range aussi le reste du volume ; les deux autres ne
        // déplacent que le fichier cassé.
        if strategyID != "jkDefrag" {
            #expect(count(cut, .writeExtent) >= 8)
            #expect(count(gathered, .writeExtent) == 1)
        }
    }

    @Test("Seuls XP, UltraDefrag et JkDefrag ont l'option, et elle est éteinte par défaut")
    func whoHasTheOption() {
        #expect(!WindowsXPStrategy().fullBlocks)
        #expect(!UltraDefragStrategy().fullBlocks)
        #expect(!JKDefragStrategy().fullBlocks)
        for strategy in DefragPlanner.all {
            let supported = strategy is WindowsXPStrategy || strategy is UltraDefragStrategy
                || strategy is JKDefragStrategy
            #expect((DefragPlanner.withFullBlocks(strategy) != nil) == supported, "\(strategy.id)")
        }
    }
}
