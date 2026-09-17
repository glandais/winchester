import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que le plateau affiché doit au disque simulé.
///
/// La couche vue n'est pas testable, mais tout ce qu'elle dessine se décide
/// ici : position du bras, montée en régime, fenêtre de traînée. Ce sont les
/// invariants de ce fichier qui garantissent que ce qu'on voit est ce qu'on
/// entend.
@Suite("Plateau affiché")
struct PlatterTests {

    private static let drive = DriveCatalog.fireball1996

    private static func request(at issueTime: Double, lba: Int,
                                sectors: Int = 8, isWrite: Bool = false) -> BlockRequest {
        BlockRequest(issueTime: issueTime, lba: lba, sectorCount: sectors,
                     isWrite: isWrite, phaseIndex: 0)
    }

    private static func track(requests: [BlockRequest],
                              spinUpAt: Double = 0,
                              spinUpDuration: Double = 0.9) -> PlatterTrack {
        let geometry = drive.geometry
        let seekModel = drive.seekModel
        let trace = DiskSimulator.run(geometry: geometry, seekModel: seekModel,
                                      requests: requests, totalDuration: 0,
                                      spinUpAt: spinUpAt, spinUpDuration: spinUpDuration)
        return PlatterTrack(geometry: geometry, seekModel: seekModel,
                            samples: trace.headSamples, spindle: trace.spindle)
    }

    // MARK: - Position du bras

    /// Le simulateur parque le bras au moyeu, et c'est ce qui fait du premier
    /// accès une course quasi complète — le « clac » du démarrage. L'afficher au
    /// bord, comme avant, donnait à voir l'inverse de ce qu'on entendait.
    @Test("Avant le premier accès, le bras est parqué au moyeu")
    func parkedBeforeFirstAccess() {
        let geometry = Self.drive.geometry
        let track = Self.track(requests: [Self.request(at: 2, lba: 0)])

        let frame = track.frame(at: 0.5)
        #expect(frame.activity == .parked)
        #expect(frame.cylinder == Double(geometry.parkCylinder))
        #expect(frame.cylinder > Double(geometry.cylinders) * 0.9)
        #expect(frame.trail.isEmpty)
    }

    /// Le simulateur fait avancer la tête piste après piste pendant un gros
    /// transfert ; la vue le montrait immobile, puis sautant.
    @Test("Pendant une lecture séquentielle, le bras descend vers l'intérieur")
    func armAdvancesDuringSequentialRead() throws {
        let geometry = Self.drive.geometry
        // Quatre mégaoctets d'affilée, soit plusieurs dizaines de cylindres.
        let sectors = 8192
        let track = Self.track(requests: [Self.request(at: 0, lba: 0, sectors: sectors)])

        let sample = try #require(track.samples.first)
        #expect(sample.endCylinder > sample.cylinder, "le transfert change de cylindre")

        // La position doit croître continûment entre le début et la fin.
        let start = track.frame(at: sample.time)
        let middle = track.frame(at: sample.time + Double(sample.duration) / 2)
        let end = track.frame(at: sample.endTime)

        #expect(start.cylinder == Double(sample.cylinder))
        #expect(end.cylinder == Double(sample.endCylinder))
        #expect(middle.cylinder > start.cylinder)
        #expect(middle.cylinder < end.cylinder)
        #expect(start.activity == .reading)
        #expect(middle.activity == .reading)

        // Et le compte doit tomber sur la géométrie : un cylindre tous les
        // `heads × spt` secteurs.
        let spanned = Int(sample.endCylinder - sample.cylinder)
        let expected = sectors / geometry.sectorsPerCylinder(Int(sample.cylinder))
        #expect(abs(spanned - expected) <= 1)
    }

    @Test("Une écriture se distingue d'une lecture")
    func writeIsReported() throws {
        let track = Self.track(requests: [Self.request(at: 0, lba: 5_000, isWrite: true)])
        let sample = try #require(track.samples.first)
        #expect(track.frame(at: sample.time).activity == .writing)
    }

    /// Un transfert de quelques millisecondes tombe le plus souvent entre deux
    /// images : la pile de faces ne peut pas se contenter de l'instant présent.
    @Test("Une face s'allume pour un transfert glissé entre deux images")
    func faceLightsForTransferBetweenFrames() throws {
        let track = Self.track(requests: [Self.request(at: 0, lba: 5_000, isWrite: true)])
        let sample = try #require(track.samples.first)
        let face = Int(sample.head)

        let justAfter = track.frame(at: sample.endTime + 0.005)
        #expect(justAfter.activity != .writing)
        #expect(justAfter.faces[face] == FaceLight(intensity: 1, isWrite: true))

        let fading = try #require(track.frame(at: sample.endTime + 0.07).faces[face])
        #expect(fading.intensity > 0 && fading.intensity < 1)

        #expect(track.frame(at: sample.endTime + 1).faces[face] == nil)
    }

    /// Le bras ne doit jamais se téléporter : entre deux images, il ne parcourt
    /// que ce que la loi de seek autorise.
    @Test("La position du bras est continue d'une image à l'autre")
    func armMovesContinuously() {
        let geometry = Self.drive.geometry
        var requests: [BlockRequest] = []
        var generator = SeededGenerator(seed: 42)
        for i in 0..<400 {
            let lba = Int(generator.next() % UInt64(geometry.totalSectors - 64))
            requests.append(Self.request(at: Double(i) * 0.004, lba: lba, isWrite: i % 3 == 0))
        }
        let track = Self.track(requests: requests)

        let step = 1.0 / 60
        var time = 0.0
        var previous = track.frame(at: time).cylinder
        var jumps = 0
        while time < 3.0 {
            time += step
            let current = track.frame(at: time).cylinder
            // Une pleine course prend bien plus qu'une image : un saut de tout
            // le disque en 16 ms serait forcément un artefact d'affichage.
            if abs(current - previous) > Double(geometry.cylinders) * 0.95 { jumps += 1 }
            previous = current
        }
        #expect(jumps == 0)
    }

    /// Le bras part au plus tard, pas au plus tôt : un disque ne déplace pas sa
    /// tête pour la laisser attendre ensuite que le secteur arrive.
    @Test("Le bras attend, puis s'élance juste avant l'accès")
    func armLeavesAtTheLastMoment() {
        let geometry = Self.drive.geometry
        let track = Self.track(requests: [
            Self.request(at: 0, lba: 0),
            Self.request(at: 1.0, lba: geometry.totalSectors - 64),
        ])
        #expect(track.samples.count == 2)
        let first = track.samples[0]
        let second = track.samples[1]

        // Au milieu du repos, le bras est encore là où le premier accès l'a
        // laissé, et il ne bouge pas.
        let resting = track.frame(at: (first.endTime + second.time) / 2)
        #expect(resting.activity == .idle)
        #expect(resting.cylinder == Double(first.endCylinder))

        // Juste avant le second accès, il est en route.
        let travelling = track.frame(at: second.time - 0.005)
        #expect(travelling.activity == .seeking)
        #expect(travelling.cylinder > Double(first.endCylinder))
        #expect(travelling.cylinder < Double(second.cylinder))
    }

    // MARK: - Rotation

    /// La rotation affichée est l'intégrale de la vitesse, et non `ω·t` : le
    /// plateau accomplit moins de tours tant qu'il monte en régime.
    @Test("Le plateau monte en régime avant de tourner à vitesse nominale")
    func spindleRampsUp() {
        let track = Self.track(requests: [Self.request(at: 3, lba: 0)],
                               spinUpAt: 0.35, spinUpDuration: 6)

        #expect(track.frame(at: 0.2).spin == 0)
        #expect(track.frame(at: 0.2).turns == 0)

        let early = track.frame(at: 1.0)
        let late = track.frame(at: 8.0)
        #expect(early.spin > 0)
        #expect(early.spin < 0.95, "à une seconde, le plateau n'est pas encore lancé")
        // Quatre constantes de temps après le départ, soit 98 % — un moteur de
        // broche n'atteint jamais son régime, il l'approche.
        #expect(late.spin > 0.98)

        // Monotone, et jamais plus rapide que le régime nominal.
        var previous = 0.0
        for i in 0...200 {
            let turns = track.frame(at: Double(i) * 0.05).turns
            #expect(turns >= previous)
            previous = turns
        }

        // Le retard accumulé pendant la rampe vaut exactement la constante de
        // temps, exprimée en tours.
        let rps = Self.drive.geometry.rpm / 60 / PlatterTrack.rotationSlowdown
        let tau = SpindleTimeline.timeConstant(forRamp: 6)
        // Le résidu exponentiel n'est jamais tout à fait nul : à vingt secondes
        // il reste cinq centièmes de millième de tour.
        let ideal = (20.0 - 0.35) * rps
        #expect(abs(track.frame(at: 20).turns - (ideal - tau * rps)) < 1e-4)
    }

    /// C'est tout l'intérêt d'un ralenti proportionnel : deux disques d'époques
    /// différentes ne tournent pas pareil à l'écran, comme ils ne sonnent pas
    /// pareil.
    @Test("Un disque deux fois plus rapide tourne deux fois plus vite à l'écran")
    func apparentSpeedFollowsRPM() {
        func turnsPerSecond(rpm: Double) -> Double {
            let spindle = SpindleTimeline(spinUpAt: 0, duration: 0.2, rpm: rpm)
            return (spindle.revolutions(at: 11) - spindle.revolutions(at: 1))
                / 10 / PlatterTrack.rotationSlowdown
        }
        let slow = turnsPerSecond(rpm: 3_600)
        let fast = turnsPerSecond(rpm: 7_200)

        #expect(abs(fast / slow - 2) < 1e-9)
        // Et les deux restent dans la plage où l'œil suit sans repliement.
        #expect(slow > 0.4 && fast < 1.5)
    }

    // MARK: - Traînée

    /// La traînée tourne avec le plateau : au-delà d'un tour apparent, les
    /// points anciens repasseraient sur les récents.
    @Test("La traînée ne dure jamais plus d'un tour apparent")
    func trailLastsOneApparentTurn() {
        for rpm in [3_600.0, 5_400.0, 7_200.0] {
            let geometry = DriveGeometry.era(model: "test", capacityBytes: 1_000_000_000,
                                             rpm: Int(rpm), year: 1996)
            let track = PlatterTrack(geometry: geometry, seekModel: Self.drive.seekModel,
                                     samples: [], spindle: SpindleTimeline(spinUpAt: 0,
                                                                           duration: 1,
                                                                           rpm: rpm))
            let apparentTurnsPerSecond = rpm / 60 / PlatterTrack.rotationSlowdown
            #expect(track.trailWindow * apparentTurnsPerSecond <= 1.000_001)
            #expect(track.trailWindow >= 0.8)
        }
    }

    /// Le fondu se calculait au rang et non à l'âge : deux accès distants d'une
    /// seconde s'affichaient presque aussi vifs l'un que l'autre, et un train
    /// dense étalait sur tout le dégradé quatre-vingt-dix millisecondes.
    @Test("La traînée ne retient que les accès de sa fenêtre")
    func trailKeepsOnlyRecentAccesses() {
        var requests: [BlockRequest] = []
        for i in 0..<60 {
            requests.append(Self.request(at: Double(i) * 0.1, lba: i * 1_000))
        }
        let track = Self.track(requests: requests)
        let frame = track.frame(at: 4.0)

        #expect(!frame.trail.isEmpty)
        for index in frame.trail {
            let age = frame.time - track.samples[index].time
            #expect(age >= 0)
            #expect(age <= track.trailWindow + 0.2,
                    "aucun point ne survit à sa fenêtre")
        }
        #expect(frame.trail.count <= PlatterTrack.trailLimit)
    }
}
