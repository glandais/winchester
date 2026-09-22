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

    /// La loi d'un seek **d'écriture**, quand la fiche la publie.
    ///
    /// Écrire exige une tête mieux posée que lire : une écriture décalée
    /// détruirait la piste voisine, et l'asservissement attend que l'erreur de
    /// position tombe sous un seuil plus serré avant d'autoriser le courant
    /// d'écriture. Le bras ne va pas plus vite ; c'est le repositionnement
    /// final qui dure plus. Les manuels le publient par deux durées de plus :
    /// seek moyen et piste-à-piste « write », une à deux millisecondes au-dessus
    /// de celles de lecture (`DriveReference.writeSeek`). L'excédent de cette
    /// loi sur celle de lecture, distance par distance, s'ajoute au settle.
    public var writeLaw: WriteSeekLaw?

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

    /// Durée d'un seek qui précède une écriture : celle d'une lecture, plus
    /// le settle plus long qu'exige la tête avant d'écrire.
    public func duration(distance: Int, isWrite: Bool) -> Double {
        duration(distance: distance) + (isWrite ? writeSettleExtra(distance: distance) : 0)
    }

    /// Ce que le settle d'une écriture dure de plus que celui d'une lecture.
    public func writeSettleExtra(distance: Int) -> Double {
        guard let writeLaw, distance != 0 else { return 0 }
        return max(writeLaw.duration(distance: distance, crossover: crossover)
                   - duration(distance: distance), 0)
    }

    public func profile(distance: Int, isWrite: Bool) -> SeekProfile {
        let read = profile(distance: distance)
        guard isWrite else { return read }
        return SeekProfile(distance: read.distance, speedup: read.speedup, coast: read.coast,
                           slowdown: read.slowdown,
                           settle: read.settle + writeSettleExtra(distance: distance))
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

/// Les constantes d'une loi de seek d'écriture : les deux branches de
/// `SeekModel`, au même cylindre de croisement que la loi de lecture dont elle
/// dérive.
public struct WriteSeekLaw: Sendable, Equatable {
    public let shortIntercept: Double
    public let shortSqrtCoefficient: Double
    public let longIntercept: Double
    public let longLinearCoefficient: Double

    func duration(distance: Int, crossover: Int) -> Double {
        let d = abs(distance)
        guard d > 0 else { return 0 }
        let ms = d < crossover
            ? shortIntercept + shortSqrtCoefficient * Double(d).squareRoot()
            : longIntercept + longLinearCoefficient * Double(d)
        return ms / 1000.0
    }
}

extension SeekModel {

    /// La même loi, avec le seek d'écriture que publie la fiche.
    ///
    /// La loi d'écriture est calée comme celle de lecture, sur les deux durées
    /// « write » de la fiche, et sur la même course. Les deux ne diffèrent
    /// que par leurs constantes : le croisement des branches est celui de la
    /// course, pas celui de la fiche.
    public func withWriteSeek(averageSeekMs: Double, trackToTrackMs: Double,
                              fullStrokeMs: Double? = nil,
                              cylinders: Int) -> SeekModel {
        let write = SeekModel.calibrated(averageSeekMs: averageSeekMs,
                                         trackToTrackMs: trackToTrackMs,
                                         fullStrokeMs: fullStrokeMs,
                                         cylinders: cylinders)
        var model = self
        guard write.crossover == crossover else { return model }
        model.writeLaw = WriteSeekLaw(shortIntercept: write.shortIntercept,
                                      shortSqrtCoefficient: write.shortSqrtCoefficient,
                                      longIntercept: write.longIntercept,
                                      longLinearCoefficient: write.longLinearCoefficient)
        return model
    }
}

extension SeekModel {

    /// La **forme** dont dérivent toutes les lois de seek du projet.
    ///
    /// Ses constantes ont été calées sur un disque de 1996 de deux mille
    /// cylindres : 3,0 ms piste-à-piste, ~12 ms en seek moyen (un tiers de
    /// course), 22 ms en pleine course. Ce qui s'en généralise, ce sont les
    /// **rapports** entre ces trois durées et le découpage en quatre phases —
    /// pas les valeurs, que `calibrated` recale sur la fiche du disque décrit.
    ///
    /// C'est donc une constante de la loi et non un disque : elle ne doit pas
    /// suivre les disques des scénarios, sans quoi toutes les lois dérivées se
    /// décaleraient avec eux.
    public static let referenceShape = SeekModel(
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

extension SeekModel {

    /// Course sur laquelle `referenceShape` a été calée : deux mille
    /// cylindres. C'est une constante de la **loi**, pas un disque — elle doit
    /// rester fixe même si les disques des scénarios changent, sans quoi toutes
    /// les lois dérivées se décaleraient avec eux.
    static let referenceCylinders = 2_000

    /// Durée d'un seek moyen, en millisecondes : **l'espérance** de la durée
    /// d'un seek entre deux cylindres tirés au hasard, ce que les manuels
    /// mesurent (« a true statistical random average of at least 5,000
    /// measurements of seeks between random tracks », Seagate U8, §1.5). La
    /// distance entre deux cylindres uniformes a pour loi 2(N − d)/N² ; ce
    /// n'est pas le tiers de course, T(N/3), que le modèle a longtemps pris
    /// pour convention et qui le faisait 2,7 à 3,9 % plus rapide que sa fiche
    /// en accès aléatoire (`LEDGER-REALISME.md`, la pleine course).
    public func averageSeekMs(cylinders: Int) -> Double {
        let weights = SeekModel.RandomSeekWeights(cylinders: cylinders, crossover: crossover)
        return weights.expectedMs(shortIntercept: shortIntercept, shortSqrtCoefficient: shortSqrtCoefficient,
                                  longIntercept: longIntercept, longLinearCoefficient: longLinearCoefficient)
    }

    /// Les sommes pondérées qui font l'espérance d'une loi à deux branches sur
    /// une course donnée : calculées une fois, l'espérance est ensuite
    /// linéaire dans les quatre constantes — c'est ce qui permet de la caler
    /// en fermé (`calibrated(averageSeekMs:trackToTrackMs:fullStrokeMs:cylinders:)`).
    struct RandomSeekWeights {
        /// Σ w(d) et Σ w(d)·√d sur la branche courte, Σ w(d) et Σ w(d)·d sur
        /// la longue, pour w(d) = 2(N − d)/N².
        let shortWeight: Double, shortRoot: Double, longWeight: Double, longDistance: Double

        init(cylinders: Int, crossover: Int) {
            let n = Double(max(cylinders, 2))
            var ws = 0.0, rs = 0.0, wl = 0.0, dl = 0.0
            for d in 1..<max(cylinders, 2) {
                let w = 2 * (n - Double(d)) / (n * n)
                if d < crossover { ws += w; rs += w * Double(d).squareRoot() }
                else { wl += w; dl += w * Double(d) }
            }
            shortWeight = ws; shortRoot = rs; longWeight = wl; longDistance = dl
        }

        func expectedMs(shortIntercept: Double, shortSqrtCoefficient: Double,
                        longIntercept: Double, longLinearCoefficient: Double) -> Double {
            shortIntercept * shortWeight + shortSqrtCoefficient * shortRoot
                + longIntercept * longWeight + longLinearCoefficient * longDistance
        }
    }

    /// Même loi, étirée sur une course différente.
    ///
    /// Ce qui est conservé, c'est la durée à **fraction de course égale** : un
    /// déplacement d'un tiers de course dure autant sur les deux disques, quel
    /// que soit le nombre de cylindres que cela représente. D'où le `√ratio` sur
    /// la branche courte, qui est en racine de la distance, et le `ratio` sur la
    /// branche longue, qui y est linéaire.
    public func stroked(cylinders: Int, reference: Int) -> SeekModel {
        let ratio = Double(reference) / Double(max(cylinders, 1))
        return SeekModel(
            shortIntercept: shortIntercept,
            shortSqrtCoefficient: shortSqrtCoefficient * ratio.squareRoot(),
            longIntercept: longIntercept,
            longLinearCoefficient: longLinearCoefficient * ratio,
            crossover: max(Int((Double(crossover) / ratio).rounded()), 2),
            settleDuration: settleDuration,
            accelerationCap: accelerationCap,
            headSwitchDuration: headSwitchDuration
        )
    }

    /// Toutes les durées multipliées par le même facteur. `duration(distance:)`
    /// étant affine en chacune de ses constantes, l'ensemble de la courbe est
    /// mis à l'échelle sans changer de forme.
    public func timeScaled(by factor: Double) -> SeekModel {
        SeekModel(
            shortIntercept: shortIntercept * factor,
            shortSqrtCoefficient: shortSqrtCoefficient * factor,
            longIntercept: longIntercept * factor,
            longLinearCoefficient: longLinearCoefficient * factor,
            crossover: crossover,
            settleDuration: settleDuration * factor,
            accelerationCap: accelerationCap * factor,
            headSwitchDuration: headSwitchDuration * factor
        )
    }

    /// Loi de seek d'un disque dont la fiche n'annonce que le seek moyen.
    ///
    /// La mécanique est celle de `referenceShape` — deux régimes, mêmes rapports
    /// entre piste-à-piste, seek moyen et pleine course — étirée sur la course
    /// réelle puis ramenée au seek moyen annoncé. Ce qui varie d'un disque à
    /// l'autre, ce sont ces deux nombres-là ; la **forme** de la loi, elle, ne
    /// dépend pas du modèle (Ruemmler & Wilkes 1994).
    public static func calibrated(averageSeekMs target: Double, cylinders: Int) -> SeekModel {
        let stretched = referenceShape.stroked(cylinders: cylinders,
                                           reference: referenceCylinders)
        let current = stretched.averageSeekMs(cylinders: cylinders)
        guard current > 0, target > 0 else { return stretched }
        return stretched.timeScaled(by: target / current)
    }
}

extension SeekModel {

    /// Loi de seek calée sur les **deux** durées que publie une fiche : le seek
    /// moyen et le piste-à-piste.
    ///
    /// Les deux réglages sont indépendants, et c'est ce qui rend l'exercice
    /// possible. Le seek moyen — un tiers de course, par convention de fiche —
    /// tombe toujours au-delà du cylindre de croisement, donc sur la branche
    /// linéaire : c'est elle que règle `calibrated(averageSeekMs:cylinders:)`.
    /// Le piste-à-piste, lui, est à l'autre bout de la branche en racine. On
    /// résout donc ses deux constantes pour qu'elle passe par `(1, piste-à-
    /// piste)` et rejoigne la branche longue au cylindre de croisement, sans
    /// rien changer au reste de la courbe.
    ///
    /// Sans cela, le rapport entre les deux durées était figé à celui du disque
    /// de 1996 quel que soit le disque décrit — un disque de 2003 se retrouvait
    /// avec un piste-à-piste deux fois trop long, c'est-à-dire avec le
    /// crépitement d'un disque d'une décennie plus tôt.
    /// Commutation de tête, rapportée au piste-à-piste.
    ///
    /// Elle n'a rien à voir avec le seek moyen, qui est ce que la mise à
    /// l'échelle globale lui appliquait : une commutation est un basculement
    /// électronique du préampli suivi d'une correction d'asservissement, sans
    /// déplacement de bras, et elle décroît comme le pas de piste — pas comme
    /// la course complète de l'actionneur. Mise à l'échelle par le seek moyen,
    /// elle finissait à 1,48 ms sur un Barracuda ATA IV dont le pas de piste
    /// vaut 0,95.
    ///
    /// **Le facteur 0,6 est un ordre de grandeur, pas une donnée de fiche.**
    /// Un seul manuel du catalogue publie les deux temps, celui du Fireball
    /// TM, et il les donne **égaux** : « Sequential Cylinder Switch Time
    /// 3.0 ms », « Sequential Head Switch Time 3.0 ms » (table 4-3) — la
    /// correction de piste, après une commutation, coûte autant qu'un pas.
    /// Ses décalages le confirment : 21 intervalles servo pour la tête, 28 pour
    /// le cylindre, calés sur 3 et 4 ms (table 5-3). Les manuels Seagate ne
    /// publient pas la commutation. Le modèle garde 0,6 × le pas de piste —
    /// 1,8 ms pour ce Fireball, au lieu de 3,0 —, et le décalage de tête en
    /// hérite. Le plancher est le repositionnement fin : une commutation se
    /// termine par lui, elle ne peut pas être plus courte.
    static func headSwitch(trackToTrackMs trackToTrack: Double) -> Double {
        max(0.6 * trackToTrack / 1_000, 0.000_2)
    }

    /// Pleine course rapportée au seek moyen dans `referenceShape` — ce que
    /// reçoit une fiche qui ne publie pas la sienne. Aucun manuel Barracuda
    /// du dépôt n'en publie ; le Fireball donne 1,75, le Conner 1,92, le U8
    /// 2,19 : la loi n'est pas la même pour tous, et c'est pour cela que la
    /// pleine course est une donnée de fiche quand elle existe.
    public static let referenceFullStrokeRatio: Double = {
        let shape = referenceShape
        return shape.duration(distance: referenceCylinders - 1) * 1_000
            / shape.averageSeekMs(cylinders: referenceCylinders)
    }()

    /// Loi de seek calée sur les **trois** durées d'une fiche : piste-à-piste,
    /// seek moyen (l'espérance sur des seeks aléatoires) et pleine course.
    ///
    /// Les deux branches ont quatre constantes ; quatre équations les fixent :
    /// la branche courte passe par `(1, piste-à-piste)`, rejoint la longue au
    /// croisement, la longue passe par `(N − 1, pleine course)`, et
    /// l'espérance vaut le seek moyen. Le croisement reste à 15 % de la course
    /// (`referenceShape`). Sans pleine course publiée, celle de la forme de
    /// référence, dans le même rapport au seek moyen.
    ///
    /// Avant, seule la branche courte était calée sur la fiche ; la longue
    /// venait de la forme étirée, si bien que pleine course / seek moyen
    /// valait 1,80 pour tous les disques — −30 % sur le U8.
    public static func calibrated(averageSeekMs average: Double,
                                  trackToTrackMs trackToTrack: Double,
                                  fullStrokeMs: Double?,
                                  cylinders: Int) -> SeekModel {
        let fallback = roughlyCalibrated(averageSeekMs: average, trackToTrackMs: trackToTrack,
                                         cylinders: cylinders)
        let n = cylinders
        let c = fallback.crossover
        guard n > c + 1, c >= 2, trackToTrack > 0, average > trackToTrack else { return fallback }
        let full = fullStrokeMs ?? average * referenceFullStrokeRatio
        guard full > average else { return fallback }

        let w = RandomSeekWeights(cylinders: n, crossover: c)
        let root = Double(c).squareRoot()
        let k = 1 / (root - 1)
        let p = k * (w.shortRoot - w.shortWeight)
        // E = t2t·(Ws − P) + a·(P + Wl) + b·(P·c + Dl), avec a = F − b·(N − 1).
        let denominator = p * Double(c) + w.longDistance - Double(n - 1) * (p + w.longWeight)
        guard abs(denominator) > 1e-12 else { return fallback }
        let b = (average - trackToTrack * (w.shortWeight - p) - full * (p + w.longWeight)) / denominator
        let a = full - b * Double(n - 1)
        let s1 = k * (a + b * Double(c) - trackToTrack)
        let s0 = trackToTrack - s1
        guard b > 0, s1 > 0 else { return fallback }

        return SeekModel(
            shortIntercept: s0,
            shortSqrtCoefficient: s1,
            longIntercept: a,
            longLinearCoefficient: b,
            crossover: c,
            settleDuration: fallback.settleDuration,
            accelerationCap: fallback.accelerationCap,
            headSwitchDuration: fallback.headSwitchDuration
        )
    }

    /// Les deux durées d'une fiche, sans pleine course : la forme de
    /// référence donne la sienne, dans le même rapport au seek moyen.
    public static func calibrated(averageSeekMs average: Double,
                                  trackToTrackMs trackToTrack: Double,
                                  cylinders: Int) -> SeekModel {
        calibrated(averageSeekMs: average, trackToTrackMs: trackToTrack,
                   fullStrokeMs: nil, cylinders: cylinders)
    }

    /// L'ancien calage à deux durées, gardé comme repli du calage en fermé :
    /// la branche longue de la forme étirée, ramenée au seek moyen, puis la
    /// branche courte refaite pour passer par le piste-à-piste — ce qui
    /// décale l'espérance de ce que la branche courte pèse, un quart des
    /// seeks aléatoires.
    static func roughlyCalibrated(averageSeekMs average: Double,
                                  trackToTrackMs trackToTrack: Double,
                                  cylinders: Int) -> SeekModel {
        let base = calibrated(averageSeekMs: average, cylinders: cylinders)
        guard trackToTrack > 0 else { return base }

        // Durée au cylindre de croisement, imposée par la branche longue.
        let crossing = base.longIntercept + base.longLinearCoefficient * Double(base.crossover)
        let root = Double(base.crossover).squareRoot()
        guard root > 1.001, crossing > trackToTrack else { return base }

        let sqrtCoefficient = (crossing - trackToTrack) / (root - 1)
        return SeekModel(
            shortIntercept: trackToTrack - sqrtCoefficient,
            shortSqrtCoefficient: sqrtCoefficient,
            longIntercept: base.longIntercept,
            longLinearCoefficient: base.longLinearCoefficient,
            crossover: base.crossover,
            // Le repositionnement final ne peut pas durer plus que le seek le
            // plus court : c'est lui qui le domine.
            settleDuration: min(base.settleDuration, trackToTrack / 1_000 * 0.8),
            accelerationCap: base.accelerationCap,
            headSwitchDuration: Self.headSwitch(trackToTrackMs: trackToTrack)
        )
    }
}
