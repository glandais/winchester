import Foundation

/// Décomposition mécanique d'un seek en quatre phases.
///
/// Ruemmler & Wilkes, « An introduction to disk drive modeling », IEEE Computer
/// 27(3), 1994 : un déplacement de tête se décompose en *speedup*, *coast*
/// (seeks longs uniquement), *slowdown* et *settle*. Les seeks très courts sont
/// dominés par le settle et n'ont pas de phase de coast du tout — c'est ce qui
/// justifie de faire varier la **forme** de l'enveloppe avec la distance, et pas
/// seulement son amplitude.
public struct SeekProfile: Sendable {
    public let distance: Int
    public let speedup: Double
    public let coast: Double
    public let slowdown: Double
    public let settle: Double

    public init(distance: Int, speedup: Double, coast: Double, slowdown: Double, settle: Double) {
        self.distance = distance
        self.speedup = speedup
        self.coast = coast
        self.slowdown = slowdown
        self.settle = settle
    }

    public var total: Double { speedup + coast + slowdown + settle }
    public var hasCoast: Bool { coast > 1e-6 }
}

/// Loi de durée de seek à deux régimes.
///
/// Forme retenue de Ruemmler & Wilkes : `a + b·√d` pour les seeks courts,
/// `c + e·d` au-delà d'un cylindre de croisement. Les constantes publiées
/// (HP C2200A : 3,45 + 0,597·√d / 10,8 + 0,012·d) valent pour des disques HP
/// des années 90 ; **la forme fonctionnelle se généralise, pas les constantes**.
/// Celles-ci sont recalibrées pour un disque de 2001 : ~1,1 ms piste-à-piste,
/// ~8,7 ms en seek moyen (1/3 de course), ~18 ms en pleine course.
public struct SeekModel: Sendable {

    public let shortIntercept: Double     // ms
    public let shortSqrtCoefficient: Double
    public let longIntercept: Double      // ms
    public let longLinearCoefficient: Double
    public let crossover: Int             // cylindres

    /// Durée du repositionnement fin sous asservissement, en fin de seek.
    public let settleDuration: Double     // s
    /// Durée max d'une phase d'accélération ou de décélération.
    public let accelerationCap: Double    // s
    /// Commutation de tête sans déplacement de bras.
    public let headSwitchDuration: Double // s

    public init(shortIntercept: Double,
                shortSqrtCoefficient: Double,
                longIntercept: Double,
                longLinearCoefficient: Double,
                crossover: Int,
                settleDuration: Double,
                accelerationCap: Double,
                headSwitchDuration: Double) {
        self.shortIntercept = shortIntercept
        self.shortSqrtCoefficient = shortSqrtCoefficient
        self.longIntercept = longIntercept
        self.longLinearCoefficient = longLinearCoefficient
        self.crossover = crossover
        self.settleDuration = settleDuration
        self.accelerationCap = accelerationCap
        self.headSwitchDuration = headSwitchDuration
    }

    public static let defaultModel = SeekModel(
        shortIntercept: 1.00,
        shortSqrtCoefficient: 0.140,
        longIntercept: 4.00,
        longLinearCoefficient: 0.000_583,
        crossover: 600,
        settleDuration: 0.000_6,
        accelerationCap: 0.002_6,
        headSwitchDuration: 0.000_9
    )

    /// Durée totale du seek, en secondes.
    public func duration(distance: Int) -> Double {
        let d = abs(distance)
        guard d > 0 else { return 0 }
        let ms: Double
        if d < crossover {
            ms = shortIntercept + shortSqrtCoefficient * Double(d).squareRoot()
        } else {
            ms = longIntercept + longLinearCoefficient * Double(d)
        }
        return ms / 1000.0
    }

    public func profile(distance: Int) -> SeekProfile {
        let d = abs(distance)
        let total = duration(distance: d)
        guard total > 0 else {
            return SeekProfile(distance: 0, speedup: 0, coast: 0, slowdown: 0, settle: 0)
        }

        let settle = min(settleDuration, total * 0.5)
        let moving = total - settle

        // Un seek court n'atteint jamais sa vitesse de croisière : accélération
        // puis décélération immédiate, sans plateau.
        if moving <= 2 * accelerationCap {
            let half = moving / 2
            return SeekProfile(distance: d, speedup: half, coast: 0, slowdown: half, settle: settle)
        }

        let coast = moving - 2 * accelerationCap
        return SeekProfile(
            distance: d,
            speedup: accelerationCap,
            coast: coast,
            slowdown: accelerationCap,
            settle: settle
        )
    }

    /// Position normalisée de la distance dans la course du disque, utilisée
    /// pour doser l'excitation des modes de l'actionneur.
    public func travelMix(distance: Int, cylinders: Int) -> Double {
        let f = Double(abs(distance)) / Double(max(cylinders - 1, 1))
        return min(max(f, 0), 1)
    }
}

extension SeekModel {

    /// Recalibrage pour le disque de 1996 : 3,0 ms piste-à-piste, ~12 ms en
    /// seek moyen (1/3 de course), 22 ms en pleine course. Le bras est plus
    /// lourd et l'asservissement plus lent qu'en 2001 — d'où un settle deux
    /// fois plus long, qui s'entend : chaque arrêt « traîne ».
    public static let win95Model = SeekModel(
        shortIntercept: 2.60,
        shortSqrtCoefficient: 0.400,
        longIntercept: 7.29,
        longLinearCoefficient: 0.007_35,
        crossover: 300,
        settleDuration: 0.001_2,
        accelerationCap: 0.004_0,
        headSwitchDuration: 0.002_0
    )
}
