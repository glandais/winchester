import Foundation

/// Générateur pseudo-aléatoire déterministe (SplitMix64) : la même graine
/// produit toujours la même trace, indispensable pour comparer deux réglages
/// audio sur exactement la même séquence d'I/O, et pour qu'un scénario de
/// génération de disque soit reproductible bit pour bit sur toutes les
/// plateformes.
///
/// Toutes les méthodes de tirage sont fournies ici plutôt que par les
/// extensions de la bibliothèque standard : `Int.random(in:)` sans générateur
/// explicite tire dans la source système et ruinerait le déterminisme, et les
/// surcharges `using:` de `Double.random` ne garantissent pas leur algorithme
/// d'une version de Swift à l'autre. Celles-ci le garantissent.
public struct SeededGenerator: RandomNumberGenerator, Sendable {

    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Tirages stables

    /// Flottant dans `[0, 1)`, construit à partir des 53 bits de poids fort :
    /// c'est exactement la précision d'un `Double`, et la conversion ne dépend
    /// d'aucun détail d'implémentation de la bibliothèque standard.
    public mutating func unitInterval() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2⁻⁵³
    }

    /// Entier dans `0..<bound`, sans biais (rejet de Lemire).
    public mutating func below(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0, "borne nulle")
        // Le reste de 2⁶⁴ modulo `bound` : les tirages qui tombent dedans sont
        // rejetés, faute de quoi les petites valeurs sortiraient plus souvent.
        let threshold = (0 &- bound) % bound
        while true {
            let r = next()
            if r >= threshold { return r % bound }
        }
    }

    /// Indice dans une collection de `count` éléments. Surcharge distincte
    /// plutôt qu'une deuxième `below` : deux `below` sur des entiers non
    /// signés rendent tout appel sur un littéral ambigu.
    public mutating func index(below count: Int) -> Int {
        precondition(count > 0, "collection vide")
        return Int(below(UInt64(count)))
    }

    /// Numéro de cluster dans `0..<bound`.
    public mutating func cluster(below bound: UInt32) -> UInt32 {
        UInt32(below(UInt64(bound)))
    }

    // MARK: - Tirages hérités
    //
    // Ces quatre méthodes délèguent à la bibliothèque standard. Elles sont
    // conservées **à l'identique** parce que le volume FAT16 vieilli et la
    // trace du scénario de démarrage sont calés dessus : en changer le corps
    // déplacerait chaque fichier du volume, et le rendu audio avec. Le noyau de
    // génération, lui, n'utilise que les tirages stables ci-dessus.

    public mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    public mutating func uniform(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    public mutating func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < p
    }

    /// Box-Muller, tronqué à ±3 σ pour éviter les valeurs aberrantes.
    public mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        let g = (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        return min(max(g, -3), 3)
    }

    /// Normale centrée réduite, tronquée à ±3 σ. Variante stable de
    /// `gaussian()`, bâtie sur `unitInterval()`.
    public mutating func normal() -> Double {
        let u1 = max(unitInterval(), 1e-12)
        let u2 = unitInterval()
        let g = (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        return min(max(g, -3), 3)
    }

    /// Log-normale de médiane `median` et d'écart-type `sigma` sur le logarithme.
    /// C'est la forme sous laquelle les tailles de fichiers sont décrites, par
    /// catégorie : la médiane est lisible, la moyenne ne l'est pas.
    public mutating func logNormal(median: Double, sigma: Double) -> Double {
        median * Foundation.exp(sigma * normal())
    }

    /// Choisit un élément selon des poids relatifs. Le tableau est ordonné,
    /// donc le tirage est reproductible — contrairement à une itération de
    /// `Dictionary`, dont l'ordre n'est stable ni entre exécutions ni entre
    /// plateformes.
    public mutating func pick(weights: [Double]) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var threshold = unitInterval() * total
        for (index, weight) in weights.enumerated() {
            threshold -= weight
            if threshold < 0 { return index }
        }
        return weights.count - 1
    }

    /// Mélange de Fisher-Yates, pour les séquences d'événements dont l'ordre
    /// compte mais ne doit pas être celui de leur construction.
    public mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            let j = Int(below(UInt64(i + 1)))
            if i != j { array.swapAt(i, j) }
        }
    }
}
