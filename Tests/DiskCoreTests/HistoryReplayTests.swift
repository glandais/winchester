import Testing
import Foundation
@testable import DiskCore

/// La vie d'un disque rejouée jour par jour.
@Suite("Rejeu de l'histoire")
struct HistoryReplayTests {

    /// Des disquettes, une défragmentation dans l'histoire, des
    /// réenregistrements par temporaire.
    static let profiles = ["gamer-1993", "dev-1993", "secretaire-1996"]

    @Test("Rejouée jour par jour, en racontant ou non, l'histoire arrive sur le disque généré",
          arguments: HistoryReplayTests.profiles)
    func replayMatchesGeneration(id: String) throws {
        let spec = try ScenarioLibrary.load(id)
        let generated = try DiskGenerator.generate(spec)
        let replay = HistoryReplay(spec)

        // Un jour raconté, deux sautés : les deux chemins doivent faire le
        // même disque.
        while let day = replay.nextDay {
            if day % 3 == 0 {
                replay.play(day: day) { _, _ in true }
            } else {
                replay.skip(through: day)
            }
        }
        #expect(replay.isFinished)
        #expect(replay.failedWrites == generated.failedWrites)
        #expect(replay.bitmap.usedCount == generated.bitmap.usedCount)
        #expect(replay.catalog.liveCount == generated.catalog.liveCount)
        var mismatches = 0
        for record in generated.catalog.files {
            if replay.catalog[record.id]?.extents != record.extents { mismatches += 1 }
        }
        #expect(mismatches == 0)

        let snapshot = replay.snapshot()
        #expect(snapshot.metrics.fragmentedFileCount == generated.metrics.fragmentedFileCount)
        #expect(snapshot.metrics.freeRunCount == generated.metrics.freeRunCount)
    }

    @Test("Ce que chaque événement prend et rend refait la bitmap, cluster par cluster",
          arguments: HistoryReplayTests.profiles)
    func stepsAccountForEveryCluster(id: String) throws {
        let replay = HistoryReplay(try ScenarioLibrary.load(id))
        var bitmap = ClusterBitmap(clusterCount: replay.bitmap.clusterCount)
        for extent in replay.initialSystemExtents { bitmap.allocate(extent) }

        var kinds: Set<String> = []
        while let day = replay.nextDay {
            replay.play(day: day) { timed, step in
                _ = bitmap.free(step.released)
                for extent in step.allocated { bitmap.allocate(extent) }
                for extent in step.metadataGrew { bitmap.allocate(extent) }
                if !step.moves.isEmpty {
                    for move in step.moves { _ = bitmap.free(move.from) }
                    for move in step.moves { for extent in move.to { bitmap.allocate(extent) } }
                    kinds.insert("defragment")
                }
                // Tout ce qui est pris est écrit.
                #expect(step.written.clusterCount >= step.allocated.clusterCount)
                switch timed.event {
                case .replaceViaTemporary: if !step.written.isEmpty { kinds.insert("replace") }
                case .create: kinds.insert("create")
                case .delete: kinds.insert("delete")
                default: break
                }
                return true
            }
        }

        var mismatches = 0
        var cluster: UInt32 = 0
        while cluster < bitmap.clusterCount {
            if bitmap.isAllocated(cluster) != replay.bitmap.isAllocated(cluster) { mismatches += 1 }
            cluster += 1
        }
        #expect(mismatches == 0)
        #expect(kinds.contains("create"))
        if id == "dev-1993" { #expect(kinds.contains("defragment")) }
        if id == "secretaire-1996" { #expect(kinds.contains("replace")) }
    }

    @Test("Sauter jusqu'à un jour donne le même état que le jouer")
    func skipEqualsPlay() throws {
        let spec = try ScenarioLibrary.load("secretaire-1996")
        let played = HistoryReplay(spec)
        let skipped = HistoryReplay(spec)
        while let day = played.nextDay, day <= 200 { played.play(day: day) { _, _ in true } }
        skipped.skip(through: 200)
        #expect(played.nextDay == skipped.nextDay)
        #expect(played.playedEvents == skipped.playedEvents)
        #expect(played.bitmap.usedCount == skipped.bitmap.usedCount)
        #expect(played.catalog.files.map(\.extents) == skipped.catalog.files.map(\.extents))
    }
}
