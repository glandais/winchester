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
    /// Les têtes se décollent du plateau à la mise en rotation : la *stiction*,
    /// le claquement sec d'un disque qu'on allume.
    case headUnstick
    /// Les têtes se posent sur la zone d'atterrissage quand le plateau ralentit
    /// assez pour que le coussin d'air ne les porte plus : le petit *crac* qui
    /// termine un arrêt.
    case headLand
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
    /// Temps pendant lequel une requête a attendu que le disque finisse de se
    /// recalibrer, et nombre de recalibrations. Personne ne les a demandées :
    /// elles n'entrent ni dans les seeks ni dans leur distance moyenne.
    var recalibrationSeconds = 0.0
    var recalibrations = 0

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

/// Ce que fait le disque de lui-même, en dehors des requêtes.
///
/// Les gestes d'un disque qu'on ne sollicite pas sont mécaniques et audibles,
/// et aucun n'appartient à une requête : la mise en route, la recalibration
/// thermique des disques d'avant 1997, le bras qui se retire et les têtes qui
/// se posent quand le moteur est coupé. Les décrire ici plutôt que dans chaque
/// scénario évite que « le disque ne fait rien » se traduise par un silence.
struct IdleBehavior {

    /// Délai d'inactivité, compté depuis la dernière requête, au bout duquel le
    /// bras retourne au cylindre de parcage. `nil` pour un disque qu'on laisse
    /// là où il s'est arrêté — c'est le cas de tous les disques de bureau de la
    /// galerie.
    ///
    /// **Aucun disque à plateaux de cette période ne le faisait** : décharger
    /// les têtes au repos est une pratique des disques à rampe, les portables
    /// des années 2000. Un disque de bureau laisse le bras où il est et ne se
    /// retire qu'à la coupure. Le mécanisme reste pour ces disques-là ; aucun
    /// scénario ne s'en sert plus depuis le chantier 25.
    ///
    /// C'est bien un délai et non un instant : une passe en boucle fermée ne
    /// connaît pas sa propre durée avant d'être simulée.
    var parkAfter: Double?

    /// Instant de coupure du moteur, celui-là absolu : il vient de la
    /// chronologie d'un scénario, pas de la fin du travail.
    var stopAt: Double?
    var stopDuration: Double = 0

    /// Coupure comptée depuis la dernière requête : la machine s'éteint tant de
    /// secondes après avoir fini d'écrire. Ignoré si `stopAt` est donné.
    var stopAfter: Double?

    /// La montée en régime est une vraie mise sous tension : les têtes se
    /// décollent, puis le disque cherche la piste 0 et charge son
    /// asservissement avant d'être prêt — et c'est **au bord** du plateau que
    /// le bras attend la première requête. `false` pour un plateau qui tourne
    /// déjà, dont la rampe n'est qu'un fondu.
    var coldStart = false

    /// Recalibration thermique périodique, pour les disques qui la faisaient.
    var recalibration: ThermalRecalibration?

    /// Un disque qu'on laisse tourner, bras là où il est.
    static let none = IdleBehavior()

    /// Un disque de bureau de l'année donnée : jamais parqué au repos, et
    /// recalibré périodiquement s'il est d'avant 1997.
    static func desktop(year: Int, coldStart: Bool = false,
                        stopAfter: Double? = nil, stopDuration: Double = 0) -> IdleBehavior {
        IdleBehavior(parkAfter: nil, stopDuration: stopDuration, stopAfter: stopAfter,
                     coldStart: coldStart,
                     recalibration: ThermalRecalibration.era(year: year))
    }
}

/// La recalibration thermique : toutes les quelques minutes, le disque
/// interrompt tout et va relire ses repères de position, parce que ses plateaux
/// et son bras se sont dilatés. Une seconde de crépitement, l'événement sonore
/// signature des disques du début des années 90 — au point que les
/// constructeurs ont dû sortir des modèles « AV » sans recalibration pour le
/// montage vidéo.
///
/// Ce que les sources donnent : la période (« quelques minutes »), la durée
/// (« une seconde »), et l'époque (avant ~1996). Ce qu'elles ne donnent pas, et
/// qui est donc un choix : l'ordre des repères visités. Ici trois zones —
/// bord, moyeu, milieu — deux fois, et à chacune un aller-retour court autour
/// du repère, deux tours de lecture chaque fois.
struct ThermalRecalibration: Equatable {

    /// Délai de la première, compté depuis le disque prêt. Deux minutes : un
    /// démarrage de la galerie en dure au plus 70 s, il n'en contient aucune.
    var firstAfter: Double = 120
    /// Intervalle entre deux recalibrations.
    var period: Double = 240
    /// Tours de plateau passés sur chaque repère.
    var dwellRevolutions: Double = 2

    /// Dernière année de la galerie à recalibrer : 1993 et 1996 le font, 1999
    /// ne le fait plus.
    static let lastYear = 1996

    static func era(year: Int) -> ThermalRecalibration? {
        year <= lastYear ? ThermalRecalibration() : nil
    }

    /// Les cylindres visités, dans l'ordre.
    func stops(cylinders: Int) -> [Int] {
        let last = max(cylinders - 1, 0)
        let nudge = max(cylinders / 200, 2)
        var result: [Int] = []
        for _ in 0..<2 {
            for anchor in [0, last, last / 2] {
                let away = anchor + nudge <= last ? anchor + nudge : anchor - nudge
                result += [anchor, max(away, 0), anchor, max(min(anchor + nudge / 2, last), 0)]
            }
        }
        return result
    }
}

/// La mise sous tension d'un disque, dans l'ordre où elle s'entend.
enum StartupSequence {

    /// Les têtes se décollent dès que le moteur donne son couple de démarrage.
    static let unstickDelay = 0.05

    /// La recherche de la piste 0 : une course complète depuis la zone de
    /// parcage, puis quelques pas courts pour charger l'asservissement, et le
    /// bras reste au bord.
    static func stops(cylinders: Int) -> [Int] {
        let step = max(cylinders / 256, 2)
        return [0, step, 0, 4 * step, 0]
    }

    /// Tours de plateau passés sur chaque arrêt.
    static let dwellRevolutions = 2.0

    /// Les têtes d'un disque à atterrissage sur le plateau (CSS) se posent
    /// quand le régime est tombé assez bas pour que le coussin d'air ne les
    /// porte plus. Aucune fiche ne donne ce seuil : 40 % du régime est une
    /// estimation.
    static let landingSpeed = 0.4

    /// Délai entre la coupure du moteur et l'atterrissage, sur la même loi du
    /// premier ordre que `SpindleTimeline`.
    static func landingDelay(stopDuration: Double) -> Double {
        -SpindleTimeline.timeConstant(forRamp: stopDuration) * log(landingSpeed)
    }
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

    /// Le décalage angulaire d'une piste à l'autre, déduit de la loi de seek de
    /// ce disque : c'est lui qui rend gratuit le franchissement de piste au
    /// milieu d'une lecture séquentielle.
    let skew: DriveGeometry.TrackSkew

    /// Tolérance sur l'angle, en tours. La somme des durées accumule quelques
    /// unités du dernier chiffre, et un angle négatif de `1e-12` n'est pas un
    /// tour à rattraper : c'est un zéro mal arrondi. Sans cette borne, une
    /// lecture strictement contiguë perdait un tour de plateau environ une fois
    /// sur trois.
    private static let angularTolerance = 1e-9

    /// Fin de la dernière requête servie — ou fin de la mise en rotation, si
    /// aucune ne l'a encore été.
    private(set) var clock: Double
    private(set) var stats = TraceStats()
    private var headCylinder: Int
    private var headIndex = 0
    private var served = false
    /// Prochaine recalibration thermique, si le disque en fait.
    private var nextRecalibration: Double?
    /// Instant de coupure du moteur, une fois connu : daté d'avance par le
    /// scénario, ou compté depuis la dernière requête à la fin du travail.
    private(set) var stopAt: Double?

    init(geometry: DriveGeometry, seekModel: SeekModel,
         spinUpAt: Double, spinUpDuration: Double, idle: IdleBehavior = .none) {
        self.geometry = geometry
        self.seekModel = seekModel
        self.spinUpAt = spinUpAt
        self.spinUpDuration = spinUpDuration
        self.idle = idle
        self.skew = geometry.skew(seekModel: seekModel)
        self.clock = spinUpAt + spinUpDuration
        // Au repos le bras est parqué au diamètre intérieur, sur la zone
        // d'atterrissage. Un plateau qui tournait déjà l'y a laissé ; un disque
        // qu'on allume en part pour chercher sa piste 0 (`start`).
        self.headCylinder = geometry.parkCylinder
        self.nextRecalibration = idle.recalibration.map { clock + $0.firstAfter }
    }

    /// La rotation du plateau, connue d'avance : la montée comme la coupure
    /// sont des dates, pas des conséquences des requêtes.
    var spindle: SpindleTimeline {
        SpindleTimeline(spinUpAt: spinUpAt, duration: spinUpDuration,
                        rpm: geometry.rpm,
                        spinDownAt: stopAt ?? idle.stopAt,
                        spinDownDuration: idle.stopDuration)
    }

    /// La mise en rotation, et pour un disque qu'on allume, ce qu'elle
    /// entraîne : le décollement des têtes, puis la recherche de la piste 0.
    ///
    /// La salve de recherche est calée pour **finir** quand le disque est prêt :
    /// c'est elle qui le rend prêt. Elle ne commence pas avant la moitié de la
    /// montée — il faut un coussin d'air pour déplacer les têtes. Elle laisse le
    /// bras au bord, et c'est de là que partira le premier accès.
    mutating func start(events: inout [DiskEvent]) {
        events.append(DiskEvent(time: spinUpAt, kind: .spinUp(duration: spinUpDuration)))
        guard idle.coldStart else { return }
        events.append(DiskEvent(time: spinUpAt + StartupSequence.unstickDelay, kind: .headUnstick))

        let dwell = StartupSequence.dwellRevolutions * geometry.revolutionDuration
        let stops = StartupSequence.stops(cylinders: geometry.cylinders)
        var cylinder = headCylinder
        var length = 0.0
        for stop in stops {
            length += seekModel.duration(distance: abs(stop - cylinder)) + dwell
            cylinder = stop
        }
        var t = max(clock - length, spinUpAt + spinUpDuration / 2)
        for stop in stops {
            let distance = abs(stop - headCylinder)
            if distance > 0 {
                let profile = seekModel.profile(distance: distance)
                events.append(DiskEvent(time: t, kind: .seek(profile)))
                t += profile.total
            }
            t += dwell
            headCylinder = stop
        }
        headIndex = 0
        // Une montée trop courte pour la salve retarde le disque prêt ; aucune
        // des rampes des scénarios ne l'est.
        clock = max(clock, t)
    }

    /// Une recalibration thermique commencée à `begin` : les repères visités,
    /// deux tours de lecture sur chacun. Rend l'instant où le disque est de
    /// nouveau disponible ; le bras reste sur le dernier repère.
    private mutating func recalibrate(_ recalibration: ThermalRecalibration,
                                      at begin: Double,
                                      events: inout [DiskEvent]) -> Double {
        let dwell = recalibration.dwellRevolutions * geometry.revolutionDuration
        var t = begin
        for stop in recalibration.stops(cylinders: geometry.cylinders) {
            let distance = abs(stop - headCylinder)
            if distance > 0 {
                let profile = seekModel.profile(distance: distance)
                events.append(DiskEvent(time: t, kind: .seek(profile)))
                t += profile.total
            }
            t += dwell
            headCylinder = stop
        }
        headIndex = 0
        stats.recalibrations += 1
        return t
    }

    /// Ce qu'il faut attendre, à l'instant `t`, pour que ce secteur-là passe
    /// sous la tête.
    ///
    /// L'angle du plateau est lu sur une horloge absolue et non tiré au sort :
    /// c'est ce qui fait qu'un fichier éclaté coûte vraiment plus cher, et pas
    /// seulement statistiquement. La tolérance, elle, ne rattrape pas une
    /// erreur de modèle : elle reconnaît qu'un angle nul calculé par somme de
    /// durées ne tombe jamais exactement sur zéro.
    private func rotationalWait(to position: DriveGeometry.Position, at t: Double) -> Double {
        let revolution = geometry.revolutionDuration
        let current = (t / revolution).truncatingRemainder(dividingBy: 1.0)
        var delta = geometry.angleOf(position, skew: skew) - current
        if delta < -Self.angularTolerance { delta += 1 } else { delta = max(delta, 0) }
        return delta * revolution
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

        // 0. Une recalibration thermique échue passe avant : le disque finit la
        //    commande en cours, puis s'interrompt. Échue pendant un repos, elle
        //    s'y loge et ne retarde personne.
        if let recalibration = idle.recalibration {
            var free = clock
            while let due = nextRecalibration, due <= t {
                let end = recalibrate(recalibration, at: max(due, free), events: &events)
                free = end
                nextRecalibration = due + recalibration.period
                if end > t {
                    stats.recalibrationSeconds += end - t
                    t = end
                }
            }
        }

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
        let latency = rotationalWait(to: target, at: t)
        t += latency
        stats.rotationSeconds += latency

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

            // Passage à la piste logique suivante. Le plateau tourne pendant le
            // franchissement : le secteur 0 de la piste d'arrivée n'est
            // rattrapé que parce qu'il a été formaté décalé de ce que ce
            // franchissement-là coûte. C'est le même `angleOf` que la latence
            // ci-dessus qui le dit, et non plus une hypothèse muette et
            // contraire.
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

            let wait = rotationalWait(to: DriveGeometry.Position(cylinder: headCylinder,
                                                                 head: headIndex, sector: 0),
                                      at: t)
            t += wait
            stats.rotationSeconds += wait
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
        let stopAt = idle.stopAt ?? (served ? idle.stopAfter.map { clock + $0 } : nil)
        self.stopAt = stopAt
        // Un disque parque toujours ses têtes **avant** de couper le moteur :
        // sans couple, plus de coussin d'air. Un disque de bureau ne le fait
        // qu'à la coupure ; un disque à rampe, aussi au bout d'un repos.
        let parkDelay = idle.parkAfter ?? (stopAt != nil ? .infinity : nil)
        if let delay = parkDelay, served {
            let distance = abs(geometry.parkCylinder - headCylinder)
            let travel = seekModel.duration(distance: distance)
            // Si la coupure vient avant le délai d'inactivité, c'est elle qui
            // déclenche le voyage.
            var moment = clock + delay
            if let stopAt { moment = min(moment, stopAt - travel) }
            moment = max(moment, clock)
            if distance > 0 {
                tail.append(DiskEvent(
                    time: moment, kind: .seek(seekModel.profile(distance: distance))))
                parkAt = moment
                headCylinder = geometry.parkCylinder
            }
        }

        if let stopAt {
            tail.append(DiskEvent(time: stopAt, kind: .spinDown(duration: idle.stopDuration)))
            // Le moteur ralentit ; les têtes finissent par toucher le plateau.
            let landing = stopAt + StartupSequence.landingDelay(stopDuration: idle.stopDuration)
            tail.append(DiskEvent(time: landing, kind: .headLand))
        }

        tail.sort { $0.time < $1.time }
        events.append(contentsOf: tail)
        return parkAt
    }
}
