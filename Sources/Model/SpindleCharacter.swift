import Foundation
import DiskCore

/// Ce que le plateau fait entendre de lui-même, disque au repos.
///
/// Trois grandeurs, et aucune n'est un réglage d'oreille :
///
/// - le **régime**, qui fixe la vitesse périphérique. Le bruit d'écoulement
///   d'air autour des plateaux est un bruit de sillage : ses fréquences suivent
///   la vitesse (nombre de Strouhal constant) et sa puissance croît comme une
///   puissance cinq à six de la vitesse. Un 3 600 tr/min et un 7 200 tr/min n'ont
///   donc ni le même timbre ni le même niveau de souffle ;
/// - le **nombre de plateaux**, qui multiplie les surfaces brassées. Le manuel
///   du Barracuda ATA IV le chiffre sur un même moteur à un même régime :
///   2,1 B au repos avec un plateau, 2,5 B avec deux ;
/// - le **palier**. Jusqu'à la fin des années 90 les moteurs tournent sur
///   roulements à billes ; Seagate passe au palier fluide (FDB) avec le
///   Barracuda ATA IV, en 2001. Le roulement fait l'essentiel du bruit d'un
///   disque de cette époque : le U8 de 1999, un plateau à 5 400 tr/min, est
///   donné à 3,2 B au repos, quand l'ATA IV à 7 200 tr/min en fait 2,1.
///
/// C'est ce dernier point qui décide de l'oreille : à plein régime, le disque
/// lent et ancien est **plus bruyant** que le rapide et récent, et ce n'est pas
/// le même bruit — un sifflement de roulement modulé à chaque tour d'un côté,
/// un souffle d'air de l'autre.
///
/// Niveaux au repos relevés sur les manuels (puissance acoustique, en bels) :
///
/// | disque | année | tr/min | plateaux | palier | repos |
/// |---|---|---|---|---|---|
/// | Conner CFA170A ¹ | 1993 | 4 011 | 2 | billes | ≈ 4,6 B |
/// | Quantum Fireball TM | 1996 | 5 400 | 2–3 | billes | 3,6 B |
/// | Seagate U8 ST38410A | 1999 | 5 400 | 1 | billes | 3,2 B |
/// | Barracuda ATA IV ST340016A | 2001 | 7 200 | 1 | FDB | 2,1 B |
/// | Barracuda ATA IV ST380021A | 2001 | 7 200 | 2 | FDB | 2,5 B |
/// | Barracuda 7200.7 ST340014A | 2003 | 7 200 | 1 | FDB | < 2,2 B |
/// | Barracuda 7200.10 320 Go | 2006 | 7 200 | 2 | FDB | 2,8 B |
/// | Barracuda 7200.11 1 To | 2008 | 7 200 | 4 | FDB | 2,9 B |
///
/// ¹ TULARC ne donne que la pression, 42 dBA. Le manuel du Fireball TM donne
/// les deux mesures du même disque — 32 dBA à un mètre, 3,6 B — et c'est cet
/// écart de 4 dB qui convertit celle du Conner. Le Fireball 1080AT de la
/// galerie est annoncé à 32 dBA, comme le TM : même niveau.
///
/// Le roulement ne dépend donc pas que du nombre de plateaux mais de
/// l'**époque** : dix décibels séparent 1993 de 1996 à deux plateaux, puis le
/// niveau se stabilise jusqu'au passage au palier fluide.
struct SpindleCharacter: Sendable, Equatable {

    let rpm: Double
    let platters: Int
    let fluidBearing: Bool
    /// Année du disque : elle fixe le niveau d'un roulement à billes.
    let year: Int

    /// Première année du palier fluide dans le catalogue : le Barracuda ATA IV.
    static let fluidBearingYear = 2001

    /// Régime de référence : celui des mesures FDB du tableau.
    static let referenceRPM = 7_200.0

    init(rpm: Double, platters: Int, year: Int) {
        self.rpm = max(rpm, 1)
        self.platters = max(platters, 1)
        self.year = year
        self.fluidBearing = year >= Self.fluidBearingYear
    }

    /// Le disque tel que la géométrie le décrit. Deux faces par plateau ; sans
    /// année connue, on suppose un palier fluide.
    init(geometry: DriveGeometry, year: Int?) {
        self.init(rpm: geometry.rpm,
                  platters: (geometry.heads + 1) / 2,
                  year: year ?? Self.fluidBearingYear)
    }

    /// Rapport de vitesse périphérique au disque de référence.
    var speedRatio: Double { min(max(rpm / Self.referenceRPM, 0.25), 2) }

    // MARK: - Niveaux

    /// Souffle d'air seul, en bels : la droite des FDB à 7 200 tr/min du
    /// tableau (2,15 B pour un plateau, +0,4 B à chaque doublement), ramenée au
    /// régime par une puissance cinq de la vitesse.
    var windageBels: Double {
        2.15 + 0.4 * log2(Double(platters)) + 5 * log10(speedRatio)
    }

    /// Roulement à billes seul, en bels : 3,6 B à deux plateaux de 1996 à 1999
    /// (Fireball TM, U8 ramené à deux plateaux), un bel de plus en 1993
    /// (Conner), interpolé entre les deux. La même pente que le souffle par
    /// plateau.
    var bearingBels: Double {
        let era = min(max(Double(1996 - year) / 3, 0), 1)
        return 3.6 + 0.4 * log2(Double(platters) / 2) + era
    }

    /// Niveau total au repos, en bels. Un palier fluide ne s'entend pas : le
    /// disque sonne comme son souffle. Un roulement à billes impose son niveau.
    var idleBels: Double {
        guard !fluidBearing else { return windageBels }
        // Les puissances s'ajoutent : un bel est un logarithme décimal.
        return log10(pow(10, bearingBels) + pow(10, windageBels))
    }

    /// Part de la puissance totale qui vient du roulement, 0 pour un FDB.
    var bearingShare: Double {
        guard !fluidBearing else { return 0 }
        return max(1 - pow(10, windageBels - idleBels), 0)
    }

    /// Niveau de référence : le U8, milieu de la galerie, que la voix
    /// d'avant représentait pour tous les disques.
    static let referenceBels = 3.2

    /// Au-delà de ce niveau — le plus bruyant des disques à palier fluide, le
    /// 7200.11 —, l'écart ne compte plus qu'au quart.
    static let kneeBels = 3.0

    /// Gain d'amplitude de la voix de rotation, 1 au niveau de référence.
    ///
    /// **Licence de mixage** : l'écart aux manuels est pris à moitié en
    /// décibels jusqu'au coude, au quart au-delà. Entre le Conner (≈ 4,6 B) et
    /// un 7 200 tr/min à un plateau (2,15 B), les fiches mettent 25 dB ; sur un
    /// haut-parleur de téléphone, c'est soit un 1993 qui couvre ses propres
    /// seeks et écrête, soit un 2003 qu'on n'entend plus. À moitié partout, il
    /// restait 12 dB, et l'écoute sur le téléphone a trouvé les vieux disques
    /// trop forts, les récents justes : seul le haut de l'échelle est donc
    /// resserré. Il reste 8 dB entre le Conner et un 2003, l'ordre des fiches,
    /// et les seeks — dont le niveau n'est calé sur aucune fiche — gardent leur
    /// place au-dessus.
    var gain: Double {
        let below = min(idleBels, Self.kneeBels) - Self.referenceBels
        let above = max(idleBels - Self.kneeBels, 0)
        return pow(10, below / 4 + above / 8)
    }

    // MARK: - Spectre

    /// Une bande de bruit filtré : fréquence centrale au régime nominal,
    /// sélectivité, et part de puissance.
    struct Band: Sendable, Equatable {
        let frequency: Double
        let q: Double
        let power: Double
        /// Modulée à chaque tour : un roulement n'est jamais rond.
        let modulated: Bool
    }

    /// Le souffle : trois résonances de la cavité, glissées avec la vitesse, et
    /// d'autant plus aiguës en poids que le disque tourne vite — le sillage
    /// monte en fréquence et l'aigu croît plus vite que le grave.
    ///
    /// Fréquences et parts de puissance sont celles de la voix d'avant, qui
    /// les appliquait à tous les disques et qu'on garde pour un 7 200 tr/min ;
    /// seule leur dépendance au régime est nouvelle.
    static let windageBands: [(frequency: Double, q: Double, weight: Double)] = [
        (185, 7.0, 0.23), (520, 4.5, 0.31), (1_450, 2.2, 0.46),
    ]

    /// Le roulement : un sifflement large autour des résonances de la
    /// structure qu'il excite, fixes, et une composante grave de roulage, qui
    /// suit le passage des billes, donc le régime. Fréquences données à
    /// 5 400 tr/min.
    static let bearingBands: [(frequency: Double, q: Double, weight: Double, follows: Bool)] = [
        (2_900, 3.0, 1.0, false), (640, 2.0, 0.45, true),
    ]
    static let bearingReferenceRPM = 5_400.0

    var bands: [Band] {
        let r = speedRatio
        let windage = Self.windageBands.enumerated().map { index, band in
            // Aigu favorisé par la vitesse : ×r pour la bande médiane, ×r² pour
            // la haute, à puissance totale égale ensuite.
            (band.frequency * r, band.q, band.weight * pow(r, Double(index)))
        }
        let windageSum = windage.reduce(0) { $0 + $1.2 }
        var result = windage.map {
            Band(frequency: $0.0, q: $0.1, power: (1 - bearingShare) * $0.2 / windageSum, modulated: false)
        }
        if bearingShare > 0 {
            let sum = Self.bearingBands.reduce(0) { $0 + $1.weight }
            result += Self.bearingBands.map {
                Band(frequency: $0.follows ? $0.frequency * rpm / Self.bearingReferenceRPM : $0.frequency,
                     q: $0.q, power: bearingShare * $0.weight / sum, modulated: true)
            }
        }
        return result
    }

    /// Raie de commutation du moteur : un triphasé à huit pôles commute
    /// vingt-quatre fois par tour (quatre paires de pôles, six pas). Elle suit
    /// le régime au lieu d'une résonance ; 1 440 Hz à 3 600 tr/min, 2 880 Hz à
    /// 7 200. Le nombre de pôles n'est donné par aucune des fiches : c'est le
    /// moteur le plus courant de ces disques, pas celui de chacun.
    static let commutationsPerTurn = 24.0

    var commutationFrequency: Double { rpm / 60 * Self.commutationsPerTurn }
}
