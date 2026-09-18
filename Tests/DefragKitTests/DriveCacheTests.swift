import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Le tampon du disque : lecture anticipée, lecture sans latence, cache
/// d'écriture, et le bus qui borne ce qu'il sert.
///
/// Chaque test porte sur une propriété qu'un total de démarrage ne verrait pas
/// disparaître — le recalage de `ThinkModel` absorberait un tampon faux aussi
/// bien qu'un vrai. Ils sont donc chiffrés en secondes de latence, en Mo/s de
/// bus et en nombre de vidages, pas en durées de passe.
@Suite("Tampon du disque")
struct DriveCacheTests {

    /// Deux disques de deux époques, chacun dans sa machine : le Fireball de
    /// 1996 derrière un bus PIO de 16,6 Mo/s, le Barracuda 7200.10 derrière
    /// l'Ultra DMA/100.
    private static let fireball = DriveCatalog.fireball1996
    private static let barracuda = DriveCatalog.nearest(year: 2007)

    private static func interface(_ drive: DriveReference) -> DriveInterface {
        DriveInterface(buffer: drive.buffer, host: .era(year: drive.year))
    }

    private static func mechanics(_ drive: DriveReference,
                                  interface: DriveInterface? = nil) -> DiskMechanics {
        DiskMechanics(geometry: drive.geometry, seekModel: drive.seekModel,
                      spinUpAt: 0, spinUpDuration: 0,
                      drive: interface ?? Self.interface(drive))
    }

    private static func read(_ lba: Int, _ sectors: Int, think: Double = 0) -> BlockRequest {
        BlockRequest(issueTime: 0, lba: lba, sectorCount: sectors, isWrite: false,
                     phaseIndex: 0, thinkTime: think)
    }

    private static func write(_ lba: Int, _ sectors: Int, think: Double = 0) -> BlockRequest {
        BlockRequest(issueTime: 0, lba: lba, sectorCount: sectors, isWrite: true,
                     phaseIndex: 0, thinkTime: think)
    }

    // MARK: - La lecture anticipée

    /// La requête qui suit une lecture, pendant que l'hôte calcule, est déjà
    /// dans le tampon : ni latence rotationnelle, ni pas de piste, ni seek — et
    /// elle sort au débit du bus, coût de commande compris, pas à celui du
    /// plateau.
    @Test("Une lecture contiguë servie par le tampon ne paie que le bus",
          arguments: ["fireball", "barracuda"])
    func readAheadServesAtBusSpeed(which: String) {
        let drive = which == "fireball" ? Self.fireball : Self.barracuda
        let interface = Self.interface(drive)
        var mechanics = Self.mechanics(drive)
        var events: [DiskEvent] = []
        let start = drive.geometry.lba(ofFraction: 0.2)
        let chunk = 8                                   // 4 Ko, une page
        _ = mechanics.serve(Self.read(start, chunk), events: &events)
        let before = mechanics.stats

        // L'hôte calcule 20 ms entre deux lectures : le disque, lui, continue
        // de remplir son tampon.
        var busy = 0.0
        let count = 8
        for index in 1...count {
            let timing = mechanics.serve(Self.read(start + index * chunk, chunk, think: 0.020),
                                         events: &events).timing
            busy += timing.end - timing.start
        }
        let after = mechanics.stats
        #expect(after.bufferHits - before.bufferHits == count)
        #expect(after.seekCount == before.seekCount)
        #expect(after.rotationSeconds == before.rotationSeconds)
        #expect(after.stepSeconds == before.stepSeconds)

        let bytes = Double(count * chunk * DriveGeometry.bytesPerSector)
        let achieved = bytes / busy / 1_000_000
        let bus = interface.readBytesPerSecond / 1_000_000
        let expected = bytes / (Double(count) * interface.commandOverhead
                                + bytes / interface.readBytesPerSecond) / 1_000_000
        #expect(achieved <= bus)
        #expect(abs(achieved - expected) < 1e-6 * expected,
                "\(achieved) Mo/s, attendu \(expected) Mo/s — bus à \(bus) Mo/s")
        print(String(format: "  %@ : %.2f Mo/s servis par le tampon (bus %.1f Mo/s, commande %.1f ms)",
                     drive.shortName, achieved, bus, interface.commandOverhead * 1_000))
    }

    /// La lecture anticipée continue quand l'hôte ne demande rien : la tête lit
    /// la fin de la piste, et le pas de piste s'entend sans requête.
    @Test("La lecture anticipée lit sans qu'on le lui demande")
    func readAheadReadsOnItsOwn() {
        let drive = Self.fireball
        var mechanics = Self.mechanics(drive)
        var events: [DiskEvent] = []
        let start = drive.geometry.lba(ofFraction: 0.3)
        _ = mechanics.serve(Self.read(start, 8), events: &events)
        let lastRequestEvent = events.last?.time ?? 0
        // Une seconde plus tard, une lecture ailleurs.
        _ = mechanics.serve(Self.read(drive.geometry.lba(ofFraction: 0.8), 8, think: 1.0),
                            events: &events)
        let spt = drive.geometry.sectorsPerTrack(cylinder: drive.geometry.position(ofLBA: start).cylinder)
        #expect(mechanics.stats.readAheadSectors >= spt - 8)
        #expect(events.contains { event in
            if case .transfer(_, _, false) = event.kind, event.time > lastRequestEvent,
               event.time < 1.0 { return true }
            return false
        })
    }

    // MARK: - Le tampon se vide

    /// Une lecture plus grosse que le cache en chasse tout ce qu'il tenait : la
    /// relire depuis son début repasse par le plateau.
    @Test("Une lecture plus grosse que le tampon le rend inopérant")
    func readLargerThanTheBufferFlushesIt() {
        let drive = Self.fireball
        var mechanics = Self.mechanics(drive)
        var events: [DiskEvent] = []
        let start = drive.geometry.lba(ofFraction: 0.4)
        let cache = Self.interface(drive).cacheSectors
        _ = mechanics.serve(Self.read(start, 8), events: &events)
        _ = mechanics.serve(Self.read(start + 8, 8), events: &events)
        #expect(mechanics.stats.bufferHits == 1)
        // La grosse lecture prolonge la lecture anticipée : elle en est servie,
        // mais elle pousse le début hors du tampon.
        _ = mechanics.serve(Self.read(start + 16, 4 * cache), events: &events)
        let hits = mechanics.stats.bufferHits
        let rotations = mechanics.stats.rotationSeconds
        _ = mechanics.serve(Self.read(start, 8, think: 0.05), events: &events)
        #expect(mechanics.stats.bufferHits == hits)
        #expect(mechanics.stats.rotationSeconds > rotations)
    }

    /// Un seek emmène la tête : sur le Fireball, dont le cache tient une piste,
    /// la nouvelle entrée chasse l'ancienne ; sur le 7200.10, dont le tampon de
    /// 16 Mo tient des dizaines de pistes, le premier flux reste servi. C'est la
    /// segmentation — un tampon segmenté sert plusieurs flux.
    @Test("Un seek vide un petit tampon, pas un grand",
          arguments: ["fireball", "barracuda"])
    func aSeekEmptiesASmallBufferOnly(which: String) {
        let drive = which == "fireball" ? Self.fireball : Self.barracuda
        var mechanics = Self.mechanics(drive)
        var events: [DiskEvent] = []
        let a = drive.geometry.lba(ofFraction: 0.2)
        let b = drive.geometry.lba(ofFraction: 0.7)
        _ = mechanics.serve(Self.read(a, 16), events: &events)
        _ = mechanics.serve(Self.read(b, 16, think: 0.1), events: &events)
        let hits = mechanics.stats.bufferHits
        _ = mechanics.serve(Self.read(a + 16, 16, think: 0.1), events: &events)
        if which == "fireball" {
            #expect(mechanics.stats.bufferHits == hits)
        } else {
            #expect(mechanics.stats.bufferHits == hits + 1)
        }
    }

    // MARK: - La lecture sans latence

    /// Une requête d'une piste entière : la tête commence où elle arrive, et le
    /// tour suffit. Sans elle, la latence moyenne est d'un demi-tour.
    @Test("Une lecture d'une piste entière coûte moins d'un demi-tour de latence")
    func zeroLatencyReadOnAWholeTrack() {
        let drive = Self.fireball
        let geometry = drive.geometry
        let revolution = geometry.revolutionDuration

        func meanLatency(zeroLatency: Bool) -> Double {
            // Ni lecture anticipée ni cache : on ne mesure que la latence.
            let interface = Self.interface(drive).with(readAhead: false, zeroLatencyRead: zeroLatency)
            var mechanics = Self.mechanics(drive, interface: interface)
            var events: [DiskEvent] = []
            let count = 200
            for index in 0..<count {
                // Des pistes éloignées, des arrivées à des angles quelconques.
                let cylinder = (index * 37) % (geometry.cylinders - 1)
                let track = DriveGeometry.Position(cylinder: cylinder, head: index % geometry.heads,
                                                   sector: 0)
                let spt = geometry.sectorsPerTrack(cylinder: cylinder)
                _ = mechanics.serve(Self.read(geometry.lba(of: track), spt,
                                              think: 0.000_73 * Double(index % 11)),
                                    events: &events)
            }
            return mechanics.stats.rotationSeconds / Double(count) / revolution
        }

        let with = meanLatency(zeroLatency: true)
        let without = meanLatency(zeroLatency: false)
        #expect(with < 0.1, "\(with) tour de latence moyenne avec la lecture sans latence")
        #expect(without > 0.35 && without < 0.65, "\(without) tour sans")
        print(String(format: "  piste entière : %.3f tour de latence moyenne, %.3f sans", with, without))
    }

    // MARK: - Le cache d'écriture

    /// *N* petites écritures envoyées d'affilée sont acquittées au rythme du bus,
    /// et posées en bien moins de *N* vidages : le disque écrit par salves.
    @Test("Le cache d'écriture pose par salves", arguments: ["fireball", "barracuda"])
    func writeCacheWritesInBursts(which: String) {
        let drive = which == "fireball" ? Self.fireball : Self.barracuda
        let geometry = drive.geometry
        let start = geometry.lba(ofFraction: 0.5)
        let count = 64
        let requests = (0..<count).map { Self.write(start + $0 * 8, 8) }

        var cached = Self.mechanics(drive)
        var events: [DiskEvent] = []
        var host = 0.0
        for request in requests {
            let timing = cached.serve(request, events: &events).timing
            host += timing.end - timing.start
        }
        _ = cached.finish(events: &events)

        var direct = Self.mechanics(drive, interface: Self.interface(drive).with(writeCache: false))
        var directEvents: [DiskEvent] = []
        var waited = 0.0
        for request in requests {
            let timing = direct.serve(request, events: &directEvents).timing
            waited += timing.end - timing.start
        }

        #expect(cached.stats.cachedWrites == count)
        // Le Fireball, dont le cache tient dix-neuf de ces écritures, en fait
        // huit salves ; le 7200.10 et ses 16 Mo, trois.
        #expect(cached.stats.destageWrites * 4 < count,
                "\(cached.stats.destageWrites) vidages pour \(count) écritures")
        #expect(direct.stats.destageWrites == 0)
        #expect(cached.stats.bytesWritten == direct.stats.bytesWritten)
        // L'hôte n'attend plus que le bus — et, sur le petit cache du Fireball,
        // les vidages qui lui font de la place.
        #expect(host < waited / 3, "\(host) s d'attente contre \(waited) s sans cache")
        print("  \(drive.shortName) : \(count) écritures de 4 Ko, \(cached.stats.destageWrites) vidages")
    }

    /// Des écritures éparses sont posées dans l'ordre des secteurs, pas dans
    /// celui où elles sont arrivées.
    @Test("Un vidage suit l'ordre des secteurs")
    func destageFollowsTheElevator() {
        let drive = Self.barracuda
        let geometry = drive.geometry
        var mechanics = Self.mechanics(drive)
        var events: [DiskEvent] = []
        var samples: [HeadSample] = []
        for fraction in [0.9, 0.1, 0.6, 0.3, 0.8, 0.2] {
            _ = mechanics.serve(Self.write(geometry.lba(ofFraction: fraction), 8),
                                events: &events, samples: &samples)
        }
        _ = mechanics.finish(events: &events, samples: &samples)
        let cylinders = samples.filter(\.isWrite).map(\.cylinder)
        #expect(cylinders.count == 6)
        // Un seul retournement au plus : l'ascenseur repart du bas une fois.
        let turns = zip(cylinders, cylinders.dropFirst()).filter { $0 > $1 }.count
        #expect(turns <= 1, "\(cylinders)")
    }

    // MARK: - Sans tampon

    /// Sans tampon, la mécanique est exactement celle d'avant : c'est ce qui
    /// permet de mesurer le cache comme une étape, et non comme une réécriture.
    @Test("Sans tampon, rien ne change")
    func directIsTheOldMechanics() {
        let drive = Self.fireball
        var mechanics = Self.mechanics(drive, interface: .direct)
        var events: [DiskEvent] = []
        let start = drive.geometry.lba(ofFraction: 0.2)
        for index in 0..<10 {
            _ = mechanics.serve(Self.read(start + index * 8, 8, think: 0.02), events: &events)
        }
        #expect(mechanics.stats.bufferHits == 0)
        #expect(mechanics.stats.readAheadSectors == 0)
        #expect(mechanics.idleAt == mechanics.clock)
    }
}
