import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// La règle NTFS des clusters retenus, vérifiée là où elle vit : dans le
/// volume, et non dans une stratégie.
///
/// Sur NTFS, ce qu'un déplacement quitte reste occupé jusqu'au point de
/// contrôle suivant. Deux outils sur cinq l'ignoraient, parce que la règle
/// était une méthode qu'on pouvait ne pas appeler ; elle est maintenant la
/// seule façon de déplacer sur NTFS.
@Suite("Points de contrôle NTFS")
struct CheckpointTests {

    /// Trois fichiers sur un volume de 100 clusters : `A` au début, `B` en
    /// deux morceaux de part et d'autre de `C`, et un trou de 10 clusters au
    /// fond.
    private static func volume(format: VolumeFormat) -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 100,
                                          clusterSectors: 8, format: format)
        let layout: [[Extent]] = [
            [Extent(start: 0, length: 10)],
            [Extent(start: 10, length: 40), Extent(start: 60, length: 30)],
            [Extent(start: 50, length: 10)],
        ]
        let files = layout.enumerated().map { position, extents in
            DefragFile(id: UInt32(position), path: "\\F\(position).DAT", category: .document,
                       walkOrder: position, extents: extents, isMovable: true)
        }
        return DefragVolume(partition: partition, files: files)
    }

    @Test("Sur NTFS, un déplacement ne réutilise pas avant le point de contrôle ce qu'un autre vient de quitter")
    func releasedClustersWaitForCheckpoint() {
        var volume = Self.volume(format: .ntfs)
        #expect(volume.releaseWaitsForCheckpoint)

        // `A` part au fond. Ses dix clusters de tête sont libres pour le
        // système de fichiers, mais pas encore réutilisables.
        volume.relocateHoldingReleased(0, to: [Extent(start: 90, length: 10)])
        #expect(volume.heldClusters == [Extent(start: 0, length: 10)])
        #expect(!volume.bitmap.isFree(Extent(start: 0, length: 10)))
        // Le premier trou de dix clusters que voit un défragmenteur qui relit
        // le bitmap : il n'y en a aucun.
        #expect(DefragOperations.firstGap(in: volume, need: 10, avoidingMFTZone: true) == nil)

        // Le point de contrôle : la place est rendue.
        volume.releaseHeldClusters()
        #expect(volume.heldClusters.isEmpty)
        #expect(DefragOperations.firstGap(in: volume, need: 10, avoidingMFTZone: true) == Extent(start: 0, length: 10))
    }

    @Test("Sur FAT, ce qu'un déplacement quitte est libre aussitôt")
    func fatReleasesAtOnce() {
        var volume = Self.volume(format: .fat16)
        #expect(!volume.releaseWaitsForCheckpoint)
        volume.relocate(0, to: [Extent(start: 90, length: 10)])
        #expect(volume.heldClusters.isEmpty)
        #expect(DefragOperations.firstGap(in: volume, need: 10, avoidingMFTZone: true) == Extent(start: 0, length: 10))
    }

    @Test("Sur NTFS, un déplacement qui rendrait aussitôt ce qu'il quitte est refusé")
    func ntfsRefusesImmediateRelease() async {
        await #expect(processExitsWith: .failure) {
            var volume = CheckpointTests.volume(format: .ntfs)
            volume.relocate(0, to: [Extent(start: 90, length: 10)])
        }
    }

    @Test("Ne changer que les extents qui bougent retient la même chose")
    func changesOnlyHoldsTheSame() {
        var whole = Self.volume(format: .ntfs)
        var changes = Self.volume(format: .ntfs)
        // Le second morceau de `B` recollé derrière le premier… sur la place
        // de `C`, qui part d'abord au fond.
        whole.relocateHoldingReleased(2, to: [Extent(start: 90, length: 10)])
        changes.relocateHoldingReleased(2, to: [Extent(start: 90, length: 10)])
        whole.releaseHeldClusters()
        changes.releaseHeldClusters()
        let merged = [Extent(start: 10, length: 40), Extent(start: 50, length: 30)]
        whole.relocateHoldingReleased(1, to: merged)
        changes.relocateHoldingReleased(1, to: merged, changesOnly: true)
        #expect(whole.heldClusters == changes.heldClusters)
        #expect(whole.heldClusters == [Extent(start: 80, length: 10)])
        #expect(whole.bitmap.freeCount == changes.bitmap.freeCount)
    }

    /// Un point de contrôle qui tombe pendant un déplacement libère ce que les
    /// précédents ont quitté, pas ce que celui-ci quitte : il n'est validé
    /// qu'à sa fin.
    @Test("Un point de contrôle ne rend que ce qui a été validé avant lui")
    func checkpointReleasesOnlyWhatCameBefore() {
        var volume = Self.volume(format: .ntfs)
        let sink = OperationSink()
        var checkpoints = NTFSCheckpoints()

        // Un premier déplacement, court : pas de point de contrôle.
        volume.relocateHoldingReleased(2, to: [Extent(start: 90, length: 10)])
        sink.emit(DiskOperation(kind: .metadata, phase: 0, lba: 0, sectors: 1,
                                isWrite: true, issueTime: 0, cluster: nil))
        checkpoints.afterCommit(&volume, sink: sink)
        #expect(volume.heldClusters == [Extent(start: 50, length: 10)])

        // Un second, qui dure plus que l'intervalle : le point de contrôle
        // tombe pendant qu'il copie.
        volume.relocateHoldingReleased(0, to: [Extent(start: 50, length: 10)])
        let bytes = Int(NTFSCheckpoints.interval * OperationSink.plannedBytesPerSecond)
        sink.emit(DiskOperation(kind: .writeExtent, phase: 0, lba: 0,
                                sectors: bytes / DriveGeometry.bytesPerSector,
                                isWrite: true, issueTime: 0, cluster: 0))
        checkpoints.afterCommit(&volume, sink: sink)
        // Ce que `C` avait quitté est rendu ; ce que `A` vient de quitter,
        // non.
        #expect(volume.heldClusters == [Extent(start: 0, length: 10)])
    }

    /// Les deux outils qui relisent le bitmap à chaque trou, sur le cas qui
    /// les départage : le seul trou à la taille du second fichier cassé est
    /// celui que le premier vient de quitter.
    @Test("XP et JkDefrag ne se posent pas sur la place qu'ils viennent de quitter",
          arguments: ["windowsXP", "jkDefrag"])
    func toolsDoNotReuseBeforeCheckpoint(strategyID: String) throws {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 200,
                                          clusterSectors: 8, format: .ntfs)
        // `A` (20 clusters, ses deux moitiés à l'envers) n'a qu'un trou à sa
        // taille, au fond. `B` (20 clusters, en deux morceaux) n'en aurait un
        // que sur la place de `A`. Le reste est immobile.
        let layout: [[Extent]] = [
            [Extent(start: 10, length: 10), Extent(start: 0, length: 10)],
            [Extent(start: 20, length: 10), Extent(start: 40, length: 10)],
            [Extent(start: 30, length: 10), Extent(start: 50, length: 130)],
        ]
        let files = layout.enumerated().map { position, extents in
            DefragFile(id: UInt32(position), path: "\\F\(position).DAT", category: .document,
                       walkOrder: position, extents: extents, isMovable: position < 2)
        }
        let volume = DefragVolume(partition: partition, files: files)
        let strategy = try #require(DefragPlanner.strategy(named: strategyID))
        let plan = strategy.plan(volume: volume)
        let a = try #require(plan.arrangement.first { $0.id == 0 })
        let b = try #require(plan.arrangement.first { $0.id == 1 })
        #expect(a.extents == [Extent(start: 180, length: 20)])
        // Le déplacement de `A` a duré bien moins que cinq secondes : sa place
        // est encore retenue quand vient le tour de `B`, qui reste en morceaux.
        #expect(b.extents.count == 2)
    }
}
