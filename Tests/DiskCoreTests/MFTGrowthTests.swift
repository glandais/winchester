import Testing
import Foundation
@testable import DiskCore

/// Ce que devient `$MFT` quand sa zone ne la protège plus.
///
/// Une MFT hors zone se fragmente : c'est vrai, c'est le symptôme classique
/// d'un volume NTFS qu'on a laissé se remplir, et le modèle doit le montrer.
/// Mais elle se fragmente en **quelques dizaines** de morceaux, pas en
/// quelques centaines : NTFS agrandit la table par paquets et les pose au plus
/// près d'elle-même. Le modèle faisait l'inverse — le plus petit trou du disque,
/// un cluster à la fois — et rendait 348 extents pour les 4 653 clusters de
/// `dev-2003` : une MFT de 18 Mo en 348 morceaux, qu'aucun volume réel ne
/// montre.
///
/// Les volumes retenus sont ceux de la galerie dont la MFT déborde de sa
/// zone. Les autres la gardent d'un seul tenant, et c'est aussi une
/// non-régression.
///
/// `famille-2003` et `famille-2007` ont changé de liste au lot 4 : leurs
/// médias et leurs téléchargements remplissent le reste du volume jusqu'à
/// entamer la zone.
///
/// Sous XP (chantier 49), la MFT qui ne peut plus grandir sur place ouvre une
/// zone neuve et y continue d'un seul tenant (`bitmpsup.c:1263-1287`) :
/// `famille-2003` finit en 3 extents, loin sous le plafond, qui reste celui
/// du modèle d'avant pour Vista.
///
/// `dev-2003` et `secretaire-2007` ont quitté la liste au chantier 50 (50a) :
/// leur zone n'était entamée que par la défragmentation de l'histoire, qui
/// tassait les fichiers à travers elle. Elle la laisse vide désormais, comme
/// tout défragmenteur d'époque (`freespace.cpp:305-318`), et leur MFT tient
/// d'un seul tenant.
@Suite("Croissance de la MFT")
struct MFTGrowthTests {

    /// Les valeurs mesurées à l'écriture de ce test. Elles ne sont pas des
    /// cibles : ce sont les bornes en deçà desquelles le résultat cesse de
    /// décrire un volume possible.
    @Test("Une MFT hors zone se compte en dizaines d'extents, pas en centaines",
          arguments: [("famille-2003", 80), ("famille-2007", 60)])
    func overflowingMFTStaysInTensOfExtents(id: String, ceiling: Int) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(id))
        let perExtent = Double(disk.mftClusters) / Double(max(disk.mftExtents, 1))
        print(String(format: "%@ — MFT %d clusters en %d extents (%.0f clusters par morceau)",
                     id, Int(disk.mftClusters), disk.mftExtents, perExtent))

        #expect(disk.mftExtents > 1, "\(id) : la MFT est censée avoir débordé de sa zone")
        #expect(disk.mftExtents < ceiling,
                "\(id) : \(disk.mftExtents) extents pour \(disk.mftClusters) clusters")
    }

    /// Les volumes dont la zone a tenu : la MFT y est d'un seul tenant, et
    /// aucune correction de la croissance hors zone ne doit la casser.
    @Test("Une MFT qui tient dans sa zone reste d'un seul tenant",
          arguments: ["secretaire-2003", "gamer-2003", "gamer-2007", "dev-2003", "secretaire-2007"])
    func containedMFTIsContiguous(id: String) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(id))
        #expect(disk.mftExtents == 1, "\(id) : \(disk.mftExtents) extents")
    }
}
