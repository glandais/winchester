import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que les instruments lisent d'une passe : des cumuls qui doivent
/// retomber sur ce que la mécanique et la stratégie comptent de leur côté.
@Suite("Instruments d'une passe")
struct InstrumentsTests {

    private static let drive = DriveCatalog.fireball1996
    private static let setup = PassSetup(geometry: drive.geometry, seekModel: drive.seekModel,
                                         spinUpAt: 0, spinUpDuration: 0.9,
                                         idle: IdleBehavior(parkAfter: 1.0),
                                         tail: 3.5)

    /// Un petit FAT16 vieilli : assez pour que chaque outil ait du travail,
    /// assez petit pour que les onze passent en debug.
    private static func volume() -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, sectors: 40_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        return VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
    }

    private static func stream(_ strategy: any DefragStrategy,
                               on volume: DefragVolume) -> (plan: DefragPlan, history: PassBatch) {
        var history = PassBatch()
        let pipeline = PassPipeline(setup: setup, batchRequests: 41, batchSeconds: 0.5,
                                    deliver: { history.append($0) })
        let sink = OperationSink { operation, mutations, progress, moves in
            pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
        }
        let plan = strategy.plan(volume: volume, into: sink)
        pipeline.finish(plan: plan)
        return (plan, history)
    }

    @Test("Le temps d'une passe se recompose : seek, rotation, transfert, calcul, attente")
    func timeAddsUp() throws {
        let (_, history) = Self.stream(Windows95Strategy(), on: Self.volume())
        let end = try #require(history.end)
        let s = end.stats
        // L'horloge de la mécanique part plateau lancé : la montée en régime
        // précède la première requête et n'appartient à aucune.
        let work = end.workEnd - Self.setup.spinUpAt - Self.setup.spinUpDuration
        let parts = s.seekSeconds + s.rotationSeconds + s.busySeconds + s.stepSeconds
            + s.thinkSeconds + s.waitSeconds
        #expect(abs(parts - work) < 1e-6)

        var detail = ActivityDetail()
        for bucket in history.buckets { detail.add(bucket.detail) }
        let bucketed = detail.seekSeconds + detail.rotationSeconds + detail.transferSeconds
            + detail.thinkSeconds + detail.waitSeconds
        #expect(abs(bucketed - work) < 1e-6)
    }

    @Test("Le calcul d'un démarrage se sépare de l'attente")
    func thinkTimeIsSeparated() {
        let geometry = Self.drive.geometry
        var mechanics = DiskMechanics(geometry: geometry, seekModel: Self.drive.seekModel,
                                      spinUpAt: 0, spinUpDuration: 0.9)
        var events: [DiskEvent] = []
        // Une lecture, puis une seconde qui suit un calcul de 0,4 s, puis une
        // troisième imposée bien plus tard : 0,4 s de calcul, le reste d'attente.
        let requests = [
            BlockRequest(issueTime: 0, lba: 1_000, sectorCount: 8, isWrite: false, phaseIndex: 0),
            BlockRequest(issueTime: 0, lba: 900_000, sectorCount: 8, isWrite: false, phaseIndex: 0,
                         thinkTime: 0.4),
            BlockRequest(issueTime: 30, lba: 2_000, sectorCount: 16, isWrite: true, phaseIndex: 0),
        ]
        var end = 0.0
        for request in requests { end = mechanics.serve(request, events: &events).timing.end }

        let s = mechanics.stats
        #expect(abs(s.thinkSeconds - 0.4) < 1e-9)
        #expect(s.waitSeconds > 20)
        let parts = s.seekSeconds + s.rotationSeconds + s.busySeconds + s.stepSeconds
            + s.thinkSeconds + s.waitSeconds
        #expect(abs(parts - (end - 0.9)) < 1e-9)
    }

    @Test("Classes de seek, bandes de cylindres et lectures retombent sur les totaux")
    func distributionsAddUp() throws {
        let (_, history) = Self.stream(Windows95Strategy(), on: Self.volume())
        let end = try #require(history.end)
        var detail = ActivityDetail()
        for bucket in history.buckets { detail.add(bucket.detail) }

        #expect(detail.seekClasses.reduce(0, +) == end.stats.seekCount)
        #expect(detail.seekClasses[SeekClass.full.rawValue] == end.stats.fullStrokeSeeks)
        #expect(detail.cylinderBands.reduce(0, +) == end.requestCount)
        #expect(detail.readBytes == end.stats.bytesRead)
        #expect(detail.writeBytes == end.stats.bytesWritten)
        #expect(detail.readRequests <= end.requestCount)
    }

    @Test("Les compteurs publiés en cours de passe finissent sur ceux du plan",
          arguments: DefragPlanner.all.map(\.id))
    func movesEndOnThePlan(id: String) throws {
        let strategy = try #require(DefragPlanner.strategy(named: id))
        let (plan, history) = Self.stream(strategy, on: Self.volume())
        let last = history.moves.last?.moves ?? MoveCount()
        #expect(last.filesMoved == plan.filesMoved)
        #expect(last.evacuations == plan.evacuations)
        // Dans l'ordre de l'écoute.
        #expect(zip(history.moves, history.moves.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    @Test("L'écoute lit les compteurs à l'instant, pas en avance")
    func liveMovesFollowTheClock() throws {
        let volume = Self.volume()
        let (plan, history) = Self.stream(Windows95Strategy(), on: volume)
        let live = LivePass(session: nil, geometry: Self.setup.geometry,
                            seekModel: Self.setup.seekModel,
                            spindle: SpindleTimeline(spinUpAt: 0, duration: 0.9,
                                                     rpm: Self.setup.geometry.rpm,
                                                     spinDownAt: nil, spinDownDuration: 4),
                            phases: plan.phases)
        live.absorb(history)
        let middle = try #require(history.moves.dropFirst(history.moves.count / 2).first)
        live.advance(to: middle.time - 0.000_1)
        let before = live.moves?.filesMoved ?? 0
        live.advance(to: middle.time)
        #expect(live.moves == middle.moves)
        #expect(before <= middle.moves.filesMoved)
        live.advance(to: (history.end?.duration ?? 0) + 1)
        #expect(live.moves?.filesMoved == plan.filesMoved)
    }
}

/// L'état d'arrivée d'une passe, gardé pour la reposer ailleurs.
@Suite("Arrangement d'arrivée")
struct ArrangementTests {

    private static func volume() -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, sectors: 40_000_000 / 512,
                                          clusterSectors: 8, format: .fat16)
        return VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
    }

    @Test("Reposé sur le volume de départ, l'arrangement redonne l'état d'arrivée du plan",
          arguments: DefragPlanner.all.map(\.id))
    func arrangementRebuildsTheAfterState(id: String) throws {
        let strategy = try #require(DefragPlanner.strategy(named: id))
        let volume = Self.volume()
        let plan = strategy.plan(volume: volume, into: OperationSink())
        #expect(plan.arrangement.count == volume.files.count)

        let rebuilt = volume.rearranged(plan.arrangement).stats
        #expect(rebuilt.fragmentedFiles == plan.after.fragmentedFiles)
        #expect(rebuilt.fragments == plan.after.fragments)
        #expect(rebuilt.freeHoles == plan.after.freeHoles)
        #expect(rebuilt.fileCount == plan.after.fileCount)
        #expect(abs(rebuilt.fill - plan.after.fill) < 1e-12)
        #expect(abs(rebuilt.extentsPerFile - plan.after.extentsPerFile) < 1e-12)
    }

    @Test("Un plan résumé garde son arrangement")
    func summarizedKeepsArrangement() {
        let plan = Windows95Strategy().plan(volume: Self.volume())
        #expect(plan.summarized().arrangement == plan.arrangement)
        #expect(!plan.arrangement.isEmpty)
    }
}

/// Démarrer un disque rangé, c'est lire ses fichiers là où la passe les a mis.
@Suite("Démarrage d'un disque rangé")
struct RangedBootTests {

    /// Sur `dev-1993` et non plus `gamer-1993` : plein à 99,96 %, celui-ci ne
    /// laissait à la passe de 95 que deux déplacements depuis le lot 1, et
    /// plus aucun depuis que ses répertoires prennent leur place.
    @Test("Le démarrage du disque rangé suit l'arrangement de la passe")
    func rangedBootReadsTheNewPlaces() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("dev-1993"))
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let plan = Windows95Strategy().plan(volume: volume)
        let moved = plan.arrangement.filter { place in
            volume.files.first { $0.id == place.id }?.extents != place.extents
        }
        try #require(!moved.isEmpty, "la passe doit déplacer quelque chose")

        let places = Dictionary(plan.arrangement.map { ($0.id, $0.extents) },
                                uniquingKeysWith: { _, last in last })
        let ranged = disk.rearranged(extents: places)
        for place in moved {
            if let directory = FileCatalog.directory(ofItem: place.id) {
                #expect(ranged.catalog.directories[Int(directory)].extents == place.extents)
            } else {
                #expect(ranged.catalog[place.id]?.extents == place.extents)
            }
        }

        // Le démarrage lit autre chose, ailleurs : ses requêtes ne sont plus
        // les mêmes.
        let before = BootPlanner.plan(disk: disk)
        let after = BootPlanner.plan(disk: ranged)
        #expect(before.filesRead == after.filesRead)
        #expect(before.requests.map(\.lba) != after.requests.map(\.lba))
        // Et l'état du volume rangé est celui que le plan annonce — lequel
        // compte les répertoires, que la passe a rangés avec le reste.
        let fragmentedDirectories = ranged.catalog.directories.filter { $0.extents.coalesced().count > 1 }.count
        #expect(ranged.metrics.fragmentedFileCount + fragmentedDirectories == plan.after.fragmentedFiles)
    }
}
