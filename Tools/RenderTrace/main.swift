import Foundation
import AVFAudio

// Rendu hors-ligne de la trace complète dans un WAV.
//
//   swiftc -O -o /tmp/rendertrace \
//       Sources/Model/DriveGeometry.swift Sources/Model/SeekModel.swift \
//       Sources/Model/Workload.swift Sources/Model/DiskSimulator.swift \
//       Sources/Audio/Biquad.swift Sources/Audio/SeekSynth.swift \
//       Sources/Audio/SpindleVoice.swift Sources/Audio/AudioCue.swift \
//       Tools/RenderTrace.swift
//   /tmp/rendertrace sortie.wav
//
// Permet d'auditionner et de régler le synthé sans passer par le simulateur.

let sampleRate = 48_000.0
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "disknoise.wav"

let geometry = DriveGeometry.defaultDrive
let seekModel = SeekModel.defaultModel
let phases = WorkloadLibrary.windowsBootAndOffice

let generator = WorkloadGenerator(geometry: geometry)
let (requests, spans) = generator.generate(phases: phases)
let total = spans.last?.end ?? 0
let spinUpDuration = (phases.first?.duration ?? 6) - 0.6

let trace = DiskSimulator.run(geometry: geometry, seekModel: seekModel,
                              requests: requests, totalDuration: total,
                              spinUpAt: 0.35, spinUpDuration: spinUpDuration)
let cues = AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders)

FileHandle.standardError.write("""
requêtes      : \(requests.count)
seeks         : \(trace.stats.seekCount) (moy. \(trace.stats.averageSeekDistance) cyl.)
événements    : \(trace.events.count)
repères audio : \(cues.count)
durée         : \(String(format: "%.1f", trace.duration)) s

""".data(using: .utf8)!)

let frameCount = Int(trace.duration * sampleRate) + 48_000
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

// 3. Mesures et écriture.
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
    report(span.phase.label, Int(span.start * sampleRate)..<Int(span.end * sampleRate))
}

var peak: Float = 0
for i in 0..<frameCount { peak = max(peak, max(abs(left[i]), abs(right[i]))) }
let normalize: Float = peak > 0.99 ? 0.99 / peak : 1
if normalize < 1 {
    FileHandle.standardError.write("écrêtage évité, gain \(normalize)\n".data(using: .utf8)!)
}

// `AVAudioFile` ne finalise l'en-tête du WAV qu'à sa libération : l'écriture est
// donc confinée à une fonction, faute de quoi le fichier annonce zéro image.
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
