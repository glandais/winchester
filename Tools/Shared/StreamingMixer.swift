import Foundation
import AVFAudio

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
    private let synth: SeekSynth
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
    private let raw: FileHandle?
    private let spindleGain: Float
    private let transientGain: Float
    private(set) var peak: Float = 0
    /// Échantillons définitifs, entrelacés gauche-droite, à partir de l'indice
    /// donné. C'est par là que la vidéo accélérée prélève ses extraits sans
    /// garder la passe entière.
    var onFlush: ((_ start: Int, _ interleaved: UnsafeBufferPointer<Float>) -> Void)?

    /// - Parameter rawPath: fichier brut où écrire le mixage, ou `nil` pour ne
    ///   rien écrire et tout confier à `onFlush`.
    init(character: SpindleCharacter, seek: SeekCharacter, rawPath: String?, spindleGain: Float = 0.20,
         transientGain: Float = 1.0) {
        spindle = SpindleVoice(sampleRate: sampleRate, character: character)
        synth = SeekSynth(sampleRate: sampleRate, headGain: seek.gain)
        self.spindleGain = spindleGain
        self.transientGain = transientGain
        if let rawPath {
            FileManager.default.createFile(atPath: rawPath, contents: nil)
            raw = FileHandle(forWritingAtPath: rawPath)!
        } else {
            raw = nil
        }
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
            case .tickTrain(let ticks, _):
                if let buffer = synth.renderTickTrain(
                    ticks, variation: UInt32(truncatingIfNeeded: ticks.count &* 7919)) {
                    schedule(buffer, at: cue.time)
                }
            case .unstick:
                if tickCache[2] == nil { tickCache[2] = synth.renderUnstick(variation: 3) }
                if let buffer = tickCache[2] { schedule(buffer, at: cue.time) }
            case .landing:
                if tickCache[3] == nil { tickCache[3] = synth.renderLanding(variation: 4) }
                if let buffer = tickCache[3] { schedule(buffer, at: cue.time) }
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
        if let onFlush {
            data.withUnsafeBytes { bytes in
                onFlush(base, bytes.bindMemory(to: Float.self))
            }
        }
        autoreleasepool { raw?.write(data) }
        left.removeFirst(count)
        right.removeFirst(count)
        base += count
    }

    func close() {
        try? raw?.close()
    }
}
