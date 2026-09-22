import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que les fiches publient du débit et du seek, contre ce que la mécanique
/// simulée en fait.
@Suite("Débit séquentiel et seek d'écriture")
struct SequentialThroughputTests {

    /// Lecture séquentielle de vingt cylindres au bord du plateau, d'un seul
    /// bloc : ce que mesure le « sustained data transfer rate » d'un manuel,
    /// commutations de tête et pas de piste compris. Un secteur lu d'abord
    /// pose la tête : ni le seek d'arrivée ni la latence du premier secteur ne
    /// sont du débit.
    private static func sequentialMBs(_ reference: DriveReference) -> Double {
        let geometry = reference.geometry
        var mechanics = DiskMechanics(geometry: geometry, seekModel: reference.seekModel,
                                      spinUpAt: 0, spinUpDuration: 0)
        var events: [DiskEvent] = []
        let placed = mechanics.serve(BlockRequest(issueTime: 0, lba: 0, sectorCount: 1,
                                                  isWrite: false, phaseIndex: 0),
                                     events: &events).timing
        let sectors = geometry.sectorsPerTrack(cylinder: 0) * geometry.heads * 20
        let timing = mechanics.serve(BlockRequest(issueTime: placed.end, lba: 1, sectorCount: sectors,
                                                  isWrite: false, phaseIndex: 0),
                                     events: &events).timing
        let elapsed = timing.end - placed.end
        return Double(sectors * DriveGeometry.bytesPerSector) / elapsed / 1_000_000
    }

    /// Le débit soutenu des cinq fiches qui le publient, à 10 % : 7200.7,
    /// 7200.10 (PATA et SATA, même plateau), 7200.11 et 7200.14.
    ///
    /// La tolérance était de 20 %, et elle absorbait un écart toujours du même
    /// côté (+5, +2 et +14 %) : la comparaison portait sur le débit brut de la
    /// piste, qui ne paie pas les commutations. Une fois comparé à ce que la
    /// fiche mesure, l'écart tombe des deux côtés, et la borne peut se serrer.
    @Test("La lecture séquentielle tient le débit soutenu des manuels, à 10 %")
    func sequentialReadMatchesTheDatasheets() {
        var checked = 0
        for reference in DriveCatalog.all {
            guard let published = reference.sustainedOuterMBs else { continue }
            let measured = Self.sequentialMBs(reference)
            print(String(format: "  %@ : %.1f Mo/s simulés, %.0f annoncés (%+.1f %%)",
                         reference.model, measured, published, (measured / published - 1) * 100))
            #expect(abs(measured - published) / published < 0.10,
                    "\(reference.model) : \(measured) Mo/s contre \(published) annoncés")
            checked += 1
        }
        #expect(checked == 5)
    }

    /// Un seek suivi d'une écriture dure plus que le même suivi d'une lecture,
    /// de ce que la fiche publie ; le transfert, lui, ne change pas.
    @Test("Une écriture attend plus longtemps que sa tête se pose")
    func writeSettlesLonger() {
        let reference = DriveCatalog.all.first { $0.model.contains("7200.7") }!
        let geometry = reference.geometry
        func seekSeconds(isWrite: Bool) -> Double {
            var mechanics = DiskMechanics(geometry: geometry, seekModel: reference.seekModel,
                                          spinUpAt: 0, spinUpDuration: 0)
            var events: [DiskEvent] = []
            let lba = geometry.lba(ofFraction: 0.33)
            _ = mechanics.serve(BlockRequest(issueTime: 0, lba: lba, sectorCount: 8,
                                             isWrite: isWrite, phaseIndex: 0), events: &events)
            return mechanics.stats.seekSeconds
        }
        let read = seekSeconds(isWrite: false)
        let write = seekSeconds(isWrite: true)
        #expect(write > read + 0.000_5, "\(write) s contre \(read) s")
    }
}
