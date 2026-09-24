import Testing
import Foundation
@testable import DiskCore

/// L'allocateur NTFS du chantier 49 (`LEDGER-XP.md`) : XP suivi à la lettre,
/// NT 4, Vista et 7 gardés tels qu'ils étaient, B#8 pour tous.
@Suite("Allocation NTFS de XP")
struct NTFSXPAllocationTests {

    /// B#8 (`AUDIT_REALISME.md`) : quand Vista ou 7 réservent une tranche
    /// neuve derrière le vierge, le milieu du volume, entre l'ancienne zone et
    /// la nouvelle, reste de l'espace de données. Les plages de données
    /// excluent la zone **courante**, pas tout ce qui la précède.
    @Test("Après une zone renouvelée, le milieu du volume reste aux données (B#8)")
    func renewedZoneKeepsTheMiddle() {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 1_000_000,
                                 formatting: .vista)
        let mftStart = ntfs.mft.extents[0].start
        #expect(mftStart == 125_000)
        // Les données de devant, puis un gros fichier derrière la zone.
        let result1 = ntfs.allocate(clusterCount: mftStart - ntfs.bootExtent.end, hint: .normal)
        #expect(result1.count == 1)
        let middle = ntfs.allocate(clusterCount: 300_000, hint: .normal)
        #expect(middle.count == 1 && middle[0].start > ntfs.mftZone.upperBound)

        // La MFT remplit ses 200 Mo : une tranche neuve est réservée derrière
        // le vierge, loin derrière le gros fichier.
        let zone = ntfs.mftZone
        while ntfs.mftZone.lowerBound == zone.lowerBound { ntfs.noteFileCreated(logicalSize: 4_096) }
        #expect(ntfs.mftZone.lowerBound > middle[0].end)

        // Tout ce qui suit la tranche neuve se remplit.
        let tail = ntfs.bitmap.clusterCount - ntfs.mftZone.upperBound
        #expect(!ntfs.allocate(clusterCount: tail, hint: .normal).isEmpty)

        // Le gros fichier disparaît : sa place, au milieu, est la première
        // reprise. Avant B#8, elle n'appartenait plus à aucune plage, et la
        // tranche neuve cédait sa queue.
        let renewed = ntfs.mftZone
        ntfs.free(middle)
        let placed = ntfs.allocate(clusterCount: 1_000, hint: .normal)
        #expect(placed.count == 1)
        #expect(placed.first.map { $0.start >= middle[0].start && $0.end <= renewed.lowerBound } == true,
                "posé en \(placed)")
        #expect(ntfs.mftZone == renewed)
    }
}
