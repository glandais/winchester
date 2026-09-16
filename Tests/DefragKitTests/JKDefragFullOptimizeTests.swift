import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un volume dont on choisit le placement, les tailles et les dates.
private struct SortFile {
    let name: String
    let extents: [Extent]
    var bytes: UInt64? = nil
    var created: UInt32 = 0
    var modified: UInt32 = 0
    var category: ClusterCategory = .document
}

private func volume(clusterCount: Int, files: [SortFile], format: VolumeFormat = .fat16,
                    mftZone: Range<UInt32>? = nil, systemExtents: [Extent] = []) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: format)
    let records = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\\(file.name)", category: file.category,
                   walkOrder: position, extents: file.extents, isMovable: file.category != .swap,
                   bytes: file.bytes, createdDay: file.created, modifiedDay: file.modified)
    }
    return DefragVolume(partition: partition, files: records, mftZone: mftZone,
                        systemExtents: systemExtents)
}

/// Sans réserve d'espace libre, les zones se réduisent à ce qu'elles
/// contiennent.
private func run(_ volume: DefragVolume, _ mode: JKDefragStrategy.Mode)
    -> (plan: DefragPlan, report: JKDefragStrategy.Report, after: DefragVolume) {
    var strategy = JKDefragStrategy(mode: mode)
    strategy.freeSpacePercent = 0
    let (plan, report) = strategy.run(volume: volume)
    // Le volume d'arrivée, reconstruit depuis la carte : chaque cluster
    // rendu à son propriétaire par le rejeu des mutations.
    return (plan, report, replay(plan, on: volume))
}

/// Rejoue les mutations d'une passe, en vérifiant au passage qu'aucune
/// écriture ne tombe sur un cluster occupé.
private func replay(_ plan: DefragPlan, on volume: DefragVolume) -> DefragVolume {
    var occupied = [Bool](repeating: false, count: plan.partition.clusterCount)
    for run in plan.initialRuns {
        for cluster in Int(run.start)..<Int(run.end) { occupied[cluster] = true }
    }
    for operation in plan.operations where operation.mutationCount > 0 {
        let slice = plan.mutations[Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount)]
        for mutation in slice where mutation.category != .free {
            for cluster in mutation.start..<(mutation.start + mutation.count) {
                #expect(!occupied[cluster], "écriture sur le cluster occupé \(cluster)")
                occupied[cluster] = true
            }
        }
        for mutation in slice where mutation.category == .free {
            for cluster in mutation.start..<(mutation.start + mutation.count) { occupied[cluster] = false }
        }
    }
    let used = occupied.filter { $0 }.count
    #expect(used == plan.initialRuns.reduce(0) { $0 + Int($1.count) }, "des clusters se sont perdus")
    return volume
}

/// L'état final d'une passe : où commence chaque fichier, et en combien de
/// morceaux. Il se relit sur la stratégie, qui rejoue chaque déplacement.
private func finalFiles(_ volume: DefragVolume, _ mode: JKDefragStrategy.Mode) -> [DefragFile] {
    var strategy = JKDefragStrategy(mode: mode)
    strategy.freeSpacePercent = 0
    var pass = JKDefragStrategy.Pass(strategy: strategy, volume: volume, sink: OperationSink())
    switch mode {
    case .fastOptimize: break
    case .forcedFill: pass.report.moves = [0]; pass.forcedFill(phase: 1)
    case .moveUp: pass.report.moves = [0]; pass.optimizeUp(phase: 1)
    case .sort(let field): pass.report.moves = [0, 0]; pass.optimizeSort(field: field, phases: [1, 1, 2])
    }
    return pass.volume.files
}

@Suite("Passes JkDefrag complètes")
struct JKDefragFullOptimizeTests {

    /// Six fichiers en désordre, dont deux cassés, avec des trous entre eux.
    private static let shuffled: [SortFile] = [
        SortFile(name: "E.DAT", extents: [Extent(start: 3, length: 6)], bytes: 6_000, created: 5, modified: 9),
        SortFile(name: "b.dat", extents: [Extent(start: 12, length: 3), Extent(start: 60, length: 3)],
                 bytes: 50_000, created: 2, modified: 2),
        SortFile(name: "A.DAT", extents: [Extent(start: 20, length: 10)], bytes: 90_000, created: 9, modified: 4),
        SortFile(name: "D.DAT", extents: [Extent(start: 33, length: 4)], bytes: 1_000, created: 1, modified: 7),
        SortFile(name: "c.dat", extents: [Extent(start: 40, length: 8), Extent(start: 50, length: 8)],
                 bytes: 70_000, created: 3, modified: 1),
        SortFile(name: "F.DAT", extents: [Extent(start: 70, length: 5)], bytes: 3_000, created: 4, modified: 3),
    ]

    private static func startOrder(_ files: [DefragFile]) -> [String] {
        files.sorted { $0.extents[0].start < $1.extents[0].start }.map { String($0.path.dropFirst()) }
    }

    /// `_wcsicmp` ignore la casse : « b.dat » vient entre « A.DAT » et
    /// « c.dat », pas après « F.DAT » comme le voudrait l'ASCII.
    @Test("Le tri par nom range les fichiers dans l'ordre alphabétique, sans casse")
    func sortByName() {
        let input = volume(clusterCount: 200, files: Self.shuffled)
        let (plan, report, _) = run(input, .sort(.name))
        let files = finalFiles(input, .sort(.name))

        #expect(Self.startOrder(files) == ["A.DAT", "b.dat", "c.dat", "D.DAT", "E.DAT", "F.DAT"])
        #expect(files.allSatisfy { $0.isContiguous })
        // Contigus et collés les uns aux autres depuis le début du volume.
        var cursor: UInt32 = 0
        for file in files.sorted(by: { $0.extents[0].start < $1.extents[0].start }) {
            #expect(file.extents[0].start == cursor, "\(file.path) n'est pas collé au précédent")
            cursor = file.extents[0].start + file.clusterCount
        }
        #expect(plan.evacuations > 0, "le tri n'a délogé personne")
        #expect(plan.evacuations == report.evacuations)
    }

    @Test("Les autres critères suivent les tailles et les dates")
    func otherCriteria() {
        let input = volume(clusterCount: 200, files: Self.shuffled)
        #expect(Self.startOrder(finalFiles(input, .sort(.size)))
                == ["D.DAT", "F.DAT", "E.DAT", "b.dat", "c.dat", "A.DAT"])
        #expect(Self.startOrder(finalFiles(input, .sort(.creation)))
                == ["D.DAT", "b.dat", "c.dat", "F.DAT", "E.DAT", "A.DAT"])
        #expect(Self.startOrder(finalFiles(input, .sort(.lastChange)))
                == ["c.dat", "b.dat", "F.DAT", "A.DAT", "D.DAT", "E.DAT"])
        // Le dernier accès, du plus récent au plus ancien : c'est le code de
        // `CompareItems`, pas son commentaire.
        #expect(Self.startOrder(finalFiles(input, .sort(.lastAccess)))
                == ["E.DAT", "D.DAT", "A.DAT", "F.DAT", "b.dat", "c.dat"])
    }

    /// Deux dates égales se départagent par le chemin.
    @Test("À date égale, le chemin départage")
    func tiesFallBackToThePath() {
        let input = volume(clusterCount: 100, files: [
            SortFile(name: "Z.DAT", extents: [Extent(start: 10, length: 4)], created: 1),
            SortFile(name: "M.DAT", extents: [Extent(start: 20, length: 4)], created: 1),
            SortFile(name: "A.DAT", extents: [Extent(start: 30, length: 4)], created: 2),
        ])
        #expect(Self.startOrder(finalFiles(input, .sort(.creation))) == ["M.DAT", "Z.DAT", "A.DAT"])
    }

    /// Un fichier que le trou au curseur ne peut pas recevoir, parce qu'un
    /// fichier immobile coupe la place : il est posé en deux morceaux, arrondis
    /// au multiple de 8 près. Le tri **refragmente**.
    @Test("Un fichier coupé par un immobile est posé en morceaux multiples de 8")
    func sortSplitsAroundUnmovable() {
        let input = volume(clusterCount: 200, files: [
            SortFile(name: "A.DAT", extents: [Extent(start: 100, length: 20)]),
            SortFile(name: "SWAP", extents: [Extent(start: 11, length: 2)], category: .swap),
        ])
        let (_, report, _) = run(input, .sort(.name))
        let file = finalFiles(input, .sort(.name))[0]
        #expect(file.extents.first == Extent(start: 0, length: 8))
        #expect(report.splitPlacements == 1)
        #expect(file.clusterCount == 20)
    }

    /// `ForcedFill` prend le fragment le plus haut et en détache la fin : le
    /// volume finit tassé contre son début, sans trou sous les données.
    @Test("Le comblement forcé tasse tout contre le début du volume")
    func forcedFillPacksTheStart() {
        let input = volume(clusterCount: 200, files: Self.shuffled)
        let (plan, _, _) = run(input, .forcedFill)
        let files = finalFiles(input, .forcedFill)
        let used = files.reduce(0) { $0 + $1.clusterCount }

        var map = [Bool](repeating: false, count: 200)
        for file in files { for extent in file.extents { for c in extent.start..<extent.end { map[Int(c)] = true } } }
        // `ForcedFill` ne pose jamais rien sur le cluster zéro : il part de
        // `HighestLcn = 0` et s'arrête quand le plus haut fragment est sous le
        // trou. Ici le premier trou commence à 0.
        #expect(map[0..<Int(used)].filter { !$0 }.count <= 1)
        #expect(map[Int(used) + 1..<200].allSatisfy { !$0 }, "des données restent au-delà du tassement")
        #expect(plan.evacuations == 0)
    }

    /// `OptimizeUp` remplit chaque trou, du fond vers le début, par les
    /// fichiers pris dessous : le début du volume se vide.
    @Test("Vers la fin du volume, le début se vide")
    func moveUpEmptiesTheStart() {
        let input = volume(clusterCount: 200, files: Self.shuffled)
        let (plan, _, _) = run(input, .moveUp)
        let files = finalFiles(input, .moveUp)
        let lowest = files.map { $0.extents.map(\.start).min()! }.min()!
        let used = files.reduce(0) { $0 + $1.clusterCount }
        #expect(lowest >= 200 - used - 8, "des données restent en bas : \(lowest)")
        #expect(plan.filesMoved > 0)
    }

    /// Le parcours ascendant de `FindHighestItem` avec `Direction = 0` :
    /// entre deux fichiers qui tiennent, c'est **le plus bas** qui monte.
    @Test("Vers la fin du volume, c'est le fichier le plus bas qui part le premier")
    func moveUpTakesTheLowest() {
        let input = volume(clusterCount: 100, files: [
            SortFile(name: "LOW.DAT", extents: [Extent(start: 10, length: 3)]),
            SortFile(name: "HIGH.DAT", extents: [Extent(start: 50, length: 3)]),
            SortFile(name: "TOP.DAT", extents: [Extent(start: 90, length: 10)]),
        ])
        let (plan, _, _) = run(input, .moveUp)
        let firstWrite = plan.mutations.first { $0.category != .free }
        // Le trou le plus haut est 53..<90 : ni LOW ni HIGH ne le remplissent
        // seuls, et ensemble ils ne font que 6. Le plus bas, LOW, monte le
        // premier contre la fin du trou.
        #expect(firstWrite?.start == 87)
        let files = finalFiles(input, .moveUp)
        #expect(files[0].extents[0].start == 87)
        #expect(files[1].extents[0].start == 84)
    }

    /// Ce qu'aucune passe ne doit casser, sur un volume vieilli : pas un
    /// cluster perdu ou dupliqué, pas d'écriture sur un occupant, rien hors de
    /// la partition.
    @Test("Les tassements et les tris conservent le volume",
          arguments: [JKDefragStrategy.Mode.forcedFill, .moveUp, .sort(.name), .sort(.size),
                      .sort(.lastAccess), .sort(.lastChange), .sort(.creation)])
    func fullPassesPreserveTheVolume(mode: JKDefragStrategy.Mode) {
        let partition = PartitionGeometry(startLBA: 0, sectors: 180_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        let input = VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
        let (plan, report) = JKDefragStrategy(mode: mode).run(volume: input)
        _ = replay(plan, on: input)

        #expect(plan.before.fill == plan.after.fill)
        #expect(plan.before.fileCount == plan.after.fileCount)
        #expect(plan.filesMoved > 0)
        #expect(report.perfectFitsExhausted == 0)
        let end = partition.lba(ofCluster: partition.clusterCount)
        for operation in plan.operations {
            #expect(operation.lba + operation.sectors <= end, "opération hors de la partition")
        }
    }

    /// Chaque mode s'obtient par son identifiant, comme le mode par défaut.
    @Test("Chaque mode a son identifiant")
    func everyModeIsReachable() {
        let ids = ["jkDefragForcedFill", "jkDefragMoveUp", "jkDefragSortName", "jkDefragSortSize",
                   "jkDefragSortAccess", "jkDefragSortChange", "jkDefragSortCreation"]
        for id in ids { #expect(DefragPlanner.strategy(named: id) != nil, "\(id) introuvable") }
        #expect(Set(DefragPlanner.all.map(\.id)).count == DefragPlanner.all.count)
    }
}
