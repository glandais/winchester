import Testing
import Foundation
@testable import DiskCore

/// Géométrie et loi de seek déduites de la fiche d'un disque.
///
/// Les deux disques modélisés à la main servent de points d'ancrage : si
/// l'interpolation ne les retrouve pas, elle ne décrit rien.
@Suite("Disques déduits d'une fiche")
struct DriveModelTests {

    @Test("La capacité obtenue couvre toujours celle demandée")
    func capacityIsNeverShort() {
        for mb in [20, 170, 210, 340, 850, 1_080, 4_300, 40_000, 320_000] as [UInt64] {
            let bytes = mb * 1_024 * 1_024
            let drive = DriveGeometry.era(model: "test", capacityBytes: bytes, rpm: 5_400)
            #expect(UInt64(drive.capacityBytes) >= bytes,
                    "\(mb) Mo : \(drive.capacityBytes) octets obtenus")
        }
    }

    @Test("Le disque de 1996 se retrouve à quelques pour cent")
    func matchesWin95Drive() {
        let reference = DriveGeometry.win95Drive
        let drive = DriveGeometry.era(model: "test",
                                      capacityBytes: UInt64(reference.capacityBytes),
                                      rpm: 4_500)
        let outer = Double(drive.zones[0].sectorsPerTrack)
        #expect(abs(outer - 256) / 256 < 0.02, "\(outer) secteurs sur la piste externe")
        // Même ordre de grandeur de course : c'est elle qui fixe l'acoustique.
        let ratio = Double(drive.cylinders) / Double(reference.cylinders)
        #expect(ratio > 0.9 && ratio < 1.1, "\(drive.cylinders) cylindres contre 2 000")
    }

    @Test("Le disque de 2001 aussi")
    func matchesDefaultDrive() {
        let reference = DriveGeometry.defaultDrive
        let drive = DriveGeometry.era(model: "test",
                                      capacityBytes: UInt64(reference.capacityBytes),
                                      rpm: 7_200)
        let outer = Double(drive.zones[0].sectorsPerTrack)
        #expect(abs(outer - 468) / 468 < 0.05, "\(outer) secteurs sur la piste externe")
    }

    @Test("Sans zonage, une seule zone et la capacité tient quand même")
    func withoutZonedRecording() {
        let bytes: UInt64 = 210 * 1_024 * 1_024
        let drive = DriveGeometry.era(model: "test", capacityBytes: bytes, rpm: 3_600, zbr: false)
        #expect(drive.zones.count == 1)
        #expect(UInt64(drive.capacityBytes) >= bytes)
    }

    @Test("Le seek moyen annoncé est celui qu'on mesure")
    func calibratedSeekHitsItsTarget() {
        for cylinders in [500, 672, 2_000, 8_000, 24_000] {
            for target in [8.5, 12.0, 16.0, 20.0] {
                let model = SeekModel.calibrated(averageSeekMs: target, cylinders: cylinders)
                let measured = model.averageSeekMs(cylinders: cylinders)
                #expect(abs(measured - target) < 0.05,
                        "\(cylinders) cylindres, \(target) ms visées, \(measured) ms mesurées")
            }
        }
    }

    @Test("Étirer la course conserve les durées à fraction de course égale")
    func strokingPreservesShape() {
        let reference = SeekModel.win95Model
        let stretched = reference.stroked(cylinders: 8_000, reference: 2_000)
        for fraction in [0.05, 0.2, 1.0 / 3, 0.75, 1.0] {
            let before = reference.duration(distance: Int(2_000 * fraction))
            let after = stretched.duration(distance: Int(8_000 * fraction))
            #expect(abs(after - before) / max(before, 1e-9) < 0.02,
                    "à \(fraction) de course : \(before * 1000) ms puis \(after * 1000) ms")
        }
    }

    /// Une passe de défragmentation pose la partition à l'extérieur du plateau :
    /// si le disque déduit est trop petit, les LBA de fin de volume seraient
    /// silencieusement ramenés au dernier cylindre et la passe sonnerait faux.
    @Test("Tout volume d'un scénario tient sur le disque de sa fiche")
    func everyScenarioVolumeFits() throws {
        for spec in try ScenarioLibrary.loadAll() {
            let drive = DriveGeometry.era(model: spec.id,
                                          capacityBytes: spec.disk.sizeBytes,
                                          rpm: spec.disk.rpm,
                                          zbr: spec.disk.zbr)
            let volumeBytes = UInt64(spec.clusterCount) * UInt64(spec.resolvedFileSystem().clusterBytes)
            #expect(UInt64(drive.capacityBytes) >= volumeBytes, "\(spec.id)")
            #expect(drive.cylinders > 1, "\(spec.id)")

            let seek = SeekModel.calibrated(averageSeekMs: spec.disk.averageSeekMs,
                                            cylinders: drive.cylinders)
            // Piste-à-piste plausible : jamais plus rapide qu'un dixième du
            // seek moyen, jamais plus lent que la moitié.
            let trackToTrack = seek.duration(distance: 1) * 1_000
            #expect(trackToTrack > spec.disk.averageSeekMs * 0.10, "\(spec.id) : \(trackToTrack) ms")
            #expect(trackToTrack < spec.disk.averageSeekMs * 0.50, "\(spec.id) : \(trackToTrack) ms")
        }
    }
}
