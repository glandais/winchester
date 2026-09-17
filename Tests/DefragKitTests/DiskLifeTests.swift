import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Le défilement de la vie d'un disque.
@Suite("Vie d'un disque en accéléré")
struct DiskLifeTests {

    @Test("Le défilement arrive sur le disque généré, jour après jour")
    func scrollingReachesGeneration() throws {
        let spec = try ScenarioLibrary.load("secretaire-1996")
        let life = DiskLife(spec: spec)
        while !life.isFinished { life.advance(days: 50) }

        let generated = try DiskGenerator.generate(spec)
        #expect(life.replay.bitmap.usedCount == generated.bitmap.usedCount)
        #expect(life.digests.count == Int(spec.timeline.dayCount) + 1)
        #expect(life.digests.map(\.day) == Array(0...spec.timeline.dayCount))
        // La dernière journée décrit le volume tel que la galerie le montre.
        let last = try #require(life.digests.last)
        #expect(last.fragmentedFiles == generated.metrics.fragmentedFileCount)
        #expect(abs(last.fill - generated.metrics.fill) < 0.001)
    }

    @Test("Le disque se remplit et se fragmente, dans cet ordre")
    func volumeFillsUp() throws {
        let life = DiskLife(spec: try ScenarioLibrary.load("secretaire-1996"))
        while !life.isFinished { life.advance(days: 50) }
        let curves = life.curves
        #expect(curves.fill.count == life.digests.count)
        // Le premier jour installe, le dernier est plein et mité.
        #expect(curves.fill.first ?? 1 < curves.fill.max() ?? 0)
        #expect(curves.fragmented.last ?? 0 > curves.fragmented.first ?? .max)
    }

    @Test("Les repères nomment l'installation, le remplissage et les grosses journées")
    func landmarksAreWorthListening() throws {
        let life = DiskLife(spec: try ScenarioLibrary.load("gamer-1999"))
        while !life.isFinished { life.advance(days: 50) }

        #expect(life.landmarks.first?.landmark == .installation)
        #expect(life.landmarks.first?.day == 0)
        let kinds = Set(life.landmarks.compactMap(\.landmark?.label))
        #expect(kinds.contains("Installation"))
        #expect(kinds.contains { $0.hasPrefix("Disque à") })
        // Assez pour se repérer, pas au point de remplacer le défilement.
        #expect(life.landmarks.count > 2 && life.landmarks.count < 60)
        // Les grosses journées sont espacées d'au moins un mois.
        let heavy = life.landmarks.filter { $0.landmark == .heavyDay }.map(\.day)
        #expect(zip(heavy, heavy.dropFirst()).allSatisfy { $1 - $0 > 30 })
    }

    @Test("On peut s'arrêter sur un repère et écouter la journée suivante")
    func stopsOnLandmarkAndHandsOver() throws {
        let life = DiskLife(spec: try ScenarioLibrary.load("dev-1996"))
        life.advance()                       // l'installation
        let landmark = try #require(life.advanceToLandmark())
        #expect(landmark.landmark != nil)

        // Le rejeu est laissé au matin du jour suivant : la journée s'écoute.
        let day = try #require(life.nextDay)
        #expect(day == landmark.day + 1)
        let sink = OperationSink()
        let plan = DayPlanner.plan(day: day, replay: life.replay, disk: life.replay.snapshot(),
                                   diskBytesPerSecond: 5_000_000, into: sink)
        #expect(plan.day == day)
        #expect(!sink.operations.isEmpty)
    }

    @Test("La carte du défilement est celle du volume à ce jour-là")
    func mapFollowsTheVolume() throws {
        let spec = try ScenarioLibrary.load("gamer-1993")
        let life = DiskLife(spec: spec)
        while !life.isFinished { life.advance(days: 50) }

        let generated = try DiskGenerator.generate(spec)
        let volume = try GeneratedVolumeBridge.volume(from: generated)
        let player = ClusterMapPlayer()
        player.load(clusterCount: volume.partition.clusterCount, initialRuns: volume.categoryRuns())
        let expected = player.shades(at: 0)
        let shades = life.shades()

        #expect(shades.count == expected.count)
        let differing = zip(shades, expected).filter { $0.category != $1.category }.count
        #expect(differing == 0)
    }
}
