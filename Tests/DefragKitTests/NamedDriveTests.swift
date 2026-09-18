import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Un disque choisi par son nom : le WD VelociRaptor WD1000DHTZ, hors de la
/// courbe des époques — 10 000 tr/min, plateaux de 2,5 pouces, 64 Mo de tampon.
///
/// Ce qui est vérifié, c'est que sa fiche le décrit seule, sans que l'année
/// vienne s'en mêler, et qu'elle ne dérange rien des huit disques de bureau.
@Suite("Disque nommé : le VelociRaptor")
struct NamedDriveTests {

    private static let raptor = DriveCatalog.reference(named: "VelociRaptor")!

    // MARK: - La fiche

    @Test("La géométrie est celle de la fiche, pas celle de 2012")
    func geometryFollowsTheDatasheet() {
        let drive = Self.raptor.geometry
        #expect(drive.heads == 6)
        #expect(drive.platterInches == 2.5)
        #expect(abs(drive.cylinders - Self.raptor.tracksPerFace) <= Self.raptor.tracksPerFace / 50)
        #expect(UInt64(drive.capacityBytes) >= Self.raptor.capacityBytes)

        // Débit mesuré par Tom's Hardware : 209,1 Mo/s au bord, 114,7 au moyeu.
        #expect(abs(drive.outerSustainedMBs - 209.1) / 209.1 < 0.03,
                "\(drive.outerSustainedMBs) Mo/s au bord")
        #expect(abs(drive.innerSustainedMBs - 114.7) / 114.7 < 0.05,
                "\(drive.innerSustainedMBs) Mo/s au moyeu")
        // Et la fiche WD, 200 Mo/s soutenus, à 5 % près.
        #expect(abs(drive.outerSustainedMBs - 200) / 200 < 0.05)
    }

    @Test("La loi de seek passe par ses deux durées")
    func seekHitsBothTimes() {
        let drive = Self.raptor.geometry
        let seek = Self.raptor.seekModel
        #expect(abs(seek.averageSeekMs(cylinders: drive.cylinders) - 3.8) < 0.05)
        #expect(abs(seek.duration(distance: 1) * 1_000 - 0.7) < 0.05)
        #expect(seek.headSwitchDuration < seek.duration(distance: 1))
        var previous = 0.0
        for distance in [1, 2, 8, 64, 512, drive.cylinders / 3, drive.cylinders - 1] {
            let duration = seek.duration(distance: distance)
            #expect(duration >= previous, "creux à \(distance) cylindres")
            previous = duration
        }
    }

    @Test("Il reste hors de la courbe des époques")
    func namedDriveStaysOutOfTheEras() {
        #expect(!DriveCatalog.all.contains { $0.model == Self.raptor.model })
        #expect(!Self.raptor.followsEra)
        // Une année au-delà du catalogue garde le tampon d'un disque de bureau.
        #expect(DriveCatalog.nearest(year: 2012).rpm == 7_200)
        let desktop = DriveCatalog.all.allSatisfy { $0.followsEra }
        #expect(desktop)
    }

    // MARK: - Dans un scénario

    private static func gamer2007(model: String?) throws -> ProfileSpec {
        var spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "gamer-2007" })
        if model != nil { spec.disk = DiskSpec(reference: raptor) }
        return spec
    }

    @Test("Un scénario qui le nomme prend sa fiche entière")
    func scenarioTakesTheWholeDatasheet() throws {
        let spec = try Self.gamer2007(model: Self.raptor.model)
        let hardware = GeneratedVolumeBridge.drive(for: spec, atLeast: 1)
        #expect(hardware.geometry.rpm == 10_000)
        #expect(hardware.year == 2012)
        #expect(hardware.rampLoad)
        #expect(hardware.interface.buffer == Self.raptor.buffer)
        // Un SATA dans une machine de 2007 : 3 Gb/s, pas la nappe UDMA/100.
        #expect(hardware.interface.readBytesPerSecond == 300_000_000)

        let plain = GeneratedVolumeBridge.drive(for: try Self.gamer2007(model: nil), atLeast: 1)
        #expect(plain.year == 2007)
        #expect(!plain.rampLoad)
        #expect(plain.interface == .era(year: 2007))
    }

    @Test("Le champ model est facultatif dans le JSON")
    func modelIsOptionalInJSON() throws {
        let bare = #"{"sizeMB": 1080, "rpm": 5400, "averageSeekMs": 12, "zbr": true}"#
        let named = #"{"sizeMB": 953869, "rpm": 10000, "averageSeekMs": 3.8, "zbr": true, "#
            + #""model": "Western Digital VelociRaptor WD1000DHTZ"}"#
        let a = try JSONDecoder().decode(DiskSpec.self, from: Data(bare.utf8))
        let b = try JSONDecoder().decode(DiskSpec.self, from: Data(named.utf8))
        #expect(a.model == nil && a.reference == nil)
        #expect(b.reference?.shortName == "VelociRaptor")
        let roundTrip = try JSONDecoder().decode(DiskSpec.self, from: JSONEncoder().encode(b))
        #expect(roundTrip.model == b.model)
    }

    // MARK: - Ce qu'on en entend

    @Test("Le souffle suit la vitesse au bord, pas le régime")
    func windageFollowsTipSpeed() {
        let raptor = SpindleCharacter(geometry: Self.raptor.geometry, year: Self.raptor.year)
        #expect(abs(raptor.speedRatio - 10_000.0 / 7_200 * 1.25 / 1.831) < 1e-9)
        // Fiche WD : 30 dBA au repos en puissance acoustique, 3,0 B. Le modèle
        // tient à 0,35 B, l'écart qu'il a déjà sur le 7200.10.
        #expect(abs(raptor.idleBels - 3.0) < 0.35, "\(raptor.idleBels) B")
        // Au régime seul, il en ferait 3,5 : plus fort que le 7200.11 de 2008.
        let byRPM = SpindleCharacter(rpm: 10_000, platters: 3, year: 2012)
        #expect(byRPM.idleBels > raptor.idleBels + 0.7)
        // Mais la raie de commutation suit le régime : 4 kHz.
        #expect(raptor.commutationFrequency == 4_000)
        // Un plateau de 3,5 pouces n'a pas changé.
        let barracuda = DriveCatalog.all[7]
        let character = SpindleCharacter(geometry: barracuda.geometry, year: barracuda.year)
        #expect(character.speedRatio == 1)
    }

    @Test("Sur rampe, ni décollage ni atterrissage")
    func rampLoadHasNoContact() {
        let drive = Self.raptor
        func run(_ ramp: Bool) -> DiskTrace {
            DiskSimulator.run(geometry: drive.geometry, seekModel: drive.seekModel,
                              requests: [BlockRequest(issueTime: 8, lba: 1_000, sectorCount: 8,
                                                      isWrite: false, phaseIndex: 0)],
                              totalDuration: 0, spinUpAt: 0.35, spinUpDuration: 6,
                              idle: .desktop(year: drive.year, coldStart: true, stopAfter: 1,
                                             stopDuration: 4, rampLoad: ramp))
        }
        func count(_ trace: DiskTrace, _ kind: DiskEventKind) -> Int {
            trace.events.filter { "\($0.kind)" == "\(kind)" }.count
        }
        let contact = run(false)
        let ramp = run(true)
        #expect(count(contact, .headUnstick) == 1 && count(contact, .headLand) == 1)
        #expect(count(ramp, .headUnstick) == 0 && count(ramp, .headLand) == 0)
    }
}
