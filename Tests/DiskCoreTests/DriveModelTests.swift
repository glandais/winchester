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
            for year in [1993, 1996, 1999, 2003, 2007] {
                let bytes = mb * 1_024 * 1_024
                let drive = DriveGeometry.era(model: "test", capacityBytes: bytes,
                                              rpm: 5_400, year: year)
                #expect(UInt64(drive.capacityBytes) >= bytes,
                        "\(mb) Mo en \(year) : \(drive.capacityBytes) octets obtenus")
            }
        }
    }

    /// Le test qui tient tout le modèle : chacun des disques du catalogue est
    /// un disque réellement vendu, et le modèle doit le retrouver à partir de
    /// sa seule fiche commerciale — capacité, régime, année.
    ///
    /// Ce qui est vérifié, ce sont les deux grandeurs qui s'entendent : la
    /// **course du bras**, qui est le nombre de pistes, et la **densité
    /// linéaire**, qui est le nombre de secteurs par piste. Le nombre de faces
    /// est vérifié à une près — la marge de densité peut en économiser une sur
    /// un disque à quatre plateaux.
    @Test("Les disques réels du catalogue se retrouvent depuis leur seule fiche")
    func catalogDrivesAreReproduced() {
        for reference in DriveCatalog.all {
            let drive = DriveGeometry.era(model: reference.model,
                                          capacityBytes: reference.capacityBytes,
                                          rpm: reference.rpm,
                                          year: reference.year)

            // La course, à 2 % près : c'est elle qui fixe l'acoustique.
            let trackError = abs(Double(drive.cylinders - reference.tracksPerFace))
                / Double(reference.tracksPerFace)
            #expect(trackError < 0.02,
                    "\(reference.model) : \(drive.cylinders) pistes contre \(reference.tracksPerFace)")

            #expect(abs(drive.heads - reference.heads) <= 1,
                    "\(reference.model) : \(drive.heads) têtes contre \(reference.heads)")

            // La densité linéaire suit le nombre de faces retenu : une face de
            // moins, ce sont d'autant de secteurs en plus sur chaque piste.
            let meanSPT = Double(drive.totalSectors) / Double(drive.cylinders * drive.heads)
            let densityError = abs(meanSPT - reference.meanSectorsPerTrack)
                / reference.meanSectorsPerTrack
            #expect(densityError < 0.35,
                    "\(reference.model) : \(Int(meanSPT)) contre \(Int(reference.meanSectorsPerTrack)) secteurs par piste")
        }
    }

    /// Vérification croisée : le débit n'entre dans aucun calcul du modèle, il
    /// est entièrement déterminé par la géométrie déduite. S'il retombe sur
    /// celui qu'annonce le manuel, c'est que la répartition entre pistes et
    /// densité linéaire est la bonne — et pas seulement leur produit.
    @Test("Le débit de la piste externe retombe sur celui des manuels")
    func outerThroughputMatchesTheDatasheets() {
        for reference in DriveCatalog.all {
            guard let published = reference.sustainedOuterMBs else { continue }
            let drive = DriveGeometry.era(model: reference.model,
                                          capacityBytes: reference.capacityBytes,
                                          rpm: reference.rpm,
                                          year: reference.year)
            let measured = drive.outerSustainedMBs
            #expect(abs(measured - published) / published < 0.20,
                    "\(reference.model) : \(Int(measured)) Mo/s contre \(Int(published)) annoncés")
        }
    }

    /// Une capacité donnée ne décrit pas un disque : il faut l'année. Le même
    /// gigaoctet est un disque entier en 1996 et un coin de plateau en 2003, et
    /// cela s'entend — ni le débit, ni le nombre de faces, ni la course n'ont
    /// quoi que ce soit de commun.
    @Test("Deux disques de même capacité mais d'époques différentes diffèrent")
    func capacityAloneDoesNotDescribeADrive() {
        let bytes: UInt64 = 1_080 * 1_024 * 1_024
        let early = DriveGeometry.era(model: "1996", capacityBytes: bytes, rpm: 5_400, year: 1996)
        let late = DriveGeometry.era(model: "2003", capacityBytes: bytes, rpm: 7_200, year: 2003)

        // En 2003, un gigaoctet n'occupe plus qu'une face, et une fraction de
        // sa surface : moins de pistes qu'en 1996, mais cinq fois le débit.
        #expect(early.heads > late.heads)
        #expect(late.outerSustainedMBs > early.outerSustainedMBs * 5)
        #expect(late.cylinders < early.cylinders)
    }

    /// Et à capacité d'époque, c'est la course qui explose : c'est elle qui
    /// fixe la durée des seeks, donc tout le rythme d'une passe.
    @Test("La course s'allonge d'une époque à l'autre")
    func strokeGrowsWithTheYears() {
        let sizes: [(year: Int, bytes: UInt64, rpm: Int)] = [
            (1993, 170 * 1_024 * 1_024, 3_600),
            (1996, 1_080 * 1_024 * 1_024, 5_400),
            (1999, 6_400 * 1_024 * 1_024, 5_400),
            (2003, 40_000 * 1_024 * 1_024, 7_200),
        ]
        var previous = 0
        for (year, bytes, rpm) in sizes {
            let drive = DriveGeometry.era(model: "\(year)", capacityBytes: bytes, rpm: rpm, year: year)
            #expect(drive.cylinders > previous, "\(year) : \(drive.cylinders) pistes")
            previous = drive.cylinders
        }
    }

    @Test("Sans zonage, une seule zone et la capacité tient quand même")
    func withoutZonedRecording() {
        let bytes: UInt64 = 210 * 1_024 * 1_024
        let drive = DriveGeometry.era(model: "test", capacityBytes: bytes, rpm: 3_600,
                                      year: 1993, zbr: false)
        #expect(drive.zones.count == 1)
        #expect(UInt64(drive.capacityBytes) >= bytes)
        #expect(drive.outerSustainedMBs == drive.innerSustainedMBs)
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

    /// Le seek moyen et le piste-à-piste sont les deux seules durées qu'une
    /// fiche publie, et la loi doit passer par les deux : c'est leur **rapport**
    /// qui distingue une époque d'une autre, pas leur valeur absolue.
    @Test("La loi de seek passe par les deux durées de la fiche")
    func calibrationHitsBothPublishedTimes() {
        for reference in DriveCatalog.all {
            let drive = DriveGeometry.era(model: reference.model,
                                          capacityBytes: reference.capacityBytes,
                                          rpm: reference.rpm,
                                          year: reference.year)
            let seek = SeekModel.calibrated(averageSeekMs: reference.averageSeekMs,
                                            trackToTrackMs: reference.trackToTrackMs,
                                            cylinders: drive.cylinders)

            let measuredAverage = seek.averageSeekMs(cylinders: drive.cylinders)
            #expect(abs(measuredAverage - reference.averageSeekMs) < 0.05,
                    "\(reference.model) : seek moyen \(measuredAverage) ms")

            let measuredTrack = seek.duration(distance: 1) * 1_000
            #expect(abs(measuredTrack - reference.trackToTrackMs) < 0.05,
                    "\(reference.model) : piste-à-piste \(measuredTrack) ms")

            // La courbe reste croissante entre les deux points de mesure.
            var previous = 0.0
            for distance in [1, 2, 8, 64, 512, drive.cylinders / 3, drive.cylinders - 1] {
                let duration = seek.duration(distance: distance)
                #expect(duration >= previous, "\(reference.model) : creux à \(distance) cylindres")
                previous = duration
            }
        }
    }

    @Test("Étirer la course conserve les durées à fraction de course égale")
    func strokingPreservesShape() {
        let reference = SeekModel.referenceShape
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
                                          year: spec.timeline.start.year,
                                          zbr: spec.disk.zbr)
            let volumeBytes = UInt64(spec.clusterCount) * UInt64(spec.resolvedFileSystem().clusterBytes)
            #expect(UInt64(drive.capacityBytes) >= volumeBytes, "\(spec.id)")
            #expect(drive.cylinders > 1, "\(spec.id)")

            let year = spec.timeline.start.year
            let seek = SeekModel.calibrated(
                averageSeekMs: spec.disk.averageSeekMs,
                trackToTrackMs: spec.disk.trackToTrackMs ?? DriveCatalog.trackToTrackMs(year: year),
                cylinders: drive.cylinders)
            // Piste-à-piste plausible : jamais plus rapide qu'un dixième du
            // seek moyen, jamais plus lent que la moitié.
            let trackToTrack = seek.duration(distance: 1) * 1_000
            #expect(trackToTrack > spec.disk.averageSeekMs * 0.10, "\(spec.id) : \(trackToTrack) ms")
            #expect(trackToTrack < spec.disk.averageSeekMs * 0.50, "\(spec.id) : \(trackToTrack) ms")

            // Et le débit du disque déduit reste dans ce que la période
            // permettait : un volume d'époque doit se lire à la vitesse de son
            // époque, sinon toute la durée d'une passe est fausse.
            let reference = DriveCatalog.nearest(year: year)
            let referenceDrive = DriveGeometry.era(model: reference.model,
                                                  capacityBytes: reference.capacityBytes,
                                                  rpm: reference.rpm,
                                                  year: reference.year)
            let ratio = drive.outerSustainedMBs / referenceDrive.outerSustainedMBs
            #expect(ratio > 0.5 && ratio < 2.0,
                    "\(spec.id) : \(Int(drive.outerSustainedMBs)) Mo/s contre \(Int(referenceDrive.outerSustainedMBs)) pour un \(reference.model)")
        }
    }
}
