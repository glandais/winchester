import Testing
@testable import DiskCore

/// La conversion des octets, et les deux taux qu'on ne doit pas confondre.
///
/// `UX_REVIEW.md` §3 : aucun nombre n'était faux, mais le même octet se
/// convertissait à deux endroits — 2²⁰ dans l'interface, 10⁶ dans une
/// demi-douzaine de divisions écrites à la main —, si bien qu'un disque
/// s'annonçait « 210 Mo » sur sa fiche et « 220 Mo » sur la Passe. La faute
/// revient toute seule dès qu'une nouvelle tuile réécrit sa division : ces
/// tests-là la retiennent.
@Suite("Octets et taux, écrits en français")
struct FrenchUnitsTests {

    @Test("Le mégaoctet du projet est binaire, et il n'y en a qu'un")
    func megabyteIsBinary() {
        #expect(FrenchUnits.bytesPerMegabyte == 1_048_576)
        // Le disque de « Développeur, 1993 » : 210 Mo sur l'étiquette, en
        // mégaoctets décimaux, comme les secteurs garantis des manuels ; le
        // système en montre 200, en mébioctets, comme CHKDSK le faisait. Le
        // modèle a longtemps compté 2²⁰ sur l'étiquette : 4,86 % de trop.
        let spec = DiskSpec(sizeMB: 210, rpm: 3_600, averageSeekMs: 14)
        #expect(spec.sizeBytes == 210_000_000)
        #expect(FrenchUnits.megabytes(spec.sizeBytes) == "200\u{00A0}Mo")
    }

    @Test("Go au-delà du gigaoctet, Ko en dessous quand on le demande")
    func scalesUpAndDown() {
        #expect(FrenchUnits.megabytes(2_147_483_648) == "2,0\u{00A0}Go")
        #expect(FrenchUnits.megabytes(5 * 1_048_576) == "5,0\u{00A0}Mo")
        #expect(FrenchUnits.megabytes(64 * 1_024, smallInKilobytes: true) == "64\u{00A0}Ko")
        // Sans le drapeau, un petit fichier reste en mégaoctets décimaux.
        #expect(FrenchUnits.megabytes(64 * 1_024) == "0,1\u{00A0}Mo")
    }

    @Test("Un débit reste décimal, et c'est la seule exception")
    func throughputStaysDecimal() {
        // Les fiches constructeur des manuels comptent en 10⁶ : lire un débit
        // en 2²⁰ mentirait de 5 % au moment précis où il sert à les comparer.
        #expect(FrenchUnits.megabytesPerSecond(1_000_000) == 1.0)
        #expect(FrenchUnits.megabytesPerSecond(0) == 0)
    }

    @Test("Les deux taux de fragmentation n'ont pas le même dénominateur")
    func twoRatiosTwoDenominators() {
        // La fiche du disque rapporte aux seuls fichiers fragmentables, la
        // Passe et les Instruments à tous les éléments non résidents : les deux
        // sont justes, et c'est pourquoi chaque écran doit dire lequel il
        // montre. Ce test fige l'écart pour qu'on ne « corrige » pas l'un vers
        // l'autre en croyant réparer une incohérence.
        var m = AllocationMetrics(fileCount: 100, residentFileCount: 20,
                                  fragmentedFileCount: 8, fragmentableFileCount: 50,
                                  meanExtentsPerFile: 1.2, p95ExtentsPerFile: 2,
                                  maxExtentsPerFile: 9, meanExtentClusters: 3,
                                  usedClusters: 0, freeClusters: 0, freeRunCount: 0,
                                  largestFreeRunClusters: 0, slackBytes: 0,
                                  logicalBytes: 0, allocatedBytes: 0, fill: 0)
        #expect(m.fragmentedRatioAmongFragmentable == 8.0 / 50)
        #expect(m.fragmentedRatio == 8.0 / 80)
        #expect(m.fragmentedRatioAmongFragmentable > m.fragmentedRatio)

        // Un volume dont tous les fichiers tiennent dans un cluster : le taux
        // rapporté aux fragmentables n'a pas de dénominateur, et vaut zéro
        // plutôt que de diviser par rien.
        m.fragmentableFileCount = 0
        #expect(m.fragmentedRatioAmongFragmentable == 0)
    }
}
