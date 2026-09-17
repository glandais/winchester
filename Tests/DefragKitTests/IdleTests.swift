import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que le disque fait quand plus personne ne lui demande rien.
///
/// Trois gestes que le modèle connaissait sans jamais les produire : le bras
/// qui s'en va se parquer, le moteur qu'on coupe, et le transfert qui butte
/// sur le dernier cylindre. Les deux premiers s'entendent, le troisième se
/// voyait — un bras collé au moyeu, à relire la même piste.
@Suite("Disque au repos")
struct IdleTests {

    private static let drive = DriveCatalog.fireball1996

    private static func request(at issueTime: Double, lba: Int,
                                sectors: Int = 8) -> BlockRequest {
        BlockRequest(issueTime: issueTime, lba: lba, sectorCount: sectors,
                     isWrite: false, phaseIndex: 0)
    }

    private static func run(_ requests: [BlockRequest],
                            idle: IdleBehavior,
                            geometry: DriveGeometry? = nil) -> DiskTrace {
        DiskSimulator.run(geometry: geometry ?? drive.geometry,
                          seekModel: drive.seekModel,
                          requests: requests, totalDuration: 0,
                          spinUpAt: 0, spinUpDuration: 0.9, idle: idle)
    }

    // MARK: - Le bras se parque

    /// La contrepartie du « clac » d'ouverture : la même course, dans l'autre
    /// sens, une fois qu'il n'y a plus rien à lire.
    @Test("Le bras retourne se parquer après la fin du travail")
    func armParksAfterWork() throws {
        let geometry = Self.drive.geometry
        let trace = Self.run([Self.request(at: 0, lba: 0)],
                             idle: IdleBehavior(parkAfter: 1.0))

        let parkAt = try #require(trace.parkAt)
        let work = try #require(trace.timings.last).end
        #expect(abs(parkAt - (work + 1.0)) < 1e-9)

        // Le voyage est un vrai seek, et il est long : la première requête est
        // au bord, le parcage est au moyeu.
        let seek = trace.events.compactMap { event -> SeekProfile? in
            guard event.time == parkAt, case .seek(let profile) = event.kind else { return nil }
            return profile
        }
        #expect(seek.count == 1)

        let track = PlatterTrack(geometry: geometry, seekModel: Self.drive.seekModel,
                                 samples: trace.headSamples, spindle: trace.spindle,
                                 parkAt: parkAt)
        #expect(track.frame(at: parkAt - 0.1).activity == .idle)
        #expect(track.frame(at: parkAt + 0.5).activity == .parked)
        #expect(track.frame(at: parkAt + 0.5).cylinder == Double(geometry.parkCylinder))
    }

    /// Le parcage ne décrit aucune requête : le compter décalerait le seek moyen
    /// d'une passe sans qu'aucun accès ait bougé.
    @Test("Le parcage n'entre pas dans les compteurs de la passe")
    func parkingIsNotCounted() {
        let requests = [Self.request(at: 0, lba: 0), Self.request(at: 0.1, lba: 500_000)]
        let bare = Self.run(requests, idle: .none)
        let parked = Self.run(requests, idle: IdleBehavior(parkAfter: 1.0))

        #expect(parked.stats.seekCount == bare.stats.seekCount)
        #expect(parked.stats.totalSeekDistance == bare.stats.totalSeekDistance)
        #expect(parked.stats.busySeconds == bare.stats.busySeconds)
    }

    /// Sans couple, plus de coussin d'air : un disque parque toujours ses têtes
    /// avant que le moteur s'arrête, même si le délai d'inactivité n'est pas
    /// écoulé.
    @Test("Le bras est parqué avant que le moteur soit coupé")
    func armParksBeforeMotorStops() throws {
        let trace = Self.run([Self.request(at: 0, lba: 0)],
                             idle: IdleBehavior(parkAfter: 30, stopAt: 2.0, stopDuration: 4))

        let parkAt = try #require(trace.parkAt)
        #expect(parkAt < 2.0)

        let stops = trace.events.filter {
            if case .spinDown = $0.kind { return true } else { return false }
        }
        #expect(stops.count == 1)
        #expect(stops[0].time == 2.0)
    }

    // MARK: - Le moteur s'arrête

    /// Un plateau lancé ne s'arrête pas net. La descente suit la même loi du
    /// premier ordre que la montée, et les tours accomplis restent monotones —
    /// c'est ce qui donne au spin-down sa longue traîne.
    @Test("Le plateau redescend par la même loi qu'il est monté")
    func spindleCoastsDown() {
        let spindle = SpindleTimeline(spinUpAt: 0, duration: 1.0, rpm: 5_400,
                                      spinDownAt: 5, spinDownDuration: 4)

        #expect(spindle.speed(at: 5) > 0.99)
        #expect(spindle.speed(at: 6) < 0.6)
        #expect(spindle.speed(at: 30) < 0.001)
        #expect(spindle.speed(at: 30) > 0)

        var previous = 0.0
        for step in stride(from: 0.0, through: 40.0, by: 0.05) {
            let turns = spindle.revolutions(at: step)
            #expect(turns >= previous)
            previous = turns
        }

        // Après la coupure, le plateau accomplit encore `v·τ` tours : la traîne
        // est bornée, et elle vaut la constante de temps de la descente.
        let tau = SpindleTimeline.timeConstant(forRamp: 4)
        let coasted = spindle.revolutions(at: 1_000) - spindle.revolutions(at: 5)
        #expect(abs(coasted - 5_400 / 60 * tau) < 0.5)
    }

    /// Sans commande d'arrêt, rien ne change : la trace d'un disque qu'on laisse
    /// tourner est celle d'avant.
    @Test("Sans coupure, le plateau garde son régime")
    func spindleWithoutStopIsUnchanged() {
        let spindle = SpindleTimeline(spinUpAt: 0, duration: 1.0, rpm: 5_400)
        #expect(spindle.speed(at: 100) > 0.999)
        #expect(spindle.revolutions(at: 100) > 8_900)
    }

    // MARK: - Le dernier cylindre

    /// Bloquer le cylindre au dernier faisait relire la même piste jusqu'à
    /// épuisement du compte : des pas de piste qui ne menaient nulle part, et un
    /// bras collé au moyeu. Une requête qui déborde du disque est tronquée.
    @Test("Un transfert qui déborde du dernier cylindre est tronqué")
    func transferPastLastCylinderIsTruncated() throws {
        let geometry = Self.drive.geometry
        let spt = geometry.sectorsPerTrack(cylinder: geometry.cylinders - 1)

        // Une piste de moins que la fin du disque, et on en demande cinquante.
        let lba = geometry.totalSectors - spt
        let trace = Self.run([Self.request(at: 0, lba: lba, sectors: spt * 50)],
                             idle: .none)

        let sample = try #require(trace.headSamples.last)
        #expect(Int(sample.endCylinder) == geometry.cylinders - 1)

        // Ce qui n'existe pas n'est ni lu ni chronométré.
        #expect(trace.stats.bytesRead <= spt * geometry.heads * DriveGeometry.bytesPerSector)
        let steps = trace.events.filter {
            if case .trackStep = $0.kind { return true } else { return false }
        }
        #expect(steps.count < 50)
    }
}
