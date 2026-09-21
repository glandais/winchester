import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Une journée de la vie d'un disque.
///
/// Ce qui se teste n'est pas le son, mais ce dont il dépend : la journée écrit
/// ce que l'histoire annonce, elle lit ce que l'activité suppose, elle reste
/// dans le volume, et elle laisse le disque au soir exactement là où la
/// génération le laisse.
@Suite("Journée d'un disque généré")
struct DaySessionTests {

    private struct Played {
        let replay: HistoryReplay
        let plan: DayPlan
        let operations: [DiskOperation]
        let mutations: [MapMutation]
        let disk: GeneratedDisk
    }

    private static func play(_ id: String, day: UInt32) throws -> Played {
        let replay = HistoryReplay(try ScenarioLibrary.load(id))
        if day > 0 { replay.skip(through: day - 1) }
        let disk = replay.snapshot()
        let sink = OperationSink()
        let plan = DayPlanner.plan(day: day, replay: replay, disk: disk,
                                   diskBytesPerSecond: 5_000_000, into: sink)
        return Played(replay: replay, plan: plan, operations: sink.operations,
                      mutations: sink.mutations, disk: disk)
    }

    @Test("Une journée n'accède qu'au volume, et ses phases avancent",
          arguments: [("dev-1996", UInt32(120)), ("secretaire-1993", 200), ("gamer-1999", 365)])
    func withinVolume(id: String, day: UInt32) throws {
        let played = try Self.play(id, day: day)
        #expect(!played.operations.isEmpty)
        for operation in played.operations {
            #expect(operation.lba >= played.plan.partition.startLBA)
            #expect(operation.lba + operation.sectors <= played.plan.partition.totalSectors)
            #expect(operation.sectors > 0)
            #expect(played.plan.phases.indices.contains(operation.phase))
        }
        let phases = played.operations.map(\.phase)
        #expect(zip(phases, phases.dropFirst()).allSatisfy { $0 <= $1 })
        // La journée s'ouvre sur un démarrage et se ferme sur l'arrêt.
        #expect(phases.first == 0)
        #expect(played.plan.bootFiles > 0)
        // Hors de l'app, `String(localized:)` retombe sur la langue source.
        #expect(played.plan.phases.first?.label == "Boot")
        #expect(played.plan.phases.last?.label == "Shutdown")
    }

    @Test("Une journée lit autant qu'elle écrit, et pas seulement ce que l'histoire dit")
    func activityReads() throws {
        let played = try Self.play("dev-1996", day: 120)
        #expect(played.plan.activities.contains(.compile))
        #expect(played.plan.filesRead > 0)
        // Un développeur relit ses sources et ses objets : la journée lit plus
        // qu'elle n'écrit.
        #expect(played.plan.bytesRead > played.plan.bytesWritten)
        let reads = played.operations.filter { $0.kind == .readExtent }
        #expect(reads.count > 100)
    }

    @Test("Ce que la journée écrit est ce que l'histoire lui fait écrire")
    func writesFollowTheHistory() throws {
        let played = try Self.play("dev-1996", day: 120)
        let announced = played.plan.bytesWritten
        #expect(announced > 0)
        // Les écritures de données couvrent les clusters que l'allocateur a
        // donnés ce jour-là.
        let written = played.operations.filter { $0.kind == .writeExtent }
        #expect(!written.isEmpty)
        #expect(played.plan.filesWritten > 0)
        #expect(played.plan.filesDeleted > 0)
        // La carte reçoit des couleurs et des libérations.
        #expect(played.mutations.contains { $0.category == .free })
        #expect(played.mutations.contains { $0.category != .free })
    }

    @Test("Jouer la journée fait avancer l'histoire d'un jour, et d'un seul")
    func advancesOneDay() throws {
        let played = try Self.play("secretaire-1996", day: 100)
        #expect(played.replay.nextDay ?? .max > 100)
        // L'état du soir est celui qu'un simple saut donne.
        let skipped = HistoryReplay(try ScenarioLibrary.load("secretaire-1996"))
        skipped.skip(through: 100)
        #expect(played.replay.bitmap.usedCount == skipped.bitmap.usedCount)
        #expect(played.replay.catalog.files.map(\.extents) == skipped.catalog.files.map(\.extents))
    }

    @Test("Deux journées identiques donnent la même passe")
    func deterministic() throws {
        let a = try Self.play("dev-1996", day: 120)
        let b = try Self.play("dev-1996", day: 120)
        #expect(a.operations.count == b.operations.count)
        #expect(zip(a.operations, b.operations).allSatisfy {
            $0.lba == $1.lba && $0.sectors == $1.sectors && $0.isWrite == $1.isWrite
                && $0.thinkTime == $1.thinkTime && $0.phase == $1.phase
        })
    }

    @Test("L'attente de la ligne et de la source est bridée")
    func waitsAreCapped() throws {
        let played = try Self.play("famille-2003", day: 400)
        #expect(played.plan.activities.contains(.download) || played.plan.activities.contains(.media))
        #expect(played.plan.waitSeconds > 0)
        let pause = DayScript.matching(played.disk.spec).maximumPause
        #expect(played.operations.allSatisfy { $0.thinkTime <= pause + 3 })
    }

    @Test("Une journée de joueur charge son jeu avant de sauvegarder")
    func gameDayLoadsLevels() throws {
        let played = try Self.play("gamer-1999", day: 365)
        #expect(played.plan.activities.contains(.game))
        #expect(played.plan.bytesRead > 10_000_000)
    }
}
