import Foundation
import DiskCore

/// Ce que la tête d'un disque fait entendre de plus fort ou de plus doux
/// qu'une autre : son niveau, pris aux manuels.
///
/// La voix de la tête (`SeekSynth`) a longtemps été la même pour les
/// vingt-quatre disques : mêmes modes, même excitation, même niveau. Les
/// manuels publient pourtant la puissance acoustique **en seek**, et, le
/// repos retranché, le bras seul va de 1,97 B sur le 7200.14 à 3,64 sur le
/// 7200.10 SATA, le U8 à 3,20 entre les deux — près de dix-sept décibels que
/// le timbre commun ne disait pas (`Acoustics.seekOnlyBels`).
///
/// Le timbre reste commun : aucune fiche ne publie un spectre, et la
/// littérature ne donne que deux modes (`SeekSynth.modes`). Ce qui change
/// d'un disque à l'autre est le niveau — et, comme pour le plateau
/// (`SpindleCharacter.gain`), il est pris **à moitié en décibels** : les
/// 16,7 dB des fiches en font 8,4 à l'écoute (douze et six entre le U8 et le
/// 7200.14), ce qui garde l'ordre des manuels sans qu'un disque de 2012
/// disparaisse sous sa broche. Deux fiches passent au-dessus du U8 — le
/// 7200.10 SATA et les deux disques à 3,7 B pour 3,0 au repos, dont le
/// VelociRaptor : leur gain dépasse 1.
struct SeekCharacter: Sendable, Equatable {

    /// Puissance du seek, repos retranché, en bels.
    let seekBels: Double

    /// Niveau de référence : le U8, au milieu des fiches, dont la voix
    /// commune tenait lieu à tous — 3,5 B en seek pour 3,2 au repos.
    static let referenceBels = Acoustics(idleBels: 3.2, seekBels: 3.5, source: "").seekOnlyBels

    init(seekBels: Double) {
        self.seekBels = seekBels
    }

    /// Le disque d'une fiche.
    init(reference: DriveReference) {
        self.init(acoustics: DriveCatalog.acoustics(year: reference.year, reference: reference))
    }

    /// Le disque tel que la géométrie le décrit : la fiche la plus proche de
    /// son année qui publie ses niveaux — le VelociRaptor pour un 10 000 tr/min
    /// à petits plateaux, le U8 avant 1999, faute de mieux.
    init(geometry: DriveGeometry, year: Int?) {
        let year = year ?? DriveCatalog.smallPlatterYear
        let named = DriveCatalog.smallPlatter(rpm: Int(geometry.rpm), year: year)
        self.init(acoustics: DriveCatalog.acoustics(year: year, reference: named))
    }

    private init(acoustics: Acoustics?) {
        self.init(seekBels: acoustics?.seekOnlyBels ?? Self.referenceBels)
    }

    /// Gain d'amplitude de la voix de la tête, 1 au niveau de référence :
    /// l'écart aux manuels à moitié en décibels, comme pour le plateau sous
    /// son coude.
    var gain: Double {
        pow(10, (seekBels - Self.referenceBels) / 4)
    }
}
