import Foundation

/// Le son d'une vidéo accélérée : des extraits réels de la passe, enchaînés en
/// fondu.
///
/// Accélérer le son lui-même le dénaturerait — un seek de trente millisecondes
/// deviendrait un clic, la rotation monterait de plusieurs octaves. On garde
/// donc le son tel qu'il est, par morceaux : la vidéo en dure `snippet`
/// secondes par morceau, et chaque morceau fait entendre la passe **au milieu**
/// de ce que l'image montre pendant ce temps-là.
///
/// Les fenêtres ne dépendent que de leur rang, pas de la durée de la passe,
/// encore inconnue : chacune se remplit à mesure que le mixeur livre le son, et
/// rien d'autre que les extraits n'est gardé.
final class AudioSnippets {

    let speed: Double
    /// Durée d'un extrait dans la vidéo, fondus exclus.
    let snippet: Double
    /// Durée du fondu enchaîné entre deux extraits.
    let crossfade: Double

    private var windows: [[Float]] = []
    private let windowFrames: Int

    init(speed: Double, snippet: Double = 4, crossfade: Double = 0.6) {
        self.speed = speed
        self.snippet = snippet
        self.crossfade = crossfade
        windowFrames = Int((snippet + crossfade) * sampleRate)
    }

    /// Premier échantillon source de l'extrait `k`.
    private func sourceStart(_ k: Int) -> Int {
        let center = (Double(k) + 0.5) * snippet * speed
        return max(Int((center - (snippet + crossfade) / 2) * sampleRate), 0)
    }

    /// Ce que le mixeur vient de rendre définitif.
    func consume(start: Int, interleaved: UnsafeBufferPointer<Float>) {
        let count = interleaved.count / 2
        let end = start + count
        var k = 0
        // Les extraits sont rangés dans l'ordre ; on ne regarde que ceux qui
        // peuvent recouvrir le morceau livré.
        let spacing = snippet * speed * sampleRate
        if spacing > 0 {
            k = max(Int((Double(start) - Double(windowFrames)) / spacing) - 1, 0)
        }
        while sourceStart(k) < end {
            let windowStart = sourceStart(k)
            let windowEnd = windowStart + windowFrames
            if windowEnd > start {
                while windows.count <= k { windows.append([]) }
                if windows[k].isEmpty { windows[k] = [Float](repeating: 0, count: windowFrames * 2) }
                let from = max(start, windowStart)
                let to = min(end, windowEnd)
                windows[k].withUnsafeMutableBufferPointer { window in
                    for i in from..<to {
                        window[2 * (i - windowStart)] = interleaved[2 * (i - start)]
                        window[2 * (i - windowStart) + 1] = interleaved[2 * (i - start) + 1]
                    }
                }
            }
            k += 1
        }
    }

    /// Le son de la vidéo, entrelacé, sur `passSeconds` de vidéo.
    ///
    /// L'extrait `k` occupe `[k·snippet − fondu/2, (k+1)·snippet + fondu/2]`, et
    /// deux extraits voisins se recouvrent le temps du fondu, à puissance
    /// constante.
    func mix(passSeconds: Double) -> [Float] {
        let total = Int(passSeconds * sampleRate)
        var output = [Float](repeating: 0, count: total * 2)
        let fade = Int(crossfade * sampleRate)
        let count = Int(ceil(passSeconds / snippet))
        for k in 0..<min(count, windows.count) where !windows[k].isEmpty {
            let placed = Int((Double(k) * snippet - crossfade / 2) * sampleRate)
            let window = windows[k]
            for i in 0..<windowFrames {
                let index = placed + i
                guard index >= 0 else { continue }
                guard index < total else { break }
                var gain: Float = 1
                if i < fade && k > 0 {
                    gain = Float(sin(Double(i) / Double(fade) * .pi / 2))
                } else if i >= windowFrames - fade {
                    gain = Float(cos(Double(i - (windowFrames - fade)) / Double(fade) * .pi / 2))
                }
                output[2 * index] += window[2 * i] * gain
                output[2 * index + 1] += window[2 * i + 1] * gain
            }
        }
        // Le dernier extrait s'arrête avec la passe : un court fondu évite le
        // clic d'une coupure franche.
        let tail = min(Int(0.05 * sampleRate), total)
        for i in 0..<tail {
            let gain = Float(i) / Float(max(tail, 1))
            output[2 * (total - 1 - i)] *= gain
            output[2 * (total - 1 - i) + 1] *= gain
        }
        return output
    }
}
