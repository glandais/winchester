import Foundation
import Combine

/// Assemble la chaîne complète : scénario → requêtes bloc → chronologie
/// mécanique → repères audio, et expose au rendu ce qu'il faut pour afficher
/// l'état du disque à un instant donné.
@MainActor
final class SimulationModel: ObservableObject {

    let geometry = DriveGeometry.defaultDrive
    let seekModel = SeekModel.defaultModel
    let engine: DiskNoiseEngine

    private(set) var spans: [PhaseSpan] = []
    private(set) var requests: [BlockRequest] = []
    private(set) var trace: DiskTrace
    private(set) var cues: [AudioCue] = []

    /// Séries agrégées par tranche de 100 ms, pour l'affichage.
    private(set) var iops: [Double] = []
    private(set) var throughputMBs: [Double] = []
    private(set) var peakIOPS: Double = 1

    static let bucketDuration = 0.1

    var duration: Double { trace.duration }
    var stats: TraceStats { trace.stats }

    init() {
        let geometry = DriveGeometry.defaultDrive
        let seekModel = SeekModel.defaultModel
        let phases = WorkloadLibrary.windowsBootAndOffice

        let generator = WorkloadGenerator(geometry: geometry)
        let (requests, spans) = generator.generate(phases: phases)
        let total = spans.last?.end ?? 0
        let spinUpDuration = phases.first?.duration ?? 6

        let trace = DiskSimulator.run(
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            totalDuration: total,
            spinUpAt: 0.35,
            spinUpDuration: spinUpDuration - 0.6
        )

        self.requests = requests
        self.spans = spans
        self.trace = trace
        self.engine = DiskNoiseEngine(rpm: geometry.rpm)
        self.cues = AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders)

        buildSeries()
        engine.load(cues: cues, duration: trace.duration)
    }

    private func buildSeries() {
        let count = max(Int(ceil(trace.duration / Self.bucketDuration)), 1)
        var counts = [Double](repeating: 0, count: count)
        var bytes = [Double](repeating: 0, count: count)

        for request in requests {
            let index = min(Int(request.issueTime / Self.bucketDuration), count - 1)
            counts[index] += 1
            bytes[index] += Double(request.sectorCount * DriveGeometry.bytesPerSector)
        }

        iops = counts.map { $0 / Self.bucketDuration }
        throughputMBs = bytes.map { $0 / Self.bucketDuration / 1_000_000 }
        peakIOPS = max(iops.max() ?? 1, 1)
    }

    // MARK: - Interrogation à un instant donné

    func span(at time: Double) -> PhaseSpan? {
        spans.last { $0.start <= time } ?? spans.first
    }

    private func headSampleIndex(at time: Double) -> Int? {
        let samples = trace.headSamples
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        guard samples[0].time <= time else { return nil }
        while low < high {
            let mid = (low + high + 1) / 2
            if samples[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func cylinder(at time: Double) -> Int {
        guard let index = headSampleIndex(at: time) else { return 0 }
        return trace.headSamples[index].cylinder
    }

    /// Derniers accès, pour la traînée affichée sur le plateau.
    func recentAccesses(at time: Double, window: Double = 1.6, limit: Int = 90) -> [HeadSample] {
        guard let index = headSampleIndex(at: time) else { return [] }
        var result: [HeadSample] = []
        var i = index
        while i >= 0 && result.count < limit && time - trace.headSamples[i].time <= window {
            result.append(trace.headSamples[i])
            i -= 1
        }
        return result
    }

    func bucketValue(_ series: [Double], at time: Double) -> Double {
        guard !series.isEmpty else { return 0 }
        let index = min(max(Int(time / Self.bucketDuration), 0), series.count - 1)
        return series[index]
    }

    /// Le voyant d'activité, comme sur la façade : c'est exactement le signal
    /// dont se contente HDDSynth pour déclencher ses sons.
    func activityLED(at time: Double) -> Bool {
        bucketValue(iops, at: time) > 0.5
    }
}
