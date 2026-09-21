import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que l'écran dit du modèle, quand c'est le modèle qui l'écrit.
///
/// `UX_REVIEW.md` §3 : aucun nombre n'était faux, mais les libellés ne disaient
/// pas ce qu'ils comptaient, et le même octet se convertissait à deux endroits.
/// Les deux fautes sont de celles qui reviennent toutes seules — un nouvel
/// outil recopie le libellé du voisin, une nouvelle tuile réécrit sa division.
/// Ces tests-là les attrapent au lieu d'attendre la prochaine relecture.
///
/// La conversion elle-même est éprouvée côté `DiskCore` (`FrenchUnitsTests`) ;
/// ici, ce sont les écrans du modèle qui s'y ramènent.
@Suite("Ce que l'écran dit du modèle")
struct ScreenWordingTests {

    // MARK: - Une seule conversion des octets

    @Test("Une capacité se lit pareil, d'où qu'elle vienne")
    func capacityHasOneConversion() {
        // Le disque de « Développeur, 1993 » : 210 Mo au catalogue, donc
        // 210 × 2²⁰ octets. Il s'annonçait « 210 Mo » sur sa fiche et
        // « 220 Mo » sur la Passe, faute d'un diviseur commun.
        let spec = DiskSpec(sizeMB: 210, rpm: 3_600, averageSeekMs: 14)
        let partition = PartitionGeometry(startLBA: 0,
                                          sectors: Int(spec.sizeBytes) / DriveGeometry.bytesPerSector,
                                          clusterSectors: 8,
                                          format: .fat16)
        // La capacité de la partition est un peu inférieure à celle du disque
        // — les tables prennent leur place —, mais elle se lit avec le même
        // mégaoctet : plus d'écart de 5 % dû au seul chemin de code.
        // `DisplayFormat` reprend les seuils et la conversion de `FrenchUnits` ;
        // seuls le nombre et le nom de l'unité suivent la langue, et hors de
        // l'app c'est la langue source qui sort.
        #expect(partition.capacityDescription
                == DisplayFormat.megabytes(UInt64(partition.capacityBytes)))
        #expect(partition.capacityDescription.hasSuffix("MB"))
    }

    // MARK: - Les libellés disent ce qu'ils comptent

    /// Les deux seuls outils qui tournent sur les deux familles de format et
    /// nomment une métadonnée à l'écriture. Les autres n'en nomment aucune, et
    /// XP comme le recollage économe ne sont proposés que sur NTFS.
    private var bothFamilies: [any DefragStrategy] {
        [UltraDefragStrategy(), SmartDefragStrategy()]
    }

    @Test("Aucun outil n'annonce une MFT à un volume FAT",
          arguments: [VolumeFormat.fat16, .fat32, .ntfs])
    func metadataPhraseFollowsFormat(format: VolumeFormat) throws {
        // Trois outils annonçaient « les derniers enregistrements de MFT et la
        // bitmap du volume » en écriture des métadonnées, libellé en dur : les
        // douze volumes FAT du catalogue le portaient aussi.
        for strategy in bothFamilies {
            let commit = strategy.phases(on: format).first { $0.id == "commit" }
            let detail = try #require(commit?.detail)
            if format.isFAT {
                #expect(!detail.contains("MFT"), "\(strategy.id) parle de MFT sur \(format)")
                #expect(!detail.contains("bitmap"), "\(strategy.id) parle de bitmap sur \(format)")
            } else {
                #expect(!detail.contains("table d'allocation"),
                        "\(strategy.id) parle de table d'allocation sur NTFS")
            }
        }
    }

    @Test("Le nombre et l'ordre des phases ne dépendent pas du format")
    func phaseIndicesAreStable() {
        // L'indice d'une phase est celui que portent ses opérations : si le
        // format changeait le tableau, une opération pointerait sur l'étape du
        // voisin. Seul ce qu'on dit d'une étape a le droit de changer.
        for strategy in bothFamilies {
            let fat = strategy.phases(on: .fat16).map(\.id)
            #expect(fat == strategy.phases(on: .ntfs).map(\.id))
            #expect(fat == strategy.phases.map(\.id))
        }
    }
}
