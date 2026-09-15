import Testing
@testable import DiskCore

@Suite("Générateur déterministe")
struct SeededGeneratorTests {

    @Test("Deux générateurs de même graine produisent la même suite")
    func determinism() {
        var a = SeededGenerator(seed: 0x5EED_1995)
        var b = SeededGenerator(seed: 0x5EED_1995)
        for _ in 0..<1_000 {
            #expect(a.next() == b.next())
        }
    }

    @Test("Deux graines voisines divergent immédiatement")
    func seedSeparation() {
        var a = SeededGenerator(seed: 41)
        var b = SeededGenerator(seed: 42)
        var identical = 0
        for _ in 0..<64 where a.next() == b.next() { identical += 1 }
        #expect(identical == 0)
    }

    /// La valeur attendue est figée ici : si une mise à jour de Swift ou une
    /// autre plateforme la changeait, chaque disque généré changerait avec
    /// elle, et le test le dirait tout de suite.
    @Test("La suite produite est stable dans le temps")
    func goldenValues() {
        var rng = SeededGenerator(seed: 0)
        let first = (0..<4).map { _ in rng.next() }
        // SplitMix64 avec un état initial déjà avancé d'un pas d'or : la suite
        // est celle de la référence, décalée d'un cran.
        #expect(first == [0x6E789E6AA1B965F4,
                          0x06C45D188009454F,
                          0xF88BB8A8724C81EC,
                          0x1B39896A51A8749B])
    }

    @Test("unitInterval reste dans [0, 1)")
    func unitIntervalRange() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<10_000 {
            let value = rng.unitInterval()
            #expect(value >= 0)
            #expect(value < 1)
        }
    }

    @Test("below respecte sa borne et couvre tout l'intervalle")
    func belowBounds() {
        var rng = SeededGenerator(seed: 11)
        var seen = Set<UInt64>()
        for _ in 0..<5_000 {
            let value = rng.below(UInt64(6))
            #expect(value < 6)
            seen.insert(value)
        }
        #expect(seen.count == 6)
    }

    /// Un biais grossier du tirage se verrait ici : sur 60 000 tirages à six
    /// faces, chaque face doit tomber autour de 10 000 fois.
    @Test("below n'est pas visiblement biaisé")
    func belowUniformity() {
        var rng = SeededGenerator(seed: 1_234)
        var counts = [Int](repeating: 0, count: 6)
        for _ in 0..<60_000 { counts[rng.index(below: 6)] += 1 }
        for count in counts {
            #expect(count > 9_400)
            #expect(count < 10_600)
        }
    }

    @Test("uniform(Int) couvre ses deux bornes incluses")
    func uniformClosedRange() {
        var rng = SeededGenerator(seed: 99)
        var low = false
        var high = false
        for _ in 0..<2_000 {
            let value = rng.uniform(3...7)
            #expect(value >= 3 && value <= 7)
            if value == 3 { low = true }
            if value == 7 { high = true }
        }
        #expect(low && high)
    }

    /// Médiane et dispersion d'une log-normale : c'est sous cette forme que les
    /// tailles de fichiers sont décrites par catégorie, la médiane étant la
    /// seule grandeur lisible d'une distribution aussi dissymétrique.
    @Test("logNormal retrouve sa médiane")
    func logNormalMedian() {
        var rng = SeededGenerator(seed: 2_003)
        var samples = (0..<20_000).map { _ in rng.logNormal(median: 80_000, sigma: 1.6) }
        samples.sort()
        let median = samples[samples.count / 2]
        #expect(median > 76_000)
        #expect(median < 84_000)
        // Dissymétrie : la moyenne d'une log-normale est très au-dessus de la
        // médiane. Si les deux se rejoignaient, la distribution serait lissée.
        let mean = samples.reduce(0, +) / Double(samples.count)
        #expect(mean > median * 1.5)
    }

    @Test("pick suit les poids donnés")
    func weightedPick() {
        var rng = SeededGenerator(seed: 5)
        var counts = [0, 0, 0]
        for _ in 0..<10_000 { counts[rng.pick(weights: [1, 3, 6])] += 1 }
        #expect(counts[0] > 800 && counts[0] < 1_200)
        #expect(counts[1] > 2_700 && counts[1] < 3_300)
        #expect(counts[2] > 5_600 && counts[2] < 6_400)
    }

    @Test("shuffle est une permutation, et elle est reproductible")
    func shuffleIsDeterministic() {
        var a = SeededGenerator(seed: 77)
        var b = SeededGenerator(seed: 77)
        var first = Array(0..<50)
        var second = first
        a.shuffle(&first)
        b.shuffle(&second)
        #expect(first == second)
        #expect(first.sorted() == Array(0..<50))
        #expect(first != Array(0..<50))
    }
}
