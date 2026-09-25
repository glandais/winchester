import Foundation
import DiskCore
import AVFAudio

// MARK: - La passe

/// Ce que le bilan retient d'une passe : le compte des repères, et les octets
/// par tranche pour dire ce que chaque phase a lu ou écrit.
final class Tally {
    var cues = 0
    var bytes: [Int] = []

    func consume(_ batch: PassBatch) {
        cues += batch.cues.count
        for bucket in batch.buckets {
            if bucket.index >= bytes.count {
                bytes.append(contentsOf: repeatElement(0, count: bucket.index + 1 - bytes.count))
            }
            bytes[bucket.index] += bucket.bytes
        }
    }

    /// Débit par tranche, en Mo/s, sur toute la passe.
    func throughput(duration: Double) -> [Double] {
        let bucketCount = max(Int(ceil(duration / ScenarioBuilder.bucketDuration)), 1)
        var throughput = [Double](repeating: 0, count: bucketCount)
        for (index, bytes) in bytes.enumerated() {
            throughput[min(index, bucketCount - 1)] += Double(bytes)
        }
        return throughput.map { $0 / ScenarioBuilder.bucketDuration / 1_000_000 }
    }
}


/// Ce que la passe a réellement fait : c'est le rapport entre déplacements et
/// évacuations qui explique la durée, bien plus que le volume de données.
func describe(_ plan: DefragPlan) -> String {
    let fullBlocks = ScenarioRequest.fullBlocks
    let moved = Double(plan.movedBytes) / 1_000_000
    return """
    outil         : \(plan.strategy.label)\(fullBlocks ? ", par blocs pleins" : "")
    volume        : \(plan.partition.clusterCount) clusters de \(plan.partition.clusterBytes / 1_024) Ko, \
    \(plan.before.fileCount) fichiers, \(Int(plan.before.fill * 100)) % plein
    déplacements  : \(plan.filesMoved) fichiers, \(plan.evacuations) évacuations, \
    \(plan.filesAlreadyInPlace) déjà en place
    déplacé       : \(String(format: "%.0f", moved)) Mo pour un volume de \
    \(plan.partition.capacityBytes / 1_000_000) Mo
    fragmentés    : \(plan.before.fragmentedFiles) avant, \(plan.after.fragmentedFiles) après
    morceaux      : \(plan.before.fragments) avant, \(plan.after.fragments) après
    trous libres  : \(plan.before.freeHoles) avant, \(plan.after.freeHoles) après
    """ + (plan.logFlushes > 0 ? "\njournal       : \(plan.logFlushes) vidages forcés (DELETE_PENDING)" : "")
}

/// Ce qu'un démarrage a lu, et qui du processeur ou du disque l'a fait durer.
func describe(_ playback: BootPlayback, duration: Double) -> String {
    let disk = playback.diskSeconds(duration: duration)
    let total = playback.thinkSeconds + disk
    let share = total > 0 ? disk / total * 100 : 0
    return """
    système       : \(playback.osName)\(playback.appName.map { " puis \($0)" } ?? "")
    fichiers      : \(playback.filesRead) ouverts, \(playback.residentFiles) résidents
    dates d'accès : \(playback.stampedFiles) réécrites en \(playback.stampWrites) écritures\
    \(playback.stampLogWrites > 0 ? ", et \(playback.stampLogWrites) du journal" : "")
    \(playback.softwareCache.map { "cache système : \($0)\n" } ?? "")\
    calcul        : \(String(format: "%.1f", playback.thinkSeconds)) s
    disque        : \(String(format: "%.1f", disk)) s \
    (\(String(format: "%.0f", share)) % de l'attente)
    témoin        : \(String(format: "%.1f", playback.freshSeconds)) s jamais fragmenté, \
    soit \(String(format: "%+.0f", (duration / max(playback.freshSeconds, 0.001) - 1) * 100)) %
    """
}

/// Ce que chaque étape a duré. Sur un démarrage décrit en fichiers, aucune de
/// ces durées n'est imposée : elles tombent de la simulation.
func describePhases(_ spans: [PhaseSpan], throughput: [Double]) -> String {
    spans.map { span in
        let first = Int(span.start / ScenarioBuilder.bucketDuration)
        let last = min(Int(span.end / ScenarioBuilder.bucketDuration), throughput.count)
        let megabytes = first < last
            ? throughput[first..<last].reduce(0, +) * ScenarioBuilder.bucketDuration
            : 0
        let label = span.label.count > 36
            ? String(span.label.prefix(35)) + "…"
            : span.label.padding(toLength: 36, withPad: " ", startingAt: 0)
        return String(format: "  %@ %6.1f s  %6.1f Mo", label, span.duration, megabytes)
    }.joined(separator: "\n")
}

/// Ce qu'une installation a posé, et ce qui l'a fait durer. Le décompte est
/// refait par le planificateur seul, sans simuler le disque : c'est lui qui sait
/// ce qu'ont coûté la source et les tables.
func describe(_ playback: InstallPlayback, installed: InstalledDisk, geometry: DriveGeometry,
              duration: Double) -> String {
    let rate = geometry.outerSustainedMBs * 1_000_000
    let plan = InstallPlanner.plan(installed: installed, diskBytesPerSecond: rate,
                                   into: OperationSink { _, _, _, _ in })
    let disk = max(duration - plan.thinkSeconds, 0)
    let metrics = playback.installed.metrics
    return """
    système       : \(playback.osName)\(playback.applications.isEmpty ? "" : " puis " + playback.applications.joined(separator: ", "))
    source        : \(playback.medium)
    posé          : \(plan.filesWritten) fichiers, \(plan.bytesWritten / 1_000_000) Mo
    archives      : \(plan.temporaryFiles) extraites (\(plan.temporaryBytes / 1_000_000) Mo), \
    \(plan.temporaryBytesRead / 1_000_000) Mo relus
    tables        : \(plan.metadataFlushes) vidages, \(plan.metadataSectors) secteurs
    registre      : \(plan.settingsRewrites) réécritures
    redémarrages  : \(plan.reboots)
    hors disque   : \(String(format: "%.1f", plan.thinkSeconds)) s dont source \(String(format: "%.1f", plan.sourceSeconds)) s
    disque        : \(String(format: "%.1f", disk)) s
    arrivée       : \(metrics.fileCount) fichiers, \(metrics.fragmentedFileCount) fragmentés, \
    \(metrics.freeRunCount) trous libres, \(Int(metrics.fill * 100)) % plein
    """
}

/// Ce qu'une journée a fait au disque.
func describe(_ playback: DayPlayback, stats: TraceStats, duration: Double) -> String {
    return """
    journée       : jour \(playback.day), \(playback.date)
    activités     : \(playback.activities.isEmpty ? "aucune" : playback.activities.map(\.label).joined(separator: ", "))
    volume        : \(playback.disk.catalog.liveCount) fichiers, \
    \(Int(playback.disk.metrics.fill * 100)) % plein, \(playback.disk.metrics.fragmentedFileCount) fragmentés
    annoncé       : \(playback.bytes / 1_000_000) Mo à écrire
    lu / écrit    : \(stats.bytesRead / 1_000_000) / \(stats.bytesWritten / 1_000_000) Mo
    """
}

// MARK: - Mesures et écriture

/// Niveau de chaque phase, relu dans le fichier brut : les phases d'une passe
/// en boucle fermée ne sont datées qu'à la fin.
func report(_ label: String, _ range: Range<Int>, from file: FileHandle, frameCount: Int) {
    var sum = 0.0
    var peak: Float = 0
    let upper = min(range.upperBound, frameCount)
    var index = range.lowerBound
    if index < upper {
        try? file.seek(toOffset: UInt64(index * 8))
    }
    while index < upper {
        let n = min(1 << 16, upper - index)
        // `readData` rend un objet libéré en différé : sans bassin, tout le
        // fichier resterait en mémoire jusqu'à la fin du programme.
        autoreleasepool {
            let data = file.readData(ofLength: n * 8)
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float.self)
                for i in 0..<(data.count / 8) {
                    let sample = floats[2 * i]
                    sum += Double(sample * sample)
                    peak = max(peak, abs(sample))
                }
            }
        }
        index += n
    }
    let rms = (sum / Double(range.count)).squareRoot()
    let db = rms > 0 ? 20 * log10(rms) : -Double.infinity
    let name = label.padding(toLength: 34, withPad: " ", startingAt: 0)
    let line = name + String(format: "RMS %7.1f dBFS   crête %.3f", db, peak) + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

// `AVAudioFile` ne finalise l'en-tête du WAV qu'à sa libération : l'écriture est
// donc confinée à une fonction, faute de quoi le fichier annonce zéro image.
//
// `read` rend les `n` images suivantes, entrelacées en flottants ; ce qu'il ne
// fournit pas est du silence — c'est ainsi que la vidéo prolonge le son sous
// son bilan final.
func writeWAV(to path: String, frameCount: Int, gain: Float,
              read: (_ count: Int) -> Data) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                               settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: sampleRate,
                                          AVNumberOfChannelsKey: 2,
                                          AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false])

    let chunk = 48_000
    var written = 0
    while written < frameCount {
        let n = min(chunk, frameCount - written)
        try autoreleasepool {
            let data = read(n)
            let available = min(data.count / 8, n)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float.self)
                for i in 0..<available {
                    buffer.floatChannelData![0][i] = floats[2 * i] * gain
                    buffer.floatChannelData![1][i] = floats[2 * i + 1] * gain
                }
            }
            for i in available..<n {
                buffer.floatChannelData![0][i] = 0
                buffer.floatChannelData![1][i] = 0
            }
            try file.write(from: buffer)
        }
        written += n
    }
}

/// Le même, depuis le fichier brut du mixeur.
func writeWAV(to path: String, from raw: FileHandle, frameCount: Int, gain: Float) throws {
    try raw.seek(toOffset: 0)
    try writeWAV(to: path, frameCount: frameCount, gain: gain) { raw.readData(ofLength: $0 * 8) }
}

// MARK: - Le volume

/// Colonnes de l'histogramme d'extents, celles de
/// `FILESYSTEM_EXPERT_REVIEW.md` §2 : la borne haute de chaque classe.
let extentClasses: [(label: String, upTo: Int)] = [
    ("1", 1), ("2", 2), ("3-4", 4), ("5-16", 16), ("17-64", 64), (">64", .max),
]

/// Les répertoires qui existent sur le disque, ce qu'ils occupent, et combien
/// sont en plusieurs clusters ou en plusieurs morceaux.
func directoryLine(_ disk: GeneratedDisk) -> String {
    let existing = disk.catalog.directories.filter(\.exists)
    guard !existing.isEmpty else { return "\(disk.catalog.directories.count)" }
    let clusters = existing.reduce(0) { $0 + Int($1.entry.clusterCount) }
    let multi = existing.filter { $0.entry.clusterCount > 1 }.count
    let fragmented = existing.filter { $0.extents.count > 1 }.count
    let worst = existing.map(\.extents.count).max() ?? 0
    return "\(existing.count), \(clusters) clusters, \(multi) en plusieurs clusters, "
        + "\(fragmented) fragmentés, pire \(worst) extents"
}

/// Empreinte du volume au cluster près : chaque fichier vivant, dans l'ordre
/// du catalogue, avec ses extents, puis ce que le système de fichiers occupe
/// pour lui-même. Deux générations qui la partagent ont posé les mêmes
/// clusters aux mêmes fichiers.
func fingerprint(_ disk: GeneratedDisk) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    func mix(_ value: UInt32) {
        var v = value
        for _ in 0..<4 {
            hash = (hash ^ UInt64(v & 0xFF)) &* 0x0000_0100_0000_01B3
            v >>= 8
        }
    }
    for record in disk.catalog.files {
        mix(record.id)
        mix(UInt32(truncatingIfNeeded: record.logicalSize))
        for extent in record.extents { mix(extent.start); mix(extent.length) }
    }
    for directory in disk.catalog.directories {
        for extent in directory.extents { mix(extent.start); mix(extent.length) }
    }
    for extent in disk.systemExtents { mix(extent.start); mix(extent.length) }
    return hash
}

/// Ce qu'un volume généré contient : combien de fichiers en combien de
/// morceaux, et ce que coûte sa génération.
func describeDisk(_ disk: GeneratedDisk, generation: Double) -> String {
    var histogram = [Int](repeating: 0, count: extentClasses.count)
    for record in disk.catalog.files where !record.isResident && !record.extents.isEmpty {
        let count = record.extents.count
        histogram[extentClasses.firstIndex { count <= $0.upTo }!] += 1
    }
    let m = disk.metrics
    return """
    empreinte     : \(String(fingerprint(disk), radix: 16))
    génération    : \(String(format: "%.0f", generation * 1_000)) ms
    volume        : \(disk.clusterCount) clusters de \(disk.clusterBytes / 1_024) Ko, \
    \(Int(m.fill * 100)) % plein
    fichiers      : \(m.fileCount), \(m.residentFileCount) résidents
    extents       : \(zip(extentClasses, histogram).map { "\($0.label)=\($1)" }.joined(separator: " "))
    fragmentés    : \(m.fragmentedFileCount) sur \(m.fragmentableFileCount) fragmentables, \
    \(String(format: "%.1f", m.fragmentedRatioAmongFragmentable * 100)) %
    pire fichier  : \(m.maxExtentsPerFile) extents
    trous libres  : \(m.freeRunCount)
    refusées      : \(disk.failedWrites) écritures, faute de place
    MFT           : \(disk.mftClusters) clusters en \(disk.mftExtents) extents
    répertoires   : \(directoryLine(disk))

    """
}
