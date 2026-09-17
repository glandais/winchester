import Foundation
import DiskCore
import AVFAudio

// Rendu hors-ligne d'une passe en vidéo : l'image et le son sortent de la même
// simulation, sur la même horloge.
//
//   ./Tools/build-render.sh
//   SCENARIO=windowsBoot /tmp/rendervideo demarrage.mp4
//   SCENARIO=defrag SPEED=4 /tmp/rendervideo defrag-x4.mp4
//   SCENARIO=defrag LAYOUT=short FIT_SECONDS=58 /tmp/rendervideo defrag-short.mp4
//   SCENARIO=install:secretaire-1996 /tmp/rendervideo installation.mp4
//   SCENARIO=day:dev-1996:120 /tmp/rendervideo jour120.mp4
//
// `SCENARIO`, `STRATEGY` et `FULL_BLOCKS` se lisent comme pour `RenderTrace`.
//
//   LAYOUT       landscape (1920 × 1080, défaut) ou short (1080 × 1920)
//   FPS          images par seconde (30)
//   SPEED        accélération de la passe (1) ; au-delà de 1, le son est fait
//                d'extraits réels enchaînés en fondu
//   FIT_SECONDS  la passe doit tenir en tant de secondes : la vitesse s'en
//                déduit, après une planification à blanc qui mesure la durée
//   MAX_SECONDS  coupe la vidéo après tant de secondes de passe (essais)
//   END_CARD     durée du bilan final, en secondes (8)
//   SNIPPET      durée d'un extrait sonore en vidéo accélérée (4)
//   ENCODER      videotoolbox (défaut) ou x264, plus lent et plus fin
//   KEEP_WAV     garde le WAV à côté de la vidéo
//
// Tout est en flux : les images partent dans `ffmpeg` à mesure que la passe se
// planifie, et une passe de plusieurs heures ne tient jamais en mémoire.

func say(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

let environment = ScenarioRequest.environment
guard CommandLine.arguments.count > 1 else {
    ScenarioRequest.fail("usage : SCENARIO=<id> rendervideo sortie.mp4")
}
let outputPath = CommandLine.arguments[1]
guard let layout = VideoLayout(rawValue: environment["LAYOUT"] ?? "landscape") else {
    ScenarioRequest.fail("LAYOUT : landscape ou short")
}
let fps = Double(environment["FPS"] ?? "") ?? 30
let maxSeconds = Double(environment["MAX_SECONDS"] ?? "")
let endCard = Double(environment["END_CARD"] ?? "") ?? 8
let snippet = Double(environment["SNIPPET"] ?? "") ?? 4

var speed = max(Double(environment["SPEED"] ?? "") ?? 1, 1)
if let fit = Double(environment["FIT_SECONDS"] ?? "") {
    // La durée d'une passe en boucle fermée n'est connue qu'à la fin : on la
    // planifie une première fois sans image ni son, ce qui ne coûte que le
    // temps de la simulation.
    say("mesure de la durée…")
    guard let end = try ScenarioRequest.scenario().produce(batchRequests: 4_096, batchSeconds: 5,
                                                          deliver: { _ in }) else { exit(1) }
    speed = max(end.duration / fit, 1)
    say(String(format: "durée %.1f s, vitesse ×%.2f", end.duration, speed))
}

let request = try ScenarioRequest.request()
let scenario = request.scenario

// MARK: - Encodage

/// `ffmpeg`, nourri d'images brutes sur son entrée standard.
final class VideoEncoder {
    private let process = Process()
    private let pipe = Pipe()

    init(path: String, width: Int, height: Int, fps: Double) throws {
        let codec: [String]
        switch environment["ENCODER"] ?? "videotoolbox" {
        case "x264":
            codec = ["-c:v", "libx264", "-preset", "medium", "-crf", "16", "-tune", "animation"]
        default:
            // Le débit que YouTube recommande pour du 1080p à 30 images, avec
            // de la marge : une carte de blocs se compresse mal.
            codec = ["-c:v", "h264_videotoolbox", "-b:v", "16M", "-profile:v", "high"]
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                             "-f", "rawvideo", "-pix_fmt", "rgba",
                             "-s", "\(width)x\(height)", "-r", String(fps), "-i", "-",
                             "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"]
            + codec
            + ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
               "-r", String(fps), path]
        process.standardInput = pipe
        try process.run()
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        pipe.fileHandleForWriting.write(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                                             count: bytes.count, deallocator: .none))
    }

    func finish() -> Bool {
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

func run(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

// MARK: - La passe

let composer = FrameComposer(layout: layout, scenario: scenario, speed: speed, fps: fps)
let live = LivePass(session: nil,
                    geometry: scenario.geometry,
                    seekModel: scenario.seekModel,
                    spindle: scenario.setup.spindle,
                    phases: scenario.phases,
                    map: scenario.map.map { ($0.partition.clusterCount, $0.initialRuns) })
if let grid = composer.mapGrid { live.map?.setGrid(grid) }

let work = outputPath + ".work"
let videoPath = work + ".mp4"
let rawPath = work + ".raw"
let wavPath = (environment["KEEP_WAV"] != nil) ? (outputPath as NSString).deletingPathExtension + ".wav"
    : work + ".wav"

let size = layout.size
let encoder = try VideoEncoder(path: videoPath, width: size.width, height: size.height, fps: fps)

let accelerated = speed > 1
let finalSpeed = speed
let snippets = accelerated ? AudioSnippets(speed: speed, snippet: snippet) : nil
let mixer = StreamingMixer(rpm: scenario.geometry.rpm, rawPath: accelerated ? nil : rawPath)
if let snippets {
    mixer.onFlush = { start, samples in snippets.consume(start: start, interleaved: samples) }
}

/// Ce qui avance à mesure que la passe se produit : les images déjà rendues.
final class Renderer {
    let speed: Double
    let fps: Double
    let maxFrames: Int?
    let live: LivePass
    let composer: FrameComposer
    let encoder: VideoEncoder
    let mixer: StreamingMixer
    let tally = Tally()
    var frameIndex = 0
    var capped = false
    private let started = Date()
    private var lastLog = Date()

    init(speed: Double, fps: Double, maxFrames: Int?, live: LivePass, composer: FrameComposer,
         encoder: VideoEncoder, mixer: StreamingMixer) {
        self.speed = speed
        self.fps = fps
        self.maxFrames = maxFrames
        self.live = live
        self.composer = composer
        self.encoder = encoder
        self.mixer = mixer
    }

    func say(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    func consume(_ batch: PassBatch) {
        tally.consume(batch)
        mixer.consume(batch)
        live.absorb(batch)
        renderFrames(through: batch.clock)
    }

    /// Rend toutes les images dont l'instant est couvert par la passe produite.
    func renderFrames(through clock: Double) {
        while true {
            if let maxFrames, frameIndex >= maxFrames { capped = true; return }
            let time = Double(frameIndex) / fps * speed
            guard time <= clock else { return }
            live.advance(to: time)
            composer.draw(live, at: time)
            encoder.write(composer.canvas.bytes)
            frameIndex += 1
            if Date().timeIntervalSince(lastLog) > 10 {
                lastLog = Date()
                let rate = Double(frameIndex) / Date().timeIntervalSince(started)
                say(String(format: "  %@ de passe, %d images (%.0f/s)", French.clock(time), frameIndex, rate))
            }
        }
    }

    var elapsed: Double { Date().timeIntervalSince(started) }
}

let renderer = Renderer(speed: speed, fps: fps, maxFrames: maxSeconds.map { Int($0 * fps) },
                        live: live, composer: composer, encoder: encoder, mixer: mixer)

let end = scenario.produce(batchRequests: 4_096, batchSeconds: 5,
                           isCancelled: { renderer.capped },
                           deliver: { renderer.consume($0) })
mixer.close()

if let end {
    renderer.renderFrames(through: end.duration)
}
var frameIndex = renderer.frameIndex
let capped = renderer.capped
let passFrames = frameIndex
let passSeconds = Double(passFrames) / fps

// MARK: - Bilan

if let end, !capped, endCard > 0 {
    let background = [UInt8](composer.canvas.bytes)
    var lines: [String] = []
    if let plan = end.plan {
        lines = describe(plan).components(separatedBy: "\n")
    } else if let boot = scenario.boot {
        lines = describe(boot, duration: end.duration).components(separatedBy: "\n")
    } else if let install = scenario.install, let installed = request.installed {
        lines = describe(install, installed: installed, geometry: scenario.geometry,
                         duration: end.duration).components(separatedBy: "\n")
    } else if let day = scenario.dayPlayback {
        lines = describe(day, stats: end.stats, duration: end.duration).components(separatedBy: "\n")
    }
    lines += [
        "durée         : \(French.clock(end.duration))",
        "seeks         : \(French.integer(end.stats.seekCount)) (moy. \(end.stats.averageSeekDistance) cyl.)",
        "lu / écrit    : \(end.stats.bytesRead / 1_000_000) / \(end.stats.bytesWritten / 1_000_000) Mo",
    ]
    let cardFrames = Int(endCard * fps)
    background.withUnsafeBytes { background in
        for index in 0..<cardFrames {
            composer.drawSummary(over: background, title: "Bilan — \(scenario.label.title)", lines: lines,
                                 fade: Double(index) / (0.6 * fps))
            encoder.write(composer.canvas.bytes)
        }
    }
    frameIndex += cardFrames
}

guard encoder.finish() else { ScenarioRequest.fail("ffmpeg a échoué sur la vidéo") }

// MARK: - Son

let videoFrames = Int(Double(frameIndex) / fps * sampleRate)
if let snippets {
    var audio = snippets.mix(passSeconds: passSeconds)
    let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
    let gain: Float = peak > 0.99 ? 0.99 / peak : 1
    var offset = 0
    try audio.withUnsafeMutableBytes { bytes in
        try writeWAV(to: wavPath, frameCount: videoFrames, gain: gain) { count in
            let available = max(min(count * 8, bytes.count - offset), 0)
            let data = Data(bytes: bytes.baseAddress! + offset, count: available)
            offset += available
            return data
        }
    }
    audio = []
} else {
    let normalize: Float = mixer.peak > 0.99 ? 0.99 / mixer.peak : 1
    let raw = FileHandle(forReadingAtPath: rawPath)!
    try writeWAV(to: wavPath, from: raw, frameCount: videoFrames, gain: normalize)
    try? raw.close()
    try? FileManager.default.removeItem(atPath: rawPath)
}

// MARK: - Assemblage

guard run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-i", videoPath, "-i", wavPath,
           "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k",
           "-movflags", "+faststart", outputPath]) else {
    ScenarioRequest.fail("ffmpeg a échoué à l'assemblage")
}
try? FileManager.default.removeItem(atPath: videoPath)
if environment["KEEP_WAV"] == nil { try? FileManager.default.removeItem(atPath: wavPath) }

let elapsed = renderer.elapsed
say(String(format: "écrit : %@ — %@ de vidéo (passe ×%@), rendu en %.0f s",
           outputPath, French.clock(Double(frameIndex) / fps), FrameComposer.speedLabel(speed), elapsed))
