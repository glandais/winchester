import Foundation
import DiskCore
import AVFAudio

// Rendu hors-ligne de la trace complète dans un WAV.
//
//   ./Tools/build-render.sh
//   /tmp/rendertrace sortie.wav              # scénario de démarrage
//   SCENARIO=defrag /tmp/rendertrace out.wav # passe de défragmentation
//
// `SCENARIO` accepte aussi l'identifiant d'un profil de la galerie : le disque
// est alors généré, converti en volume FAT16, et sa passe rendue sur le
// matériel que décrit sa fiche. Préfixé de `boot:`, c'est le **démarrage** de
// ce disque qui est rendu — celui-là ne refuse aucun format.
//
//   SCENARIO=dev-1993 /tmp/rendertrace dev1993.wav
//   SCENARIO=boot:dev-1993 /tmp/rendertrace boot1993.wav
//
// Préfixé de `install:`, c'est l'**installation** du disque qui est rendue :
// le jour 0 de son histoire, rejoué sur un volume vierge.
//
//   SCENARIO=install:secretaire-1996 /tmp/rendertrace install1996.wav
//
// Préfixé de `day:` et suivi d'un numéro de jour, c'est une **journée d'usage**
// qui est rendue : démarrage, séances, arrêt, sur le disque tel qu'il est ce
// jour-là.
//
//   SCENARIO=day:dev-1996:120 /tmp/rendertrace jour120.wav
//
//   SPINDLE_GAIN=0 /tmp/rendertrace tete-seule.wav
//   TRANSIENT_GAIN=0 /tmp/rendertrace rotation-seule.wav
//
// Permet d'auditionner et de régler le synthé sans passer par le simulateur.
//
// La passe est rendue **au fil de l'eau**, comme l'application l'écoute : le
// son est mixé à mesure qu'elle se planifie, écrit sur disque dès qu'il est
// définitif, et rien d'autre qu'une fenêtre de quelques secondes ne reste en
// mémoire. C'est ce qui permet de rendre une passe de plusieurs heures.

let sampleRate = 48_000.0
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "disknoise.wav"

let requested = ProcessInfo.processInfo.environment["SCENARIO"] ?? ""

let wantsBoot = requested.hasPrefix("boot:")
let wantsInstall = requested.hasPrefix("install:")
let wantsDay = requested.hasPrefix("day:")
// `day:<profil>:<jour>`
let dayParts = wantsDay ? requested.dropFirst(4).split(separator: ":", maxSplits: 1) : []
let requestedDay = UInt32(dayParts.count > 1 ? String(dayParts[1]) : "") ?? 1
let profileID = wantsBoot ? String(requested.dropFirst(5))
    : wantsInstall ? String(requested.dropFirst(8))
    : wantsDay ? String(dayParts.first ?? "")
    : requested

// `STRATEGY` force le défragmenteur simulé au lieu de laisser le format le
// dater. C'est ainsi que se compare une passe UltraDefrag à celle de l'outil
// d'époque sur exactement le même volume :
//
//   PLAN_ONLY=1 STRATEGY=ultraDefrag SCENARIO=famille-2007 /tmp/rendertrace /dev/null
//
// `FULL_BLOCKS=1` lui fait déplacer par blocs pleins, comme le recollage
// économe : XP, UltraDefrag et JkDefrag seulement.
let strategyID = ProcessInfo.processInfo.environment["STRATEGY"]
let strategy: (any DefragStrategy)?
if let strategyID {
    guard let found = DefragPlanner.strategy(named: strategyID) else {
        FileHandle.standardError.write(
            "stratégie inconnue : \(strategyID)\nconnues : \(DefragPlanner.all.map(\.id).joined(separator: ", "))\n"
                .data(using: .utf8)!)
        exit(1)
    }
    if ProcessInfo.processInfo.environment["FULL_BLOCKS"] != nil {
        guard let full = DefragPlanner.withFullBlocks(found) else {
            FileHandle.standardError.write(
                "FULL_BLOCKS : \(strategyID) n'a pas l'option (windowsXP, ultraDefrag, jkDefrag…)\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        strategy = full
    } else {
        strategy = found
    }
} else {
    strategy = nil
}

let scenario: Scenario
var installed: InstalledDisk?
if let kind = ScenarioKind(rawValue: requested) {
    scenario = ScenarioBuilder.build(kind)
} else if let spec = (try? ScenarioLibrary.loadAll())?.first(where: { $0.id == profileID }) {
    FileHandle.standardError.write("génération de \(spec.id)…\n".data(using: .utf8)!)
    if wantsDay {
        FileHandle.standardError.write("rejeu jusqu'au jour \(requestedDay)…\n".data(using: .utf8)!)
        let replay = HistoryReplay(spec)
        if requestedDay > 0 { replay.skip(through: requestedDay - 1) }
        scenario = try ScenarioBuilder.build(day: requestedDay, replay: replay)
    } else if wantsInstall {
        let install = try DiskGenerator.install(spec)
        installed = install
        scenario = ScenarioBuilder.build(install: install)
    } else {
        let disk = try DiskGenerator.generate(spec)
        scenario = wantsBoot
            ? ScenarioBuilder.build(boot: disk)
            : try ScenarioBuilder.build(generated: disk, using: strategy)
    }
} else if requested.isEmpty {
    scenario = ScenarioBuilder.build(.windowsBoot)
} else {
    let known = ScenarioKind.allCases.map(\.rawValue) + ScenarioLibrary.identifiers
        + ScenarioLibrary.identifiers.map { "boot:\($0)" }
        + ScenarioLibrary.identifiers.map { "install:\($0)" }
        + ["day:<profil>:<jour>"]
    FileHandle.standardError.write(
        "scénario inconnu : \(requested)\nconnus : \(known.joined(separator: ", "))\n"
            .data(using: .utf8)!)
    exit(1)
}

// Une passe sur un volume d'époque réellement dimensionné dure des heures, et
// son rendu pèse des gigaoctets. `PLAN_ONLY` s'arrête au bilan : c'est tout ce
// qu'il faut pour vérifier un planificateur.
let planOnly = ProcessInfo.processInfo.environment["PLAN_ONLY"] != nil
let spindleGain = Float(ProcessInfo.processInfo.environment["SPINDLE_GAIN"] ?? "") ?? 0.32
let transientGain = Float(ProcessInfo.processInfo.environment["TRANSIENT_GAIN"] ?? "") ?? 1.0

// MARK: - Mixage au fil de l'eau

/// Le mixage du rendu d'un bloc, rejoué dans le même ordre d'opérations pour
/// que le WAV soit identique à l'échantillon près : la couche de rotation
/// d'abord, bloc de 512 par bloc de 512, puis chaque transitoire ajouté par
/// dessus dans l'ordre des repères.
///
/// Ce qui permet de le faire en flux, c'est la garde des repères : avant
/// `cueWatermark`, plus aucun repère n'apparaîtra. La rotation peut donc être
/// rendue jusque-là — les consignes de moteur qui la gouvernent sont toutes
/// connues — et un transitoire peut être posé dès que la rotation couvre toute
/// sa durée. Ce qui précède le premier transitoire en attente est définitif, et
/// part dans un fichier brut.
final class StreamingMixer {

    private static let block = 512

    private let spindle: SpindleVoice
    private let synth = SeekSynth(sampleRate: sampleRate)
    private var seekCache: [Int: AVAudioPCMBuffer] = [:]
    private var tickCache: [Int: AVAudioPCMBuffer] = [:]

    private var spinCues: [(time: Double, up: Bool, duration: Double)] = []
    private var spinIndex = 0
    /// Prochain échantillon de rotation à rendre.
    private var spindlePosition = 0
    private var transients: [(buffer: AVAudioPCMBuffer, start: Int)] = []
    private var transientHead = 0

    /// Fenêtre de travail : échantillons `base ..< base + left.count`.
    private var base = 0
    private var left: [Float] = []
    private var right: [Float] = []
    private var scratchL = [Float](repeating: 0, count: 512)
    private var scratchR = [Float](repeating: 0, count: 512)

    private var frameCount: Int?
    private let raw: FileHandle
    let rawPath: String
    private(set) var peak: Float = 0

    init(rpm: Double, rawPath: String) {
        spindle = SpindleVoice(sampleRate: sampleRate, rpm: rpm)
        self.rawPath = rawPath
        FileManager.default.createFile(atPath: rawPath, contents: nil)
        raw = FileHandle(forWritingAtPath: rawPath)!
    }

    func consume(_ batch: PassBatch) {
        for cue in batch.cues {
            switch cue.kind {
            case .spinUp(let d): spinCues.append((cue.time, true, d))
            case .spinDown(let d): spinCues.append((cue.time, false, d))
            case .seek(let profile, let travelMix):
                let bucket = min(Int(travelMix * 40), 39)
                let key = bucket * 4 + profile.distance % 4
                if seekCache[key] == nil {
                    seekCache[key] = synth.renderSeek(profile: profile, travelMix: travelMix,
                                                      variation: UInt32(key + 1))
                }
                if let buffer = seekCache[key] { schedule(buffer, at: cue.time) }
            case .chatter(let run, _):
                if let buffer = synth.renderChatter(
                    run: run, variation: UInt32(truncatingIfNeeded: run.count &* 7919)) {
                    schedule(buffer, at: cue.time)
                }
            case .tick(let kind):
                let key = kind == .headSwitch ? 0 : 1
                if tickCache[key] == nil {
                    tickCache[key] = synth.renderTick(kind, variation: UInt32(key + 1))
                }
                if let buffer = tickCache[key] { schedule(buffer, at: cue.time) }
            }
        }
        // Le rendu d'un bloc triait les consignes de moteur ; elles arrivent
        // ici déjà dans l'ordre, sauf une coupure qui tomberait avant la fin
        // du travail.
        if spinIndex < spinCues.count {
            spinCues[spinIndex...].sort { $0.time < $1.time }
        }

        if let end = batch.end {
            frameCount = Int(end.duration * sampleRate) + 48_000
        }
        renderSpindle(through: batch.cueWatermark)
        mixReadyTransients()
        flush(before: batch.cueWatermark)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, at time: Double) {
        transients.append((buffer, Int(time * sampleRate)))
    }

    private func ensure(upTo end: Int) {
        let needed = end - base
        if needed > left.count {
            left.append(contentsOf: repeatElement(0, count: needed - left.count))
            right.append(contentsOf: repeatElement(0, count: needed - right.count))
        }
    }

    private func renderSpindle(through watermark: Double) {
        let limit = frameCount ?? .max
        while spindlePosition < limit {
            let time = Double(spindlePosition) / sampleRate
            guard time < watermark else { break }
            while spinIndex < spinCues.count && spinCues[spinIndex].time <= time {
                let cue = spinCues[spinIndex]
                if cue.up { spindle.spinUp(duration: cue.duration) }
                else { spindle.spinDown(duration: cue.duration) }
                spinIndex += 1
            }
            let n = min(Self.block, limit - spindlePosition)
            ensure(upTo: spindlePosition + n)
            scratchL.withUnsafeMutableBufferPointer { l in
                scratchR.withUnsafeMutableBufferPointer { r in
                    spindle.render(left: l.baseAddress!, right: r.baseAddress!, count: n)
                }
            }
            let offset = spindlePosition - base
            for i in 0..<n {
                left[offset + i] += scratchL[i] * spindleGain
                right[offset + i] += scratchR[i] * spindleGain
            }
            spindlePosition += n
        }
    }

    private func mixReadyTransients() {
        while transientHead < transients.count {
            let (buffer, start) = transients[transientHead]
            let n = Int(buffer.frameLength)
            let complete = frameCount.map { spindlePosition >= $0 } ?? false
            guard complete || start + n <= spindlePosition else { break }
            guard let channels = buffer.floatChannelData else { transientHead += 1; continue }
            let limit = frameCount ?? .max
            ensure(upTo: min(start + n, limit))
            for i in 0..<n {
                let index = start + i
                guard index >= 0 && index < limit else { continue }
                left[index - base] += channels[0][i] * transientGain
                right[index - base] += channels[1][i] * transientGain
            }
            transientHead += 1
        }
        // Un train mixé libère son tampon tout de suite : chacun est rendu à
        // part, et peut peser quelques centaines de kilo-octets.
        if transientHead > 0 {
            transients.removeFirst(transientHead)
            transientHead = 0
        }
    }

    /// Écrit ce qui ne bougera plus : ce qui précède la garde — un repère à
    /// venir peut tomber dans le dernier bloc de rotation rendu — et le premier
    /// transitoire en attente.
    private func flush(before watermark: Double) {
        var safe = spindlePosition
        if watermark.isFinite { safe = min(safe, Int(watermark * sampleRate)) }
        if transientHead < transients.count { safe = min(safe, transients[transientHead].start) }
        if let frameCount, spindlePosition >= frameCount, transientHead == transients.count {
            safe = frameCount
        }
        let count = min(max(safe - base, 0), left.count)
        guard count > 0 else { return }

        var data = Data(count: count * 8)
        data.withUnsafeMutableBytes { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            for i in 0..<count {
                floats[2 * i] = left[i]
                floats[2 * i + 1] = right[i]
                peak = max(peak, max(abs(left[i]), abs(right[i])))
            }
        }
        autoreleasepool { raw.write(data) }
        left.removeFirst(count)
        right.removeFirst(count)
        base += count
    }

    func close() {
        try? raw.close()
    }
}

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
}

let tally = Tally()
let rawPath = outputPath + ".raw"
let mixer = planOnly ? nil : StreamingMixer(rpm: scenario.geometry.rpm, rawPath: rawPath)

guard let end = scenario.produce(batchRequests: 4_096, batchSeconds: 5, deliver: { batch in
    tally.consume(batch)
    mixer?.consume(batch)
}) else { exit(1) }
mixer?.close()

let geometry = scenario.geometry
let spans = scenario.spans(of: end)
let bucketCount = max(Int(ceil(end.duration / ScenarioBuilder.bucketDuration)), 1)
var throughput = [Double](repeating: 0, count: bucketCount)
for (index, bytes) in tally.bytes.enumerated() {
    throughput[min(index, bucketCount - 1)] += Double(bytes)
}
throughput = throughput.map { $0 / ScenarioBuilder.bucketDuration / 1_000_000 }

/// Ce que la passe a réellement fait : c'est le rapport entre déplacements et
/// évacuations qui explique la durée, bien plus que le volume de données.
func describe(_ plan: DefragPlan) -> String {
    let fullBlocks = ProcessInfo.processInfo.environment["FULL_BLOCKS"] != nil
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
    """
}

/// Ce qu'un démarrage a lu, et qui du processeur ou du disque l'a fait durer.
func describe(_ playback: BootPlayback, duration: Double) -> String {
    let disk = playback.diskSeconds(duration: duration)
    let total = playback.thinkSeconds + disk
    let share = total > 0 ? disk / total * 100 : 0
    return """
    système       : \(playback.osName)\(playback.appName.map { " puis \($0)" } ?? "")
    fichiers      : \(playback.filesRead) ouverts, \(playback.residentFiles) résidents
    calcul        : \(String(format: "%.1f", playback.thinkSeconds)) s
    disque        : \(String(format: "%.1f", disk)) s \
    (\(String(format: "%.0f", share)) % de l'attente)
    témoin        : \(String(format: "%.1f", playback.freshSeconds)) s jamais fragmenté, \
    soit \(String(format: "%+.0f", (duration / max(playback.freshSeconds, 0.001) - 1) * 100)) %
    """
}

/// Ce qu'une installation a posé, et ce qui l'a fait durer. Le décompte est
/// refait par le planificateur seul, sans simuler le disque : c'est lui qui sait
/// ce qu'ont coûté la source et les tables.
func describe(_ playback: InstallPlayback, installed: InstalledDisk, duration: Double) -> String {
    let rate = scenario.geometry.outerSustainedMBs * 1_000_000
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
func describe(_ playback: DayPlayback, duration: Double) -> String {
    let stats = end.stats
    return """
    journée       : jour \(playback.day), \(playback.date)
    activités     : \(playback.activities.isEmpty ? "aucune" : playback.activities.map(\.label).joined(separator: ", "))
    volume        : \(playback.disk.catalog.liveCount) fichiers, \
    \(Int(playback.disk.metrics.fill * 100)) % plein, \(playback.disk.metrics.fragmentedFileCount) fragmentés
    annoncé       : \(playback.bytes / 1_000_000) Mo à écrire
    lu / écrit    : \(stats.bytesRead / 1_000_000) / \(stats.bytesWritten / 1_000_000) Mo
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

FileHandle.standardError.write("""
scénario      : \(scenario.label.title) — \(geometry.model)
requêtes      : \(end.requestCount)
seeks         : \(end.stats.seekCount) (moy. \(end.stats.averageSeekDistance) cyl.)
lu / écrit    : \(end.stats.bytesRead / 1_000_000) / \(end.stats.bytesWritten / 1_000_000) Mo
événements    : \(end.eventCount)
repères audio : \(tally.cues)
durée         : \(String(format: "%.1f", end.duration)) s
\(end.plan.map(describe) ?? "")
\(scenario.boot.map { describe($0, duration: end.duration) } ?? "")
\(scenario.install.flatMap { playback in installed.map { describe(playback, installed: $0, duration: end.duration) } } ?? "")
\(scenario.dayPlayback.map { describe($0, duration: end.duration) } ?? "")
\(describePhases(spans, throughput: throughput))

""".data(using: .utf8)!)

guard let mixer else { exit(0) }

let frameCount = Int(end.duration * sampleRate) + 48_000

// MARK: - Mesures et écriture

/// Niveau de chaque phase, relu dans le fichier brut : les phases d'une passe
/// en boucle fermée ne sont datées qu'à la fin.
func report(_ label: String, _ range: Range<Int>, from file: FileHandle) {
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

let rawFile = FileHandle(forReadingAtPath: rawPath)!
for span in spans {
    report(span.label, Int(span.start * sampleRate)..<Int(span.end * sampleRate), from: rawFile)
}

let normalize: Float = mixer.peak > 0.99 ? 0.99 / mixer.peak : 1
if normalize < 1 {
    FileHandle.standardError.write("écrêtage évité, gain \(normalize)\n".data(using: .utf8)!)
}

// `AVAudioFile` ne finalise l'en-tête du WAV qu'à sa libération : l'écriture est
// donc confinée à une fonction, faute de quoi le fichier annonce zéro image.
func writeWAV(to path: String, from raw: FileHandle, gain: Float) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 2, interleaved: false)!
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path),
                               settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                          AVSampleRateKey: sampleRate,
                                          AVNumberOfChannelsKey: 2,
                                          AVLinearPCMBitDepthKey: 16,
                                          AVLinearPCMIsFloatKey: false])

    try raw.seek(toOffset: 0)
    let chunk = 48_000
    var written = 0
    while written < frameCount {
        let n = min(chunk, frameCount - written)
        try autoreleasepool {
            let data = raw.readData(ofLength: n * 8)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            data.withUnsafeBytes { bytes in
                let floats = bytes.bindMemory(to: Float.self)
                for i in 0..<n {
                    buffer.floatChannelData![0][i] = floats[2 * i] * gain
                    buffer.floatChannelData![1][i] = floats[2 * i + 1] * gain
                }
            }
            try file.write(from: buffer)
        }
        written += n
    }
}

try writeWAV(to: outputPath, from: rawFile, gain: normalize)
try? rawFile.close()
try? FileManager.default.removeItem(atPath: rawPath)

FileHandle.standardError.write("\nécrit : \(outputPath)\n".data(using: .utf8)!)
