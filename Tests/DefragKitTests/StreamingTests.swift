import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Une passe calculée au fil de l'eau doit être **exactement** celle qu'on
/// calculait d'un bloc.
///
/// C'est la seule promesse du passage en flux, et elle se vérifie mieux qu'elle
/// ne s'écoute : chaque test ci-dessous recalcule une passe entière à
/// l'ancienne — plan complet, simulation de toute la liste, repères sur toute
/// la trace — et la compare, élément par élément, à ce que la chaîne livre par
/// paquets.
@Suite("Passe au fil de l'eau")
struct StreamingTests {

    private static let drive = DriveCatalog.fireball1996

    /// Un FAT16 de 180 Mo vieilli sur place, fabriqué par le fixture.
    private static func agedVolume() -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0,
                                          sectors: 180_000_000 / 512,
                                          clusterSectors: 8,
                                          format: .fat16)
        return VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
    }

    private static let setup = PassSetup(geometry: drive.geometry, seekModel: drive.seekModel,
                                         spinUpAt: 0, spinUpDuration: 0.9,
                                         idle: IdleBehavior(parkAfter: 1.0),
                                         tail: 3.5)

    // MARK: - La référence : le calcul d'un bloc

    /// Tout ce qu'une passe de défragmentation produisait, calculé d'un bloc
    /// comme le faisait le compilateur de scénarios avant le passage en flux.
    private struct Whole {
        let plan: DefragPlan
        let trace: DiskTrace
        let cues: [AudioCue]
        let mutations: [TimedMutation]
        let activity: [ClusterActivity]
        let buckets: [ActivityBucket]
        let spans: [PhaseSpan]
        let duration: Double
    }

    private static func whole(_ volume: DefragVolume, _ strategy: any DefragStrategy) -> Whole {
        let plan = DefragPlanner.plan(volume: volume, using: strategy)
        let requests = plan.operations.map {
            BlockRequest(issueTime: $0.issueTime, lba: $0.lba, sectorCount: $0.sectors,
                         isWrite: $0.isWrite, phaseIndex: $0.phase)
        }
        let trace = DiskSimulator.run(geometry: setup.geometry, seekModel: setup.seekModel,
                                      requests: requests, totalDuration: 0,
                                      spinUpAt: setup.spinUpAt,
                                      spinUpDuration: setup.spinUpDuration,
                                      idle: setup.idle)
        let duration = (trace.timings.last?.end ?? 0) + 3.5

        var mutations: [TimedMutation] = []
        var activity: [ClusterActivity] = []
        var buckets: [Int: ActivityBucket] = [:]
        var firstStarts: [Int: Double] = [:]
        var seekCursor = 0
        _ = seekCursor
        for (index, operation) in plan.operations.enumerated() {
            let timing = trace.timings[index]
            for position in Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount) {
                let mutation = plan.mutations[position]
                mutations.append(TimedMutation(time: timing.end, start: mutation.start,
                                               count: mutation.count,
                                               category: mutation.category.rawValue))
            }
            if let cluster = operation.cluster {
                activity.append(ClusterActivity(start: timing.start, end: timing.end,
                                                cluster: cluster, isWrite: operation.isWrite))
            }
            let bucket = ActivityBucket.index(at: timing.start)
            buckets[bucket, default: ActivityBucket(index: bucket)].requests += 1
            buckets[bucket, default: ActivityBucket(index: bucket)].bytes
                += operation.sectors * DriveGeometry.bytesPerSector
            if operation.kind == .writeExtent {
                let moved = ActivityBucket.index(at: timing.end)
                buckets[moved, default: ActivityBucket(index: moved)].movedBytes
                    += operation.sectors * DriveGeometry.bytesPerSector
            }
            firstStarts[operation.phase] = min(firstStarts[operation.phase] ?? .infinity, timing.start)
            seekCursor += 1
        }
        return Whole(plan: plan, trace: trace,
                     cues: ReferenceCues.build(events: trace.events,
                                               cylinders: setup.geometry.cylinders),
                     mutations: mutations, activity: activity,
                     buckets: buckets.values.sorted { $0.index < $1.index },
                     spans: PhaseSpan.closedLoop(firstStarts: firstStarts,
                                                 descriptors: plan.phases, duration: duration),
                     duration: duration)
    }

    /// La même passe, livrée par paquets et recollée.
    private static func streamed(_ volume: DefragVolume, _ strategy: any DefragStrategy,
                                 batchRequests: Int = 37) -> PassBatch {
        let recorder = PassRecorder()
        let pipeline = PassPipeline(setup: setup, batchRequests: batchRequests,
                                    batchSeconds: 0.5, deliver: recorder.receive)
        let sink = OperationSink { operation, mutations, progress, moves in
            pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
        }
        let plan = strategy.plan(volume: volume, into: sink)
        pipeline.finish(plan: plan)
        return recorder.history
    }

    // MARK: - Les repères audio

    @Test("Les repères d'une passe de défragmentation sont ceux du calcul d'un bloc",
          arguments: ["windows95", "jkDefrag", "ultraDefrag", "jkDefragSortSize"])
    func defragCuesMatch(strategyID: String) throws {
        let strategy = try #require(DefragPlanner.strategy(named: strategyID))
        let volume = Self.agedVolume()
        let reference = Self.whole(volume, strategy)
        let history = Self.streamed(volume, strategy)

        #expect(reference.cues.count > 100)
        Self.expectSameCues(history.cues, reference.cues)
    }

    /// Un démarrage n'est ni une passe pilotée par un débit ni une passe qui
    /// part dès que le disque se libère : entre deux lectures, le système
    /// calcule (`BlockRequest.thinkTime`). C'est le seul scénario où la date
    /// d'une requête dépend de ce que la précédente a duré, donc celui où le
    /// flux avait le plus de chances de s'écarter du calcul d'un bloc.
    @Test("Les repères d'un démarrage sont ceux du calcul d'un bloc")
    func bootCuesMatch() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("gamer-1993"))
        let plan = BootPlanner.plan(disk: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: plan.partition.totalSectors)
        let setup = PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                              spinUpAt: 0.35,
                              spinUpDuration: max(plan.post - 0.6, 0.5),
                              idle: IdleBehavior(parkAfter: 1.0),
                              tail: plan.tail)
        let trace = DiskSimulator.run(geometry: setup.geometry, seekModel: setup.seekModel,
                                      requests: plan.requests, totalDuration: 0,
                                      spinUpAt: setup.spinUpAt,
                                      spinUpDuration: setup.spinUpDuration,
                                      idle: setup.idle)
        let reference = ReferenceCues.build(events: trace.events,
                                            cylinders: setup.geometry.cylinders)

        let recorder = PassRecorder()
        let pipeline = PassPipeline(setup: setup, batchRequests: 11, deliver: recorder.receive)
        for request in plan.requests { pipeline.serve(request) }
        let end = pipeline.finish()

        #expect(reference.count > 100)
        Self.expectSameCues(recorder.history.cues, reference)
        #expect(end.eventCount == trace.events.count)
        #expect(end.requestCount == plan.requests.count)
        // Les phases se datent à leur première requête, ici comme là-bas.
        let spans = PhaseSpan.closedLoop(firstStarts: end.firstStarts,
                                         descriptors: plan.phases,
                                         duration: end.duration)
        #expect(recorder.history.phases.map(\.index) == spans.dropFirst().map(\.index))
    }

    /// L'installation mêle ce que les deux autres séparent : des opérations
    /// qui changent la carte, comme une défragmentation, et du temps passé
    /// hors du disque entre elles, comme un démarrage.
    @Test("Les repères et la carte d'une installation sont ceux du calcul d'un bloc")
    func installMatches() throws {
        let installed = try DiskGenerator.install(try ScenarioLibrary.load("gamer-1993"))
        let hardware = GeneratedVolumeBridge.drive(for: installed.disk.spec,
                                                   atLeast: GeneratedVolumeBridge.partition(of: installed.disk).totalSectors)
        let rate = hardware.geometry.outerSustainedMBs * 1_000_000
        let setup = PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                              spinUpAt: 0, spinUpDuration: 0.9,
                              idle: IdleBehavior(parkAfter: 1.0), tail: 3.5)

        let collected = OperationSink()
        InstallPlanner.plan(installed: installed, diskBytesPerSecond: rate, into: collected)
        let requests = collected.operations.map {
            BlockRequest(issueTime: $0.issueTime, lba: $0.lba, sectorCount: $0.sectors,
                         isWrite: $0.isWrite, phaseIndex: $0.phase, thinkTime: $0.thinkTime)
        }
        let trace = DiskSimulator.run(geometry: setup.geometry, seekModel: setup.seekModel,
                                      requests: requests, totalDuration: 0,
                                      spinUpAt: setup.spinUpAt, spinUpDuration: setup.spinUpDuration,
                                      idle: setup.idle)
        var mutations: [TimedMutation] = []
        for (index, operation) in collected.operations.enumerated() {
            for position in Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount) {
                let mutation = collected.mutations[position]
                mutations.append(TimedMutation(time: trace.timings[index].end, start: mutation.start,
                                               count: mutation.count,
                                               category: mutation.category.rawValue))
            }
        }

        let recorder = PassRecorder()
        let pipeline = PassPipeline(setup: setup, batchRequests: 29, batchSeconds: 0.5,
                                    deliver: recorder.receive)
        let sink = OperationSink { operation, slice, progress, moves in
            pipeline.serve(operation, mutations: slice, progress: progress, moves: moves)
        }
        InstallPlanner.plan(installed: installed, diskBytesPerSecond: rate, into: sink)
        let end = pipeline.finish()
        let history = recorder.history

        #expect(requests.count > 1_000)
        Self.expectSameCues(history.cues, ReferenceCues.build(events: trace.events,
                                                               cylinders: setup.geometry.cylinders))
        #expect(end.stats.requestCount == trace.stats.requestCount)
        #expect(end.stats.bytesWritten == trace.stats.bytesWritten)
        #expect(history.mutations.count == mutations.count)
        #expect(zip(history.mutations, mutations).allSatisfy {
            $0.time == $1.time && $0.start == $1.start && $0.count == $1.count && $0.category == $1.category
        })
        let progress = history.progress.map(\.value)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// Des trains denses, coupés par la durée maximale en plein milieu, avec
    /// des micro-transitoires qui tombent pile sur leurs bords : c'est là que
    /// le flux doit retenir sa décision le plus longtemps.
    @Test("Les trains et les micro-transitoires se décident comme d'un bloc, cas tordus compris")
    func syntheticCuesMatch() {
        var rng = SeededGenerator(seed: 0xC0E5)
        let seekModel = Self.drive.seekModel
        var events: [DiskEvent] = [DiskEvent(time: 0, kind: .spinUp(duration: 1))]
        var time = 1.0
        for _ in 0..<20_000 {
            if rng.chance(0.45) {
                let profile = seekModel.profile(distance: rng.uniform(1...900))
                events.append(DiskEvent(time: time, kind: .seek(profile)))
            } else if rng.chance(0.5) {
                events.append(DiskEvent(time: time, kind: .headSwitch))
            } else if rng.chance(0.5) {
                events.append(DiskEvent(time: time, kind: .trackStep))
            } else {
                events.append(DiskEvent(time: time, kind: .transfer(duration: 0.01, sectors: 8,
                                                                    isWrite: false)))
            }
            time += rng.chance(0.2) ? rng.uniform(0.02...0.4) : rng.uniform(0.0...0.012)
        }
        events.append(DiskEvent(time: time + 2, kind: .spinDown(duration: 3)))

        var stream = CueStream(cylinders: 1_000)
        var cues: [AudioCue] = []
        for (index, event) in events.enumerated() {
            stream.ingest(event)
            if index % 13 == 0 {
                let mark = stream.watermark
                let before = cues.count
                stream.release(into: &cues)
                // Rien de ce qui sort ne peut précéder ce qui est déjà sorti.
                #expect(cues[before...].allSatisfy { $0.time < mark })
            }
        }
        stream.finish()
        stream.release(into: &cues)

        Self.expectSameCues(cues, ReferenceCues.build(events: events, cylinders: 1_000))
    }

    // MARK: - Le reste de la passe

    @Test("Échantillons, carte, accès et activité sont ceux du calcul d'un bloc")
    func displayStreamsMatch() throws {
        let volume = Self.agedVolume()
        let strategy = Windows95Strategy()
        let reference = Self.whole(volume, strategy)
        let history = Self.streamed(volume, strategy)
        let end = try #require(history.end)

        #expect(history.samples.count == reference.trace.headSamples.count)
        for (a, b) in zip(history.samples, reference.trace.headSamples) {
            #expect(a.time == b.time && a.duration == b.duration && a.cylinder == b.cylinder
                    && a.endCylinder == b.endCylinder && a.head == b.head && a.isWrite == b.isWrite)
        }

        #expect(history.mutations.count == reference.mutations.count)
        #expect(zip(history.mutations, reference.mutations).allSatisfy {
            $0.time == $1.time && $0.start == $1.start && $0.count == $1.count
                && $0.category == $1.category
        })
        #expect(history.activity.count == reference.activity.count)
        #expect(zip(history.activity, reference.activity).allSatisfy {
            $0.start == $1.start && $0.end == $1.end && $0.cluster == $1.cluster
        })

        let buckets = history.buckets.map { bucket -> ActivityBucket in
            var copy = bucket
            copy.seeks = 0
            copy.seekDistance = 0
            copy.detail = ActivityDetail()
            return copy
        }
        #expect(buckets == reference.buckets)
        #expect(history.buckets.reduce(0) { $0 + $1.seeks } == reference.trace.stats.seekCount)
        #expect(history.buckets.reduce(0) { $0 + $1.seekDistance }
                == reference.trace.stats.totalSeekDistance)

        #expect(end.duration == reference.duration)
        #expect(end.parkAt == reference.trace.parkAt)
        #expect(end.stats.requestCount == reference.trace.stats.requestCount)
        #expect(end.stats.bytesWritten == reference.trace.stats.bytesWritten)
        #expect(end.eventCount == reference.trace.events.count)
        let spans = PhaseSpan.closedLoop(firstStarts: end.firstStarts,
                                         descriptors: reference.plan.phases,
                                         duration: end.duration)
        #expect(spans.map(\.start) == reference.spans.map(\.start))

        let plan = try #require(end.plan)
        #expect(plan.filesMoved == reference.plan.filesMoved)
        #expect(plan.evacuations == reference.plan.evacuations)
        #expect(plan.operations.isEmpty && plan.mutations.isEmpty)

        // L'avancement ne recule jamais, et finit au bout.
        let progress = history.progress.map(\.value)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(progress.last == 1)
    }

    // MARK: - L'écoute

    @Test("L'écoute image par image ne garde que l'instant, et arrive au même état")
    func livePassForgetsThePast() throws {
        let volume = Self.agedVolume()
        // Il faut une passe longue devant une écoute courte. Depuis que
        // Windows 95 évacue au fond du volume, sa passe sur ce volume est trois
        // fois plus courte ; un tampon de 32 Ko lui rend sa longueur. C'est
        // elle qui compte ici, pas la fidélité du tampon.
        var strategy = Windows95Strategy()
        strategy.bufferBytes = 32 * 1024
        let reference = Self.whole(volume, strategy)

        // Les paquets sont livrés à l'écoute comme le ferait la session :
        // quelques secondes d'avance, pas plus.
        var batches: [PassBatch] = []
        let pipeline = PassPipeline(setup: Self.setup, deliver: { batches.append($0) })
        let sink = OperationSink { operation, mutations, progress, moves in
            pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
        }
        let plan = strategy.plan(volume: volume, into: sink)
        pipeline.finish(plan: plan)

        let live = LivePass(session: nil, geometry: Self.setup.geometry,
                            seekModel: Self.setup.seekModel, spindle: pipeline.spindle,
                            phases: plan.phases,
                            map: (volume.partition.clusterCount, volume.categoryRuns()))
        var cues: [AudioCue] = []
        var peakSamples = 0
        var next = 0
        var time = 0.0
        while time <= reference.duration + 1 {
            while next < batches.count && batches[next].clock <= time + 4 {
                live.absorb(batches[next])
                next += 1
            }
            live.advance(to: time)
            cues.append(contentsOf: live.takeCues(before: time + 0.7))
            peakSamples = max(peakSamples, live.samples.count)
            time += 1.0 / 30
        }
        while next < batches.count { live.absorb(batches[next]); next += 1 }
        live.advance(to: reference.duration + 2)
        cues.append(contentsOf: live.takeCues(before: .infinity))

        Self.expectSameCues(cues, reference.cues)
        #expect(live.isFinished)
        #expect(live.totals.requests == reference.trace.stats.requestCount)
        #expect(live.totals.seeks == reference.trace.stats.seekCount)
        #expect(live.totals.movedBytes == reference.plan.movedBytes)

        // La passe dure plus de trois minutes et compte douze mille requêtes ;
        // l'écoute n'en a jamais tenu qu'une poignée de secondes.
        #expect(reference.trace.headSamples.count > 10_000)
        #expect(peakSamples < reference.trace.headSamples.count / 10)

        let finalMap = ClusterMapPlayer()
        finalMap.load(ClusterMapTimeline(clusterCount: volume.partition.clusterCount,
                                         initialRuns: volume.categoryRuns(),
                                         mutations: reference.mutations))
        let map = try #require(live.map)
        #expect(map.cells(at: reference.duration + 2) == finalMap.cells(at: reference.duration + 2))
        #expect(map.pendingCount == 0)
    }

    // MARK: - La session

    @Test("Le producteur ne prend jamais plus que son horizon d'avance")
    func sessionHonoursItsHorizon() async throws {
        let volume = Self.agedVolume()
        let finished = Locked(false)
        let session = PassSession(horizon: 5) { outlet in
            let pipeline = PassPipeline(setup: Self.setup, deliver: outlet.deliver)
            let sink = OperationSink { operation, mutations, progress, moves in
                guard !outlet.isCancelled else { return }
                pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
            }
            let plan = Windows95Strategy().plan(volume: volume, into: sink)
            if !outlet.isCancelled { pipeline.finish(plan: plan) }
            finished.value = true
        }
        session.start()

        // Laissé seul, il avance jusqu'à l'horizon et s'arrête là.
        try await Task.sleep(for: .milliseconds(400))
        let first = session.drain(listenedThrough: 0)
        #expect(first.clock > 4)
        #expect(first.clock < 5 + 1)
        #expect(!finished.value)

        // Une écoute qui avance le fait avancer d'autant.
        try await Task.sleep(for: .milliseconds(200))
        let second = session.drain(listenedThrough: 20)
        #expect(second.clock <= first.clock + 0.1)
        try await Task.sleep(for: .milliseconds(400))
        let third = session.drain(listenedThrough: 20)
        #expect(third.clock > 24 && third.clock < 26)

        // Abandonné, il se libère et termine son calcul à vide.
        session.cancel()
        for _ in 0..<100 where !finished.value {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finished.value)
        #expect(session.drain(listenedThrough: 1_000).samples.isEmpty)
    }

    // MARK: - Outils

    private static func expectSameCues(_ actual: [AudioCue], _ expected: [AudioCue],
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        var mismatches = 0
        for (a, b) in zip(actual, expected) where a.time != b.time || signature(a) != signature(b) {
            mismatches += 1
        }
        #expect(mismatches == 0, "\(mismatches) repères diffèrent", sourceLocation: sourceLocation)
    }

    private static func signature(_ cue: AudioCue) -> String {
        switch cue.kind {
        case .spinUp(let d): return "up \(d)"
        case .spinDown(let d): return "down \(d)"
        case .seek(let profile, let mix): return "seek \(profile.distance) \(mix)"
        case .chatter(let run, let duration):
            return "chatter \(duration) " + run.map { "\($0.offset):\($0.profile.distance)" }
                .joined(separator: ",")
        case .tick(let kind): return "tick \(kind)"
        }
    }
}

/// Le constructeur de repères tel qu'il était avant le passage en flux, recopié
/// tel quel : c'est l'oracle auquel le flux se compare.
private enum ReferenceCues {

    static func build(events unsorted: [DiskEvent], cylinders: Int) -> [AudioCue] {
        let events = unsorted.sorted { $0.time < $1.time }
        var seeks: [(time: Double, profile: SeekProfile)] = []
        var ticks: [(time: Double, kind: HeadTick)] = []
        var cues: [AudioCue] = []

        for event in events {
            switch event.kind {
            case .spinUp(let d):
                cues.append(AudioCue(time: event.time, kind: .spinUp(duration: d)))
            case .spinDown(let d):
                cues.append(AudioCue(time: event.time, kind: .spinDown(duration: d)))
            case .seek(let profile):
                seeks.append((event.time, profile))
            case .headSwitch:
                ticks.append((event.time, .headSwitch))
            case .trackStep:
                ticks.append((event.time, .trackStep))
            case .transfer:
                break
            }
        }

        func travelMix(_ distance: Int) -> Double {
            min(max(Double(distance) / Double(max(cylinders - 1, 1)), 0), 1)
        }

        var covered: [(start: Double, end: Double)] = []
        var index = 0
        while index < seeks.count {
            let start = seeks[index].time
            var end = start + seeks[index].profile.total
            var run = [ChatterSeek(offset: 0,
                                   profile: seeks[index].profile,
                                   travelMix: travelMix(seeks[index].profile.distance))]
            var next = index + 1

            while next < seeks.count,
                  seeks[next].time < end + 0.030,
                  seeks[next].time - start < 1.0 {
                let offset = seeks[next].time - start
                run.append(ChatterSeek(offset: offset,
                                       profile: seeks[next].profile,
                                       travelMix: travelMix(seeks[next].profile.distance)))
                end = max(end, seeks[next].time + seeks[next].profile.total)
                next += 1
            }

            if run.count == 1 {
                cues.append(AudioCue(time: start,
                                     kind: .seek(profile: run[0].profile,
                                                 travelMix: run[0].travelMix)))
            } else {
                cues.append(AudioCue(time: start,
                                     kind: .chatter(run: run, duration: end - start)))
            }

            covered.append((start, end))
            index = next
        }

        var coverIndex = 0
        var lastTickTime = -Double.infinity
        for tick in ticks {
            while coverIndex < covered.count && covered[coverIndex].end < tick.time {
                coverIndex += 1
            }
            if coverIndex < covered.count,
               tick.time >= covered[coverIndex].start,
               tick.time <= covered[coverIndex].end {
                continue
            }
            guard tick.time - lastTickTime >= 0.018 else { continue }
            lastTickTime = tick.time
            cues.append(AudioCue(time: tick.time, kind: .tick(tick.kind)))
        }

        cues.sort { $0.time < $1.time }
        return cues
    }
}
