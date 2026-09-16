import Foundation
import DiskCore

/// Événement mécanique audible produit par le disque.
enum DiskEventKind {
    case spinUp(duration: Double)
    case spinDown(duration: Double)
    /// Déplacement du bras d'un cylindre à un autre.
    case seek(SeekProfile)
    /// Commutation électronique vers une autre tête du même cylindre : un tic
    /// beaucoup plus discret qu'un seek, mais bien présent en lecture séquentielle.
    case headSwitch
    /// Passage à la piste suivante en fin de cylindre.
    case trackStep
    /// Transfert de données. Acoustiquement quasi muet sur un disque sain :
    /// ce qui s'entend d'une grosse lecture, ce sont les pas de piste.
    case transfer(duration: Double, sectors: Int, isWrite: Bool)
}

struct DiskEvent {
    let time: Double
    let kind: DiskEventKind
}

/// Position de la tête pendant une requête, pour l'affichage.
///
/// Un seul échantillon par requête, mais qui porte **son début et sa fin** :
/// pendant un transfert séquentiel le bras avance d'un cylindre tous les
/// `heads × spt` secteurs, à cadence constante à l'intérieur d'une zone. Deux
/// bornes suffisent donc à retrouver la position à n'importe quel instant, là
/// où un échantillon par piste ferait exploser la trace sur une lecture de
/// plusieurs mégaoctets. L'interpolation n'est approchée qu'au franchissement
/// d'une frontière de zone — seize pour tout le disque, l'erreur reste sous le
/// cylindre hors requêtes de plusieurs centaines de mégaoctets.
///
/// Les largeurs sont choisies pour que la structure garde son pas de vingt-quatre
/// octets : une passe d'époque en aligne des millions.
struct HeadSample {
    /// Instant où la tête se pose sur le premier secteur, latence purgée.
    let time: Double
    /// Durée du transfert. `Float` : soixante nanosecondes de résolution sur
    /// une seconde, trois ordres de grandeur sous ce que l'œil distingue.
    let duration: Float
    let cylinder: Int32
    /// Cylindre atteint en fin de transfert. Égal à `cylinder` neuf fois sur dix.
    let endCylinder: Int32
    let head: UInt8
    let isWrite: Bool

    var endTime: Double { time + Double(duration) }
}

struct TraceStats {
    var requestCount = 0
    var seekCount = 0
    var totalSeekDistance = 0
    var fullStrokeSeeks = 0
    var bytesRead = 0
    var bytesWritten = 0
    var busySeconds = 0.0
    /// Où passe le temps d'une passe, requête par requête : bras en
    /// mouvement (commutations de tête comprises), attente du secteur, pas de
    /// piste pendant un transfert, calcul de la machine entre deux lectures,
    /// et disque au repos. Avec `busySeconds`, ils recomposent l'horloge.
    var seekSeconds = 0.0
    var rotationSeconds = 0.0
    var stepSeconds = 0.0
    var thinkSeconds = 0.0
    var waitSeconds = 0.0

    var averageSeekDistance: Int {
        seekCount > 0 ? totalSeekDistance / seekCount : 0
    }
}

/// Instant de prise en charge et instant de fin d'une requête, dans l'ordre de
/// la liste passée au simulateur. C'est ce qui permet de dater après coup les
/// étapes d'un scénario en boucle fermée — une défragmentation n'a pas de débit
/// imposé : chaque opération part quand le disque se libère.
struct RequestTiming {
    let start: Double
    let end: Double
}

/// Ce que fait le disque quand plus personne ne lui demande rien.
///
/// Les deux gestes d'un disque au repos sont mécaniques et audibles, et aucun
/// n'appartient à une requête : le bras s'en va se parquer, et le moteur
/// finit par être coupé. Les décrire ici plutôt que dans chaque scénario
/// évite que « le disque ne fait rien » se traduise par un silence.
struct IdleBehavior {

    /// Délai d'inactivité, compté depuis la dernière requête, au bout duquel le
    /// bras retourne au cylindre de parcage. `nil` pour un disque qu'on laisse
    /// là où il s'est arrêté.
    ///
    /// C'est bien un délai et non un instant : une passe en boucle fermée ne
    /// connaît pas sa propre durée avant d'être simulée.
    var parkAfter: Double?

    /// Instant de coupure du moteur, celui-là absolu : il vient de la
    /// chronologie d'un scénario, pas de la fin du travail.
    var stopAt: Double?
    var stopDuration: Double = 0

    /// Un disque qu'on laisse tourner, bras là où il est.
    static let none = IdleBehavior()
}

struct DiskTrace {
    let events: [DiskEvent]
    let headSamples: [HeadSample]
    let timings: [RequestTiming]
    /// Montée en régime du plateau, pour l'affichage.
    let spindle: SpindleTimeline
    /// Instant où le bras repart se parquer, s'il le fait.
    let parkAt: Double?
    let duration: Double
    let stats: TraceStats

    /// La même trace, débarrassée de ce qui ne sert qu'une fois.
    ///
    /// Les événements mécaniques sont consommés par `AudioCueBuilder` et les
    /// dates de requêtes par la construction des séries d'affichage ; passé ce
    /// point, plus personne ne les lit. Sur une passe de six gigaoctets ils
    /// pèsent trois millions et un million d'éléments — les garder vivants
    /// pendant toute l'écoute coûterait deux cents mégaoctets pour rien.
    func summarized() -> DiskTrace {
        DiskTrace(events: [], headSamples: headSamples, timings: [],
                  spindle: spindle, parkAt: parkAt, duration: duration, stats: stats)
    }
}

/// Rejoue une liste de requêtes bloc sur la géométrie et le modèle de seek,
/// et en déduit la chronologie mécanique exacte.
///
/// File d'attente FIFO, sans réordonnancement d'ascenseur : c'est volontaire,
/// un contrôleur IDE de cette époque ne réordonnait quasiment rien, et c'est
/// précisément ce qui rend le crépitement si dense.
enum DiskSimulator {

    /// Toute une passe d'un coup, et tout ce qu'elle a produit. C'est la
    /// mécanique pas à pas, nourrie d'une liste : les tests et les petits
    /// scénarios s'en servent, la lecture au fil de l'eau passe par
    /// `DiskMechanics` directement.
    static func run(geometry: DriveGeometry,
                    seekModel: SeekModel,
                    requests: [BlockRequest],
                    totalDuration: Double,
                    spinUpAt: Double,
                    spinUpDuration: Double,
                    idle: IdleBehavior = .none) -> DiskTrace {

        var events: [DiskEvent] = []
        var samples: [HeadSample] = []
        var timings: [RequestTiming] = []
        // Une passe d'époque produit des millions d'événements. Sans réserve,
        // chaque doublement de tableau recopie tout et garde transitoirement
        // les deux versions : c'est un pic de mémoire pour rien.
        timings.reserveCapacity(requests.count)
        samples.reserveCapacity(requests.count)
        events.reserveCapacity(requests.count * 3)

        var mechanics = DiskMechanics(geometry: geometry, seekModel: seekModel,
                                      spinUpAt: spinUpAt, spinUpDuration: spinUpDuration,
                                      idle: idle)
        mechanics.start(events: &events)
        for request in requests {
            let served = mechanics.serve(request, events: &events)
            samples.append(served.sample)
            timings.append(served.timing)
        }
        let parkAt = mechanics.finish(events: &events)
        // Déjà dans l'ordre, sauf si la coupure du moteur tombe avant la fin du
        // travail — un scénario dont les requêtes débordent sur son extinction.
        events.sort { $0.time < $1.time }

        let end = max(max(totalDuration, mechanics.clock), parkAt ?? 0)
        return DiskTrace(events: events, headSamples: samples, timings: timings,
                         spindle: mechanics.spindle, parkAt: parkAt, duration: end,
                         stats: mechanics.stats)
    }
}

/// Le disque, une requête après l'autre.
///
/// Rien de ce qu'il calcule ne dépend des requêtes à venir : chacune part quand
/// la précédente est finie et que le système l'a émise, le bras est là où la
/// précédente l'a laissé, le plateau à l'angle que donne l'horloge. C'est cette
/// causalité qui permet de simuler une passe **à mesure qu'on la planifie**,
/// sans jamais tenir la liste de ses requêtes.
///
/// Les événements sortent dans l'ordre chronologique : la mise en rotation
/// d'abord, puis ceux de chaque requête, qui commence où la précédente finit,
/// puis le parcage et la coupure du moteur.
struct DiskMechanics {

    let geometry: DriveGeometry
    let seekModel: SeekModel
    let spinUpAt: Double
    let spinUpDuration: Double
    let idle: IdleBehavior

    /// Fin de la dernière requête servie — ou fin de la mise en rotation, si
    /// aucune ne l'a encore été.
    private(set) var clock: Double
    private(set) var stats = TraceStats()
    private var headCylinder: Int
    private var headIndex = 0
    private var served = false

    init(geometry: DriveGeometry, seekModel: SeekModel,
         spinUpAt: Double, spinUpDuration: Double, idle: IdleBehavior = .none) {
        self.geometry = geometry
        self.seekModel = seekModel
        self.spinUpAt = spinUpAt
        self.spinUpDuration = spinUpDuration
        self.idle = idle
        self.clock = spinUpAt + spinUpDuration
        // Au repos le bras est parqué au diamètre intérieur (ou sur une rampe
        // hors plateau). Le premier accès est donc une course quasi complète :
        // c'est le « clac » franc qu'on entend juste après le lancement du moteur.
        self.headCylinder = geometry.parkCylinder
    }

    /// La rotation du plateau, connue d'avance : la montée comme la coupure
    /// sont des dates, pas des conséquences des requêtes.
    var spindle: SpindleTimeline {
        SpindleTimeline(spinUpAt: spinUpAt, duration: spinUpDuration,
                        rpm: geometry.rpm,
                        spinDownAt: idle.stopAt,
                        spinDownDuration: idle.stopDuration)
    }

    func start(events: inout [DiskEvent]) {
        events.append(DiskEvent(time: spinUpAt, kind: .spinUp(duration: spinUpDuration)))
    }

    mutating func serve(_ request: BlockRequest,
                        events: inout [DiskEvent]) -> (sample: HeadSample, timing: RequestTiming) {
        let revolution = geometry.revolutionDuration

        // Le disque ne repart pas à la milliseconde où il s'est arrêté :
        // la machine a peut-être quelque chose à faire de ce qu'elle vient
        // de lire. `thinkTime` est nul partout sauf pour un démarrage.
        let issued = max(clock + request.thinkTime, request.issueTime)
        // Le calcul ne compte que ce qui s'est écoulé avant la prise en charge ;
        // le reste de l'écart est un disque qui attend qu'on lui demande.
        let thought = max(min(issued, clock + request.thinkTime) - clock, 0)
        stats.thinkSeconds += thought
        stats.waitSeconds += max(issued - clock - thought, 0)
        var t = issued
        let target = geometry.position(ofLBA: request.lba)

        // 1. Déplacement du bras.
        if target.cylinder != headCylinder {
            let distance = abs(target.cylinder - headCylinder)
            let profile = seekModel.profile(distance: distance)
            events.append(DiskEvent(time: t, kind: .seek(profile)))
            stats.seekCount += 1
            stats.totalSeekDistance += distance
            if distance > geometry.cylinders / 2 { stats.fullStrokeSeeks += 1 }
            t += profile.total
            stats.seekSeconds += profile.total
            headCylinder = target.cylinder
        } else if target.head != headIndex {
            events.append(DiskEvent(time: t, kind: .headSwitch))
            t += seekModel.headSwitchDuration
            stats.seekSeconds += seekModel.headSwitchDuration
        }
        headIndex = target.head

        // 2. Latence rotationnelle : attendre que le secteur visé passe
        //    sous la tête. En moyenne un demi-tour, soit 4,17 ms ici.
        let spt = geometry.sectorsPerTrack(cylinder: headCylinder)
        let currentAngle = (t / revolution).truncatingRemainder(dividingBy: 1.0)
        let targetAngle = Double(target.sector) / Double(spt)
        var delta = targetAngle - currentAngle
        if delta < 0 { delta += 1 }
        t += delta * revolution
        stats.rotationSeconds += delta * revolution

        // L'échantillon d'affichage est refermé après le transfert, une fois
        // connu le cylindre d'arrivée : c'est lui qui fait avancer le bras
        // à l'écran pendant une lecture séquentielle.
        let sampleTime = t
        let sampleCylinder = headCylinder
        let sampleHead = headIndex

        // 3. Transfert, piste par piste.
        var remaining = request.sectorCount
        var sector = target.sector
        var transferSeconds = 0.0

        while remaining > 0 {
            let spt = geometry.sectorsPerTrack(cylinder: headCylinder)
            let onThisTrack = min(remaining, spt - sector)
            let dt = Double(onThisTrack) / Double(spt) * revolution

            events.append(DiskEvent(time: t, kind: .transfer(
                duration: dt, sectors: onThisTrack, isWrite: request.isWrite)))

            t += dt
            transferSeconds += dt
            remaining -= onThisTrack
            sector = 0

            guard remaining > 0 else { break }

            // Passage à la piste logique suivante.
            if headIndex + 1 < geometry.heads {
                headIndex += 1
                events.append(DiskEvent(time: t, kind: .headSwitch))
                t += seekModel.headSwitchDuration
                stats.stepSeconds += seekModel.headSwitchDuration
            } else if headCylinder + 1 < geometry.cylinders {
                headIndex = 0
                headCylinder += 1
                events.append(DiskEvent(time: t, kind: .trackStep))
                t += seekModel.duration(distance: 1)
                stats.stepSeconds += seekModel.duration(distance: 1)
            } else {
                // Plus de piste suivante : la requête déborde du disque. La
                // tronquer, parce que c'est ce qu'un disque répond. Bloquer
                // le cylindre au dernier faisait relire la même piste
                // jusqu'à épuisement du compte — des pas de piste qui ne
                // menaient nulle part, et un bras collé au moyeu.
                break
            }
        }

        let sample = HeadSample(time: sampleTime,
                                duration: Float(t - sampleTime),
                                cylinder: Int32(sampleCylinder),
                                endCylinder: Int32(headCylinder),
                                head: UInt8(min(sampleHead, Int(UInt8.max))),
                                isWrite: request.isWrite)

        let bytes = (request.sectorCount - remaining) * DriveGeometry.bytesPerSector
        if request.isWrite { stats.bytesWritten += bytes } else { stats.bytesRead += bytes }
        stats.requestCount += 1
        stats.busySeconds += transferSeconds

        clock = t
        served = true
        return (sample, RequestTiming(start: issued, end: t))
    }

    /// Le travail est fini ; le disque, lui, ne l'est pas. Rend l'instant où le
    /// bras repart se parquer, s'il le fait.
    ///
    /// Le parcage n'entre pas dans `stats` : ces compteurs décrivent ce qu'on
    /// a demandé au disque, et personne n'a demandé celui-ci. L'y inclure
    /// décalerait le seek moyen d'une passe sans qu'aucune requête ait bougé.
    mutating func finish(events: inout [DiskEvent]) -> Double? {
        var tail: [DiskEvent] = []
        var parkAt: Double?
        if let delay = idle.parkAfter, served {
            let distance = abs(geometry.parkCylinder - headCylinder)
            let travel = seekModel.duration(distance: distance)
            // Un disque parque toujours ses têtes **avant** de couper le
            // moteur : sans couple, plus de coussin d'air. Si la coupure vient
            // avant le délai d'inactivité, c'est elle qui déclenche le voyage.
            var moment = clock + delay
            if let stopAt = idle.stopAt { moment = min(moment, stopAt - travel) }
            moment = max(moment, clock)
            if distance > 0 {
                tail.append(DiskEvent(
                    time: moment, kind: .seek(seekModel.profile(distance: distance))))
                parkAt = moment
                headCylinder = geometry.parkCylinder
            }
        }

        if let stopAt = idle.stopAt {
            tail.append(DiskEvent(time: stopAt, kind: .spinDown(duration: idle.stopDuration)))
        }

        tail.sort { $0.time < $1.time }
        events.append(contentsOf: tail)
        return parkAt
    }
}
