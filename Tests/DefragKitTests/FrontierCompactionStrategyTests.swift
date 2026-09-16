import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un volume FAT dont on choisit le placement au cluster près. Le fichier
/// d'échange est le seul immobile.
private func fatVolume(clusterCount: Int, files: [(category: ClusterCategory, extents: [Extent])]) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: .fat16)
    let records = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\F\(position).DAT", category: file.category,
                   walkOrder: position, extents: file.extents, isMovable: file.category != .swap)
    }
    return DefragVolume(partition: partition, files: records)
}

/// Rejoue les opérations d'un plan et vérifie la garantie de la passe : une
/// écriture ne tombe que sur un cluster libre **et validé comme tel**.
///
/// Un cluster que quitte un déplacement n'est libre pour les écritures
/// suivantes qu'une fois les tables réécrites : avant, une coupure de courant
/// laisserait les tables pointer dessus.
private func expectWritesOnlyOnReleasedClusters(_ plan: DefragPlan,
                                                sourceLocation: SourceLocation = #_sourceLocation) {
    let count = plan.partition.clusterCount
    var occupied = [Bool](repeating: false, count: count)
    var released = [Bool](repeating: false, count: count)
    for run in plan.initialRuns {
        for cluster in Int(run.start)..<Int(run.end) { occupied[cluster] = true }
    }
    var awaiting: [Int] = []
    var faults = 0
    for operation in plan.operations {
        switch operation.kind {
        case .writeExtent:
            let slice = plan.mutations[Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount)]
            for mutation in slice where mutation.category != .free {
                for cluster in mutation.start..<(mutation.start + mutation.count) {
                    if occupied[cluster] || released[cluster] { faults += 1 }
                    occupied[cluster] = true
                }
            }
            for mutation in slice where mutation.category == .free {
                for cluster in mutation.start..<(mutation.start + mutation.count) {
                    occupied[cluster] = false
                    released[cluster] = true
                    awaiting.append(cluster)
                }
            }
        case .metadata:
            for cluster in awaiting { released[cluster] = false }
            awaiting.removeAll()
        default:
            break
        }
    }
    #expect(faults == 0, "\(faults) clusters écrits avant que leur libération soit validée",
            sourceLocation: sourceLocation)
}

@Suite("Tassage à la frontière")
struct FrontierCompactionStrategyTests {

    /// Le volume vieilli des autres tests : deux ans d'usage sous Windows 95.
    @Test("Une passe complète range tout, sans écrire sur une donnée encore référencée")
    func aFullPassPacksTheVolume() {
        let partition = PartitionGeometry(startLBA: 0, sectors: 180_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        let volume = VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
        let (plan, report) = FrontierCompactionStrategy().run(volume: volume)

        #expect(plan.before.fill == plan.after.fill, "des clusters se sont perdus ou dupliqués")
        #expect(plan.before.fileCount == plan.after.fileCount)
        #expect(report.abandoned == 0)
        #expect(plan.filesMoved > 0 && plan.filesAlreadyInPlace > 0)

        // Plus un fichier déplaçable en morceaux.
        let swap = volume.files.filter { !$0.isMovable && !$0.isContiguous }.count
        #expect(plan.after.fragmentedFiles == swap)

        let end = partition.lba(ofCluster: partition.clusterCount)
        for operation in plan.operations {
            #expect(operation.lba + operation.sectors <= end, "opération hors de la partition")
        }
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Trois fichiers entrelacés, et deux clusters libres en tout. Aucun trou
    /// n'accueille un fichier entier : tout se fait par la navette.
    @Test("Deux clusters libres suffisent à tout recoller")
    func twoFreeClustersAreEnough() {
        // 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
        // A B C A B C A B C A B  C  .  .  D  D  D  D
        let volume = fatVolume(clusterCount: 18, files: [
            (.document, [0, 3, 6, 9].map { Extent(start: $0, length: 1) }),
            (.application, [1, 4, 7, 10].map { Extent(start: $0, length: 1) }),
            (.churn, [2, 5, 8, 11].map { Extent(start: $0, length: 1) }),
            (.system, [Extent(start: 14, length: 4)]),
        ])
        let (plan, report) = FrontierCompactionStrategy().run(volume: volume)

        #expect(report.abandoned == 0)
        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.after.freeHoles == 1)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Le début du volume est déjà rangé : la passe ne le relit même pas.
    @Test("Un fichier déjà à sa place n'est ni lu ni écrit")
    func filesInPlaceAreLeftAlone() {
        let volume = fatVolume(clusterCount: 100, files: [
            (.system, [Extent(start: 0, length: 20)]),
            (.application, [Extent(start: 20, length: 10)]),
            (.document, [Extent(start: 40, length: 3), Extent(start: 60, length: 3)]),
        ])
        let (plan, _) = FrontierCompactionStrategy().run(volume: volume)

        for operation in plan.operations where operation.kind == .readExtent || operation.kind == .writeExtent {
            #expect((operation.cluster ?? 0) >= 30, "le début rangé du volume a été touché")
        }
        #expect(plan.filesAlreadyInPlace == 2)
        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.after.freeHoles == 1)
    }

    /// Le fichier d'échange ne bouge pas ; le trou qui le précède est comblé
    /// par un fichier pris plus haut, qui y tient pile.
    @Test("Le trou devant le fichier d'échange est comblé, le fichier d'échange n'est pas touché")
    func theGapBeforeTheSwapFileIsFilled() {
        let swap = Extent(start: 30, length: 20)
        let volume = fatVolume(clusterCount: 100, files: [
            (.system, [Extent(start: 0, length: 25)]),
            (.swap, [swap]),
            (.application, [Extent(start: 50, length: 12)]),
            (.document, [Extent(start: 70, length: 5)]),
        ])
        let (plan, _) = FrontierCompactionStrategy().run(volume: volume)

        for mutation in plan.mutations {
            #expect(!(mutation.start < Int(swap.end) && mutation.start + mutation.count > Int(swap.start)),
                    "le fichier d'échange a été touché")
        }
        // Le fichier de 5 clusters devant le fichier d'échange, celui de 12
        // juste derrière : il ne reste que le trou de la fin.
        #expect(plan.after.freeHoles == 1)
        #expect(plan.after.fragmentedFiles == 0)
    }

    /// Trois fenêtres entre deux obstacles : 100, 110 et 70 clusters. Un
    /// fichier de 105 clusters ne tient que dans la deuxième, un de 95 dans
    /// les deux premières. Rangés dans l'ordre du volume, les petits
    /// rempliraient la première et celui de 95, déjà dans la deuxième, y
    /// resterait : le gros n'aurait plus nulle part où aller.
    @Test("Un gros fichier sans autre fenêtre à sa taille passe avant les autres")
    func largeFilesClaimTheirLastWindow() {
        let volume = fatVolume(clusterCount: 300, files: [
            (.document, [Extent(start: 0, length: 10)]),
            (.document, [Extent(start: 10, length: 10)]),
            (.document, [Extent(start: 20, length: 10)]),
            (.document, [Extent(start: 30, length: 10)]),
            (.document, [Extent(start: 40, length: 10)]),
            (.archive, [Extent(start: 50, length: 50), Extent(start: 230, length: 55)]),
            (.swap, [Extent(start: 100, length: 10)]),
            (.application, [Extent(start: 110, length: 95)]),
            (.swap, [Extent(start: 220, length: 10)]),
        ])
        let (plan, report) = FrontierCompactionStrategy().run(volume: volume)

        #expect(report.abandoned == 0)
        #expect(plan.after.fragmentedFiles == 0)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    /// Les validations d'un lot tiennent en quelques écritures : bien moins
    /// que les trois par déplacement d'une validation fichier par fichier.
    @Test("Les validations sont groupées")
    func commitsAreBatched() {
        var files: [(category: ClusterCategory, extents: [Extent])] = []
        // Quarante petits fichiers derrière un grand trou : ils descendent tous
        // dans le trou sans rien quitter qui serve à un autre.
        files.append((.system, [Extent(start: 0, length: 10)]))
        for index in 0..<40 {
            files.append((.document, [Extent(start: 500 + UInt32(index) * 2, length: 2)]))
        }
        let volume = fatVolume(clusterCount: 1_000, files: files)
        let (plan, report) = FrontierCompactionStrategy().run(volume: volume)

        let moves = plan.operations.filter { $0.kind == .writeExtent }.count
        #expect(moves == 40)
        #expect(report.commits < moves / 4)
        #expect(plan.after.freeHoles == 1)
        expectWritesOnlyOnReleasedClusters(plan)
    }

    @Test("Le tassage à la frontière ne se choisit pas tout seul")
    func itIsNeverThePeriodTool() {
        #expect(DefragPlanner.strategy(for: .fat16).id == "windows95")
        #expect(DefragPlanner.strategy(for: .fat32).id == "windows95")
        #expect(DefragPlanner.strategy(named: "frontierCompaction")?.label == "Tassage à la frontière")
    }
}
