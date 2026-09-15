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
//   SPINDLE_GAIN=0 /tmp/rendertrace tete-seule.wav
//   TRANSIENT_GAIN=0 /tmp/rendertrace rotation-seule.wav
//
// Permet d'auditionner et de régler le synthé sans passer par le simulateur.

let sampleRate = 48_000.0
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "disknoise.wav"

let requested = ProcessInfo.processInfo.environment["SCENARIO"] ?? ""

let wantsBoot = requested.hasPrefix("boot:")
let profileID = wantsBoot ? String(requested.dropFirst(5)) : requested

let scenario: Scenario
if let kind = ScenarioKind(rawValue: requested) {
    scenario = ScenarioBuilder.build(kind)
} else if let spec = (try? ScenarioLibrary.loadAll())?.first(where: { $0.id == profileID }) {
    FileHandle.standardError.write("génération de \(spec.id)…\n".data(using: .utf8)!)
    let disk = try DiskGenerator.generate(spec)
    scenario = wantsBoot
        ? ScenarioBuilder.build(boot: disk)
        : try ScenarioBuilder.build(generated: disk)
} else if requested.isEmpty {
    scenario = ScenarioBuilder.build(.windowsBoot)
} else {
    let known = ScenarioKind.allCases.map(\.rawValue) + ScenarioLibrary.identifiers
        + ScenarioLibrary.identifiers.map { "boot:\($0)" }
    FileHandle.standardError.write(
        "scénario inconnu : \(requested)\nconnus : \(known.joined(separator: ", "))\n"
            .data(using: .utf8)!)
    exit(1)
}


/// Ce que la passe a réellement fait : c'est le rapport entre déplacements et
/// évacuations qui explique la durée, bien plus que le volume de données.
func describe(_ playback: DefragPlayback) -> String {
    let plan = playback.plan
    let moved = Double(plan.movedBytes) / 1_000_000
    return """
    outil         : \(plan.strategy.label)
    volume        : \(plan.partition.clusterCount) clusters de \(plan.partition.clusterBytes / 1_024) Ko, \
    \(plan.before.fileCount) fichiers, \(Int(plan.before.fill * 100)) % plein
    déplacements  : \(plan.filesMoved) fichiers, \(plan.evacuations) évacuations, \
    \(plan.filesAlreadyInPlace) déjà en place
    déplacé       : \(String(format: "%.0f", moved)) Mo pour un volume de \
    \(plan.partition.capacityBytes / 1_000_000) Mo
    fragmentés    : \(plan.before.fragmentedFiles) avant, \(plan.after.fragmentedFiles) après
    morceaux      : \(plan.before.fragments) avant, \(plan.after.fragments) après
    """
}

/// Ce qu'un démarrage a lu, et qui du processeur ou du disque l'a fait durer.
func describe(_ playback: BootPlayback, duration: Double) -> String {
    let total = playback.thinkSeconds + playback.diskSeconds
    let share = total > 0 ? playback.diskSeconds / total * 100 : 0
    return """
    système       : \(playback.osName)\(playback.appName.map { " puis \($0)" } ?? "")
    fichiers      : \(playback.filesRead) ouverts, \(playback.residentFiles) résidents
    calcul        : \(String(format: "%.1f", playback.thinkSeconds)) s
    disque        : \(String(format: "%.1f", playback.diskSeconds)) s \
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

let geometry = scenario.geometry
let spans = scenario.spans
let cues = scenario.cues
let trace = scenario.trace

FileHandle.standardError.write("""
scénario      : \(scenario.label.title) — \(geometry.model)
requêtes      : \(scenario.requestCount)
seeks         : \(trace.stats.seekCount) (moy. \(trace.stats.averageSeekDistance) cyl.)
lu / écrit    : \(trace.stats.bytesRead / 1_000_000) / \(trace.stats.bytesWritten / 1_000_000) Mo
événements    : \(trace.events.count)
repères audio : \(cues.count)
durée         : \(String(format: "%.1f", scenario.duration)) s
\(scenario.defrag.map(describe) ?? "")
\(scenario.boot.map { describe($0, duration: scenario.duration) } ?? "")
\(describePhases(spans, throughput: scenario.throughputMBs))

""".data(using: .utf8)!)

// Une passe sur un volume d'époque réellement dimensionné dure des heures, et
// son rendu pèse des gigaoctets. `PLAN_ONLY` s'arrête au bilan : c'est tout ce
// qu'il faut pour vérifier un planificateur.
if ProcessInfo.processInfo.environment["PLAN_ONLY"] != nil { exit(0) }

let frameCount = Int(scenario.duration * sampleRate) + 48_000
var left = [Float](repeating: 0, count: frameCount)
var right = [Float](repeating: 0, count: frameCount)

// 1. Couche continue, bloc par bloc, en appliquant les consignes de rotation.
let spindle = SpindleVoice(sampleRate: sampleRate, rpm: geometry.rpm)
let spindleGain = Float(ProcessInfo.processInfo.environment["SPINDLE_GAIN"] ?? "") ?? 0.32
var spinCues = cues.compactMap { cue -> (Double, Bool, Double)? in
    switch cue.kind {
    case .spinUp(let d): return (cue.time, true, d)
    case .spinDown(let d): return (cue.time, false, d)
    default: return nil
    }
}
spinCues.sort { $0.0 < $1.0 }

var spinIndex = 0
let block = 512
var scratchL = [Float](repeating: 0, count: block)
var scratchR = [Float](repeating: 0, count: block)
var position = 0
while position < frameCount {
    let time = Double(position) / sampleRate
    while spinIndex < spinCues.count && spinCues[spinIndex].0 <= time {
        let cue = spinCues[spinIndex]
        if cue.1 { spindle.spinUp(duration: cue.2) } else { spindle.spinDown(duration: cue.2) }
        spinIndex += 1
    }
    let n = min(block, frameCount - position)
    scratchL.withUnsafeMutableBufferPointer { l in
        scratchR.withUnsafeMutableBufferPointer { r in
            spindle.render(left: l.baseAddress!, right: r.baseAddress!, count: n)
        }
    }
    for i in 0..<n {
        left[position + i] += scratchL[i] * spindleGain
        right[position + i] += scratchR[i] * spindleGain
    }
    position += n
}

// 2. Transitoires, mixés à leur date exacte.
let synth = SeekSynth(sampleRate: sampleRate)
let transientGain = Float(ProcessInfo.processInfo.environment["TRANSIENT_GAIN"] ?? "") ?? 1.0
var seekCache: [Int: AVAudioPCMBuffer] = [:]
var tickCache: [Int: AVAudioPCMBuffer] = [:]

@MainActor
func mix(_ buffer: AVAudioPCMBuffer, at time: Double) {
    guard let channels = buffer.floatChannelData else { return }
    let start = Int(time * sampleRate)
    let n = Int(buffer.frameLength)
    for i in 0..<n {
        let index = start + i
        guard index >= 0 && index < frameCount else { continue }
        left[index] += channels[0][i] * transientGain
        right[index] += channels[1][i] * transientGain
    }
}

for cue in cues {
    switch cue.kind {
    case .seek(let profile, let travelMix):
        let bucket = min(Int(travelMix * 40), 39)
        let key = bucket * 4 + profile.distance % 4
        if seekCache[key] == nil {
            seekCache[key] = synth.renderSeek(profile: profile, travelMix: travelMix,
                                              variation: UInt32(key + 1))
        }
        if let buffer = seekCache[key] { mix(buffer, at: cue.time) }

    case .chatter(let run, _):
        if let buffer = synth.renderChatter(
            run: run, variation: UInt32(truncatingIfNeeded: run.count &* 7919)) {
            mix(buffer, at: cue.time)
        }

    case .tick(let kind):
        let key = kind == .headSwitch ? 0 : 1
        if tickCache[key] == nil {
            tickCache[key] = synth.renderTick(kind, variation: UInt32(key + 1))
        }
        if let buffer = tickCache[key] { mix(buffer, at: cue.time) }

    case .spinUp, .spinDown:
        break
    }
}

// 3. Mesures et écriture. Le code de premier niveau d'un `main.swift` est
// isolé sur l'acteur principal en Swift 6 : les fonctions qui lisent `left`,
// `right` et `frameCount` le sont donc aussi.
@MainActor
func report(_ label: String, _ range: Range<Int>) {
    var sum = 0.0
    var peak: Float = 0
    for i in range where i < frameCount {
        sum += Double(left[i] * left[i])
        peak = max(peak, abs(left[i]))
    }
    let rms = (sum / Double(range.count)).squareRoot()
    let db = rms > 0 ? 20 * log10(rms) : -Double.infinity
    let name = label.padding(toLength: 34, withPad: " ", startingAt: 0)
    let line = name + String(format: "RMS %7.1f dBFS   crête %.3f", db, peak) + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

for span in spans {
    report(span.label, Int(span.start * sampleRate)..<Int(span.end * sampleRate))
}

var peak: Float = 0
for i in 0..<frameCount { peak = max(peak, max(abs(left[i]), abs(right[i]))) }
let normalize: Float = peak > 0.99 ? 0.99 / peak : 1
if normalize < 1 {
    FileHandle.standardError.write("écrêtage évité, gain \(normalize)\n".data(using: .utf8)!)
}

// `AVAudioFile` ne finalise l'en-tête du WAV qu'à sa libération : l'écriture est
// donc confinée à une fonction, faute de quoi le fichier annonce zéro image.
@MainActor
func writeWAV(to path: String, gain: Float) throws {
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
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            buffer.floatChannelData![0][i] = left[written + i] * gain
            buffer.floatChannelData![1][i] = right[written + i] * gain
        }
        try file.write(from: buffer)
        written += n
    }
}

try writeWAV(to: outputPath, gain: normalize)

FileHandle.standardError.write("\nécrit : \(outputPath)\n".data(using: .utf8)!)
