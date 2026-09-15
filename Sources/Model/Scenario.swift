import Foundation
import DiskCore

enum ScenarioKind: String, CaseIterable, Identifiable {
    case windowsBoot
    case defrag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsBoot: return "Démarrage"
        case .defrag:      return "Défragmentation"
        }
    }

    var summary: String {
        switch self {
        case .windowsBoot:
            return "Démarrage Windows puis lancement d'une suite bureautique, sur un IDE de 2001"
        case .defrag:
            return "Passe complète du défragmenteur de Windows 95 sur un volume FAT16 vieilli"
        }
    }
}

/// Mutation de la carte des clusters, datée par la simulation.
struct TimedMutation {
    let time: Double
    let start: Int
    let count: Int
    let category: UInt8
}

/// Cluster touché à un instant donné, pour surligner la carte.
struct ClusterActivity {
    let start: Double
    let end: Double
    let cluster: Int
    let isWrite: Bool
}

/// Tout ce qu'il faut pour rejouer visuellement une défragmentation.
struct DefragPlayback {
    let partition: PartitionGeometry
    let plan: DefragPlan
    let mutations: [TimedMutation]
    let activity: [ClusterActivity]
    /// Octets déplacés cumulés, par tranche de `SimulationModel.bucketDuration`.
    let movedBytes: [Double]
    let workEndTime: Double
}

/// Un scénario entièrement calculé : requêtes, chronologie mécanique, repères
/// audio et séries d'affichage.
struct Scenario {
    let kind: ScenarioKind
    let geometry: DriveGeometry
    let seekModel: SeekModel
    let requests: [BlockRequest]
    let spans: [PhaseSpan]
    let trace: DiskTrace
    let cues: [AudioCue]
    let duration: Double

    let iops: [Double]
    let throughputMBs: [Double]
    let peakIOPS: Double

    let defrag: DefragPlayback?

    var stats: TraceStats { trace.stats }
}

enum ScenarioBuilder {

    static let bucketDuration = 0.1

    static func build(_ kind: ScenarioKind) -> Scenario {
        switch kind {
        case .windowsBoot: return buildWindowsBoot()
        case .defrag:      return buildDefrag()
        }
    }

    // MARK: - Démarrage Windows

    private static func buildWindowsBoot() -> Scenario {
        let geometry = DriveGeometry.defaultDrive
        let seekModel = SeekModel.defaultModel
        let phases = WorkloadLibrary.windowsBootAndOffice

        let generator = WorkloadGenerator(geometry: geometry)
        let (requests, spans) = generator.generate(phases: phases)
        let total = spans.last?.end ?? 0
        let spinUpDuration = (phases.first?.duration ?? 6) - 0.6

        let trace = DiskSimulator.run(
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            totalDuration: total,
            spinUpAt: 0.35,
            spinUpDuration: spinUpDuration
        )

        let series = buildSeries(requests: requests, trace: trace, duration: trace.duration)

        return Scenario(
            kind: .windowsBoot,
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            spans: spans,
            trace: trace,
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: trace.duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: nil
        )
    }

    // MARK: - Défragmentation

    /// Partition C: de 180 Mo en tête d'un disque de 876 Mo, clusters de 4 Ko —
    /// ce que donnait `FORMAT` pour cette taille en FAT16. Elle occupe les 21 %
    /// extérieurs du plateau, et les tables d'allocation sont à son tout début :
    /// valider un déplacement fait revenir le bras au bord, d'où le
    /// « clac … clac » régulier.
    ///
    /// Une passe complète dure ici un peu plus de trois minutes. Sur un volume
    /// de l'époque réellement dimensionné (500 Mo à 1 Go) elle en prenait vingt
    /// à quarante-cinq : c'est le volume qui est réduit, pas le modèle.
    static let partitionSectors = 180_000_000 / DriveGeometry.bytesPerSector
    static let clusterSectors = 8
    static let volumeFill = 0.78

    /// Silence final, une fois la passe terminée.
    private static let tailDuration = 3.5

    private static func buildDefrag() -> Scenario {
        let geometry = DriveGeometry.win95Drive
        let seekModel = SeekModel.win95Model

        let partition = PartitionGeometry(startLBA: 0,
                                          sectors: partitionSectors,
                                          clusterSectors: clusterSectors)
        let volume = VolumeFactory.agedWindows95(partition: partition, fill: volumeFill)
        let plan = DefragPlanner.plan(volume: volume)

        let requests = plan.operations.map {
            BlockRequest(issueTime: $0.issueTime,
                         lba: $0.lba,
                         sectorCount: $0.sectors,
                         isWrite: $0.isWrite,
                         phaseIndex: $0.phase)
        }

        // Le plateau tourne déjà : Windows est démarré. La rampe de 0,9 s n'est
        // qu'un fondu pour que la couche de rotation s'installe.
        let trace = DiskSimulator.run(
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            totalDuration: 0,
            spinUpAt: 0,
            spinUpDuration: 0.9
        )

        let workEnd = trace.timings.last?.end ?? 0
        let duration = workEnd + tailDuration

        // Datation des mutations de la carte et des surlignages.
        var mutations: [TimedMutation] = []
        var activity: [ClusterActivity] = []
        var movedBytes = [Double](repeating: 0, count: bucketCount(duration))

        for (index, operation) in plan.operations.enumerated() {
            guard index < trace.timings.count else { break }
            let timing = trace.timings[index]

            for mutation in operation.mutations {
                mutations.append(TimedMutation(time: timing.end,
                                               start: mutation.start,
                                               count: mutation.count,
                                               category: mutation.category.rawValue))
            }
            if let cluster = operation.cluster {
                activity.append(ClusterActivity(start: timing.start, end: timing.end,
                                                cluster: cluster, isWrite: operation.isWrite))
            }
            if operation.kind == .writeExtent {
                let bucket = min(Int(timing.end / bucketDuration), movedBytes.count - 1)
                movedBytes[bucket] += Double(operation.sectors * DriveGeometry.bytesPerSector)
            }
        }
        mutations.sort { $0.time < $1.time }
        for index in 1..<max(movedBytes.count, 1) { movedBytes[index] += movedBytes[index - 1] }

        let spans = closedLoopSpans(requests: requests,
                                    trace: trace,
                                    descriptors: plan.phases,
                                    duration: duration)
        let series = buildSeries(requests: requests, trace: trace, duration: duration)

        return Scenario(
            kind: .defrag,
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            spans: spans,
            trace: trace,
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: DefragPlayback(partition: partition,
                                   plan: plan,
                                   mutations: mutations,
                                   activity: activity,
                                   movedBytes: movedBytes,
                                   workEndTime: workEnd)
        )
    }

    // MARK: - Outils communs

    private static func bucketCount(_ duration: Double) -> Int {
        max(Int(ceil(duration / bucketDuration)), 1)
    }

    /// Les phases d'un scénario en boucle fermée ne se datent qu'après coup :
    /// chacune commence quand sa première opération est prise en charge et
    /// s'arrête quand la suivante démarre.
    private static func closedLoopSpans(requests: [BlockRequest],
                                        trace: DiskTrace,
                                        descriptors: [PhaseDescriptor],
                                        duration: Double) -> [PhaseSpan] {
        var firstTime: [Int: Double] = [:]
        for (index, request) in requests.enumerated() where index < trace.timings.count {
            let time = trace.timings[index].start
            if let existing = firstTime[request.phaseIndex] {
                firstTime[request.phaseIndex] = min(existing, time)
            } else {
                firstTime[request.phaseIndex] = time
            }
        }

        var indices = Array(0..<descriptors.count).filter { firstTime[$0] != nil || $0 == descriptors.count - 1 }
        indices.sort()

        var spans: [PhaseSpan] = []
        for (position, index) in indices.enumerated() {
            let start = firstTime[index] ?? (trace.timings.last?.end ?? 0)
            let end: Double
            if position + 1 < indices.count {
                end = firstTime[indices[position + 1]] ?? duration
            } else {
                end = duration
            }
            spans.append(PhaseSpan(descriptor: descriptors[index], index: index,
                                   start: max(start, spans.last?.end ?? 0), end: end))
        }
        return spans
    }

    /// Séries d'affichage bâties sur les **temps simulés** et non sur les dates
    /// d'émission : en boucle fermée, toutes les requêtes sont émises à zéro et
    /// c'est le disque qui décide du rythme.
    private static func buildSeries(requests: [BlockRequest],
                                    trace: DiskTrace,
                                    duration: Double) -> (iops: [Double], throughput: [Double], peak: Double) {
        let count = bucketCount(duration)
        var counts = [Double](repeating: 0, count: count)
        var bytes = [Double](repeating: 0, count: count)

        for (index, request) in requests.enumerated() {
            let time = index < trace.timings.count ? trace.timings[index].start : request.issueTime
            let bucket = min(max(Int(time / bucketDuration), 0), count - 1)
            counts[bucket] += 1
            bytes[bucket] += Double(request.sectorCount * DriveGeometry.bytesPerSector)
        }

        let iops = counts.map { $0 / bucketDuration }
        return (iops,
                bytes.map { $0 / bucketDuration / 1_000_000 },
                max(iops.max() ?? 1, 1))
    }
}
