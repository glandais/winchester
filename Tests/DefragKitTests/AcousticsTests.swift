import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que le lot 6 fait entendre, vérifié là où il se décide : dans la
/// mécanique et dans les repères, avant toute synthèse.
///
/// L'oreille juge le timbre ; ces tests gardent ce qui le porte — le caractère
/// de chaque plateau, la mise en route en trois temps, la recalibration des
/// vieux disques, l'atterrissage des têtes, et la cadence des pistes qu'on ne
/// décime plus.
@Suite("Acoustique des disques")
struct AcousticsTests {

    private static func request(at issueTime: Double = 0, lba: Int,
                                sectors: Int = 8) -> BlockRequest {
        BlockRequest(issueTime: issueTime, lba: lba, sectorCount: sectors,
                     isWrite: false, phaseIndex: 0)
    }

    private static func run(_ drive: DriveReference, _ requests: [BlockRequest],
                            idle: IdleBehavior, spinUp: Double = 6) -> DiskTrace {
        DiskSimulator.run(geometry: drive.geometry, seekModel: drive.seekModel,
                          requests: requests, totalDuration: 0,
                          spinUpAt: 0.35, spinUpDuration: spinUp, idle: idle)
    }

    private static func times(_ trace: DiskTrace, _ match: (DiskEventKind) -> Bool) -> [Double] {
        trace.events.filter { match($0.kind) }.map(\.time)
    }

    private static func isSeek(_ kind: DiskEventKind) -> Bool {
        if case .seek = kind { return true } else { return false }
    }

    // MARK: - Le plateau

    /// Les niveaux au repos des manuels, dans leur ordre : le vieux disque lent
    /// à roulements est le plus bruyant, le 7 200 tr/min à un plateau et palier
    /// fluide le plus discret, et un plateau de plus s'entend.
    @Test("Le niveau au repos suit les manuels du catalogue")
    func idleLevelsFollowManuals() {
        func character(_ drive: DriveReference) -> SpindleCharacter {
            SpindleCharacter(geometry: drive.geometry, year: drive.year)
        }
        let all = DriveCatalog.all.map(character)
        let bels = all.map(\.idleBels)
        // Conner, Fireball, U8, ATA IV ×2, 7200.7, 7200.10, 7200.11.
        #expect(abs(bels[2] - 3.2) < 0.1)             // U8 : 3,2 B
        #expect(abs(bels[3] - 2.1) < 0.1)             // ATA IV un plateau : 2,1 B
        #expect(abs(bels[1] - 3.6) < 0.1)             // Fireball : 3,6 B
        #expect(abs(bels[6] - 2.55) < 0.3)            // 7200.10 : 2,8 B
        #expect(bels[0] > bels[1] && bels[1] > bels[2] && bels[2] > bels[7])
        #expect(bels[7] > bels[6] && bels[6] > bels[5])
        #expect(!all[2].fluidBearing && all[3].fluidBearing)
        // Le gain garde l'ordre des fiches : à moitié en décibels jusqu'au
        // coude, au quart au-delà.
        for (a, b) in zip(bels, bels.dropFirst()) where a > b {
            #expect(all[bels.firstIndex(of: a)!].gain > all[bels.firstIndex(of: b)!].gain)
        }
        let knee = SpindleCharacter.kneeBels
        #expect(abs(20 * log10(all[7].gain / all[3].gain) - 10 * (bels[7] - bels[3]) / 2) < 1e-9)
        #expect(abs(20 * log10(all[0].gain / all[3].gain)
                    - (10 * (knee - bels[3]) / 2 + 10 * (bels[0] - knee) / 4)) < 1e-9)
    }

    /// Le cœur du point 1 : à plein régime, deux disques de régime différent
    /// n'ont plus le même souffle.
    @Test("Le souffle glisse et s'éclaircit avec le régime")
    func windageFollowsSpeed() {
        let slow = SpindleCharacter(rpm: 3_600, platters: 1, year: 2003)
        let fast = SpindleCharacter(rpm: 7_200, platters: 1, year: 2003)
        #expect(slow.bands.count == 3 && fast.bands.count == 3)
        for (a, b) in zip(slow.bands, fast.bands) {
            #expect(abs(b.frequency / a.frequency - 2) < 1e-9)
        }
        // La bande haute pèse quatre fois plus, relativement à la basse.
        let tilt = (fast.bands[2].power / fast.bands[0].power) / (slow.bands[2].power / slow.bands[0].power)
        #expect(abs(tilt - 4) < 1e-9)
        #expect(fast.idleBels - slow.idleBels > 1.4)
        #expect(fast.commutationFrequency == 2_880)
    }

    /// Les parts de puissance font le tout : le niveau est celui du caractère,
    /// quelle que soit la forme du spectre.
    @Test("Les bandes se partagent toute la puissance")
    func bandsShareAllPower() {
        for drive in DriveCatalog.all {
            let character = SpindleCharacter(geometry: drive.geometry, year: drive.year)
            let total = character.bands.reduce(0) { $0 + $1.power }
            #expect(abs(total - 1) < 1e-9, "\(drive.shortName)")
            #expect(character.bands.contains { $0.modulated } == !character.fluidBearing)
        }
    }

    /// La galerie a cinq époques : aucune ne doit sonner comme sa voisine.
    @Test("Les cinq époques de la galerie ont chacune leur plateau")
    func galleryErasDiffer() throws {
        let specs = try ScenarioLibrary.loadAll().filter { $0.id.hasPrefix("dev-") }
        let characters = specs.map { spec -> SpindleCharacter in
            let drive = GeneratedVolumeBridge.drive(for: spec, atLeast: 1)
            return SpindleCharacter(geometry: drive.geometry, year: spec.timeline.start.year)
        }
        #expect(characters.count == 5)
        for (a, b) in zip(characters, characters.dropFirst()) {
            #expect(a != b)
            #expect(a.bands != b.bands || abs(a.idleBels - b.idleBels) > 0.1)
        }
    }

    // MARK: - La mise en route

    /// Moteur, décollement, recherche de la piste 0 : dans cet ordre, la salve
    /// finie quand le disque est prêt, et le bras au bord.
    @Test("Une mise sous tension décolle les têtes, cherche la piste 0 et laisse le bras au bord")
    func coldStartSequence() throws {
        let drive = DriveCatalog.fireball1996
        let trace = Self.run(drive, [Self.request(lba: 400_000)],
                             idle: .desktop(year: 1996, coldStart: true))
        let ready = 0.35 + 6
        let unstick = Self.times(trace) { if case .headUnstick = $0 { true } else { false } }
        #expect(unstick == [0.35 + StartupSequence.unstickDelay])

        let seeks = trace.events.filter { Self.isSeek($0.kind) }
        let salvo = seeks.filter { $0.time < ready }
        #expect(salvo.count == 5)
        #expect(salvo.allSatisfy { $0.time > 0.35 + 3 })
        // La première course est complète : du moyeu au bord.
        if case .seek(let first) = salvo[0].kind {
            #expect(first.distance == drive.geometry.parkCylinder)
        }
        // Le premier accès part du bord, et la salve n'entre pas dans les
        // compteurs : personne ne l'a demandée.
        #expect(trace.stats.seekCount == 1)
        let target = drive.geometry.position(ofLBA: 400_000).cylinder
        if case .seek(let access) = seeks.last!.kind { #expect(access.distance == target) }
        let start = try #require(trace.timings.first).start
        #expect(start >= ready - 1e-9)
    }

    /// Le secteur d'amorçage est au cylindre 0 : sur un disque qu'on allume,
    /// le « clac » d'ouverture est la recherche de la piste 0, pas la lecture.
    /// Et ce qui suit ne change que du premier seek, au tour près.
    @Test("La mise en route ne change la durée que du premier seek")
    func coldStartKeepsDurations() throws {
        let drive = DriveCatalog.all[0]
        let requests = (0..<40).map { Self.request(lba: $0 * 3_001, sectors: 16) }
        let warm = Self.run(drive, requests, idle: .none)
        let cold = Self.run(drive, requests, idle: .desktop(year: 1999, coldStart: true))
        #expect(cold.stats.seekCount == warm.stats.seekCount - 1)
        let shift = try #require(cold.timings.last).end - #require(warm.timings.last).end
        let firstSeek = drive.seekModel.duration(distance: drive.geometry.parkCylinder)
        #expect(abs(shift) <= firstSeek + drive.geometry.revolutionDuration)
    }

    // MARK: - La recalibration thermique

    /// Les disques de 1993 et 1996 s'interrompent toutes les quatre minutes,
    /// ceux de 1999 jamais. La première tombe après tout démarrage.
    @Test("Les disques d'avant 1997 se recalibrent, pas les suivants")
    func recalibrationByEra() {
        #expect(ThermalRecalibration.era(year: 1993) != nil)
        #expect(ThermalRecalibration.era(year: 1996) != nil)
        #expect(ThermalRecalibration.era(year: 1999) == nil)
        #expect(ThermalRecalibration().firstAfter > 70)
    }

    /// Une lecture toutes les 10 s pendant neuf minutes : deux recalibrations,
    /// à 2 et 6 minutes, chacune une salve d'environ une seconde, et ce qu'elles
    /// retardent est compté à part.
    @Test("Une recalibration interrompt le travail, et seulement lui")
    func recalibrationInterrupts() throws {
        let drive = DriveCatalog.fireball1996
        let requests = (0..<54).map { Self.request(at: Double($0) * 10 + 7, lba: ($0 % 7) * 90_000) }
        let plain = Self.run(drive, requests, idle: .desktop(year: 1999), spinUp: 0.9)
        let recal = Self.run(drive, requests, idle: .desktop(year: 1996), spinUp: 0.9)

        #expect(plain.stats.recalibrations == 0)
        #expect(recal.stats.recalibrations == 2)
        #expect(recal.stats.seekCount >= plain.stats.seekCount)
        #expect(recal.stats.totalSeekDistance >= plain.stats.totalSeekDistance)
        let extra = recal.events.filter { Self.isSeek($0.kind) }.count
            - plain.events.filter { Self.isSeek($0.kind) }.count
        let stops = ThermalRecalibration().stops(cylinders: drive.geometry.cylinders).count
        #expect(extra >= 2 * (stops - 4))

        // Salve d'environ une seconde, posée dans un repos : personne n'attend.
        let ready = 0.35 + 0.9
        let first = recal.events.filter { Self.isSeek($0.kind) && $0.time >= ready + 120 }
        let burst = first.prefix { $0.time < 126 }
        let span = try #require(burst.last).time - burst.first!.time
        #expect(span > 0.4 && span < 1.2)
        #expect(recal.stats.recalibrationSeconds == 0)
    }

    /// Une passe qui ne s'arrête jamais attend la fin de la salve.
    @Test("Une passe continue paie la recalibration")
    func continuousWorkPays() {
        let drive = DriveCatalog.all[0]
        var requests: [BlockRequest] = []
        var lba = 0
        for _ in 0..<40_000 {
            requests.append(Self.request(lba: lba, sectors: 16))
            lba = (lba + 97_003) % 300_000
        }
        let plain = Self.run(drive, requests, idle: .none, spinUp: 0.9)
        let recal = Self.run(drive, requests, idle: .desktop(year: 1993), spinUp: 0.9)
        let delta = recal.timings.last!.end - plain.timings.last!.end
        #expect(recal.stats.recalibrations >= 1)
        #expect(recal.stats.recalibrationSeconds > 0.5 * Double(recal.stats.recalibrations))
        #expect(delta > 0.5 * Double(recal.stats.recalibrations))
    }

    // MARK: - L'arrêt

    /// Un disque de bureau ne parque pas au repos : le bras reste où il est.
    @Test("Un disque de bureau ne parque pas au repos")
    func desktopDoesNotPark() {
        let trace = Self.run(DriveCatalog.fireball1996, [Self.request(lba: 0)],
                             idle: .desktop(year: 1996), spinUp: 0.9)
        #expect(trace.parkAt == nil)
        #expect(trace.events.filter { Self.isSeek($0.kind) }.count == 1)
    }

    /// La coupure en fin de journée : le bras se retire au moyeu, le moteur
    /// s'arrête, et les têtes se posent quand le plateau a assez ralenti.
    @Test("La coupure retire le bras, puis les têtes se posent")
    func powerOffLands() throws {
        let trace = Self.run(DriveCatalog.fireball1996, [Self.request(lba: 0)],
                             idle: .desktop(year: 1996, stopAfter: 1.0, stopDuration: 3.5),
                             spinUp: 0.9)
        let work = try #require(trace.timings.last).end
        let parkAt = try #require(trace.parkAt)
        let stop = Self.times(trace) { if case .spinDown = $0 { true } else { false } }
        let land = Self.times(trace) { if case .headLand = $0 { true } else { false } }
        #expect(stop == [work + 1.0])
        #expect(parkAt < work + 1.0)
        #expect(land.count == 1)
        let landing = land[0] - stop[0]
        #expect(abs(landing - StartupSequence.landingDelay(stopDuration: 3.5)) < 1e-9)
        #expect(abs(trace.spindle.speed(at: land[0]) - StartupSequence.landingSpeed) < 1e-2)
    }

    /// La coupure comptée depuis la dernière requête n'est connue qu'à la fin :
    /// le plateau qu'on voit doit ralentir avec celui qu'on entend.
    @Test("Le plateau affiché s'arrête avec la coupure")
    func displayedSpindleStops() {
        let drive = DriveCatalog.fireball1996
        let setup = PassSetup(geometry: drive.geometry, seekModel: drive.seekModel,
                              spinUpAt: 0.35, spinUpDuration: 1.2,
                              idle: .desktop(year: 1996, coldStart: true, stopAfter: 1, stopDuration: 3.5),
                              tail: 3.5, year: 1996)
        let recorder = PassRecorder()
        let pipeline = PassPipeline(setup: setup, deliver: recorder.receive)
        pipeline.serve(Self.request(lba: 100_000))
        let end = pipeline.finish()
        let live = LivePass(session: nil, geometry: drive.geometry, seekModel: drive.seekModel,
                            spindle: setup.spindle, armReady: setup.armReady, phases: [])
        live.absorb(recorder.history)
        #expect(end.stopAt != nil)
        #expect(live.spindle.speed(at: end.duration) < 0.3)
        // Avant la première lecture, le bras attend au bord.
        #expect(live.platter.frame(at: 1.551).cylinder == 0)
        #expect(live.platter.frame(at: 0.5).cylinder == Double(drive.geometry.parkCylinder))
    }

    // MARK: - La cadence des pistes

    /// Une lecture séquentielle sur un disque à une tête franchit une piste à
    /// chaque tour. Plus aucun pas n'est supprimé : ils partent en trains.
    @Test("Les pas de piste d'une lecture séquentielle partent tous, en trains")
    func trackStepsAreNotDecimated() {
        let rev = 60.0 / 7_200
        var events: [DiskEvent] = [DiskEvent(time: 0, kind: .spinUp(duration: 0.9))]
        for k in 0..<300 { events.append(DiskEvent(time: 1 + Double(k) * rev, kind: .trackStep)) }
        events.append(DiskEvent(time: 10, kind: .trackStep))
        var stream = CueStream(cylinders: 1_000)
        events.forEach { stream.ingest($0) }
        stream.finish()
        var cues: [AudioCue] = []
        stream.release(into: &cues)

        var trains: [[TrainTick]] = []
        var singles = 0
        for cue in cues {
            switch cue.kind {
            case .tickTrain(let ticks, let duration):
                trains.append(ticks)
                #expect(duration < AudioCueBuilder.maxChatterDuration)
            case .tick: singles += 1
            default: break
            }
        }
        #expect(trains.reduce(0) { $0 + $1.count } == 300)
        #expect(trains.count == 3)
        #expect(singles == 1)
        // Pas un de moins : l'écart entre deux tics est un tour.
        for train in trains {
            for (a, b) in zip(train, train.dropFirst()) { #expect(abs(b.offset - a.offset - rev) < 1e-9) }
        }
    }
}
