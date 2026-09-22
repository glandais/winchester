import Foundation

/// Biquad RBJ en forme directe II transposée.
struct Biquad {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0
    private var z1: Double = 0
    private var z2: Double = 0

    mutating func reset() { z1 = 0; z2 = 0 }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// Recale un passe-bande **sans toucher à son état** : les coefficients
    /// changent, `z1` et `z2` restent. C'est ce qu'il faut à un filtre qui
    /// glisse — réaffecter `Biquad.bandpass(…)` le viderait à chaque fois, et
    /// un résonateur vidé plus vite qu'il ne s'établit ne sonne jamais.
    mutating func setBandpass(frequency: Double, q: Double, sampleRate: Double) {
        let tuned = Biquad.bandpass(frequency: frequency, q: q, sampleRate: sampleRate)
        b0 = tuned.b0; b1 = tuned.b1; b2 = tuned.b2
        a1 = tuned.a1; a2 = tuned.a2
    }

    /// Passe-bande à gain crête unitaire — la brique du banc de résonateurs.
    static func bandpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = alpha / a0
        f.b1 = 0
        f.b2 = -alpha / a0
        f.a1 = (-2 * cos(w0)) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    static func lowpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = ((1 - cosw) / 2) / a0
        f.b1 = (1 - cosw) / a0
        f.b2 = f.b0
        f.a1 = (-2 * cosw) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }

    static func highpass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = ((1 + cosw) / 2) / a0
        f.b1 = -(1 + cosw) / a0
        f.b2 = f.b0
        f.a1 = (-2 * cosw) / a0
        f.a2 = (1 - alpha) / a0
        return f
    }
}

/// Bruit blanc xorshift — rapide et sans allocation, utilisable dans un
/// callback de rendu temps réel.
struct NoiseSource {
    private var state: UInt32

    init(seed: UInt32 = 0x1234_5678) { state = seed | 1 }

    @inline(__always)
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(Int32(bitPattern: state)) / Double(Int32.max)
    }
}
