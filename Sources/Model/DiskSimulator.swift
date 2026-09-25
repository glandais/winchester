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
/// Un échantillon par geste du bras, qui porte **son début et sa fin** — une
/// requête servie par le bras, un bout de lecture anticipée, un vidage du cache
/// d'écriture ; aucun pour une requête que le tampon sert sans que la tête
/// bouge :
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
    /// Ce que la tête a attendu, posée sur la piste, que le premier secteur
    /// se présente : le bras est arrivé `latency` avant `time`. `Float16`
    /// pour tenir dans les deux octets qui restaient — quatre microsecondes
    /// de résolution sur les huit millisecondes d'un tour de 1993.
    let latency: Float16

    var endTime: Double { time + Double(duration) }
    /// L'instant où le bras est arrivé sur la piste, avant l'attente.
    var arrivalTime: Double { time - Double(latency) }
}

struct TraceStats {
    var requestCount = 0
    var seekCount = 0
    var totalSeekDistance = 0
    var fullStrokeSeeks = 0
    var bytesRead = 0
    var bytesWritten = 0
    var busySeconds = 0.0
    /// Où passe le temps d'une passe : bras en mouvement (commutations de tête
    /// comprises), attente du secteur, pas de piste pendant un transfert,
    /// calcul de la machine entre deux lectures, disque au repos, et ce qu'une
    /// commande servie par le tampon a fait attendre l'hôte. Sans tampon, ils recomposent l'horloge avec `busySeconds`. Avec
    /// lui, plus exactement : les vidages et la lecture anticipée font bouger
    /// le bras pendant que l'hôte calcule, et leurs seeks sont comptés sans que
    /// personne les ait attendus.
    var seekSeconds = 0.0
    var rotationSeconds = 0.0
    var stepSeconds = 0.0
    var thinkSeconds = 0.0
    var waitSeconds = 0.0
    var bufferSeconds = 0.0
    /// Temps pendant lequel une requête a attendu que le disque finisse de se
    /// recalibrer, et nombre de recalibrations. Personne ne les a demandées :
    /// elles n'entrent ni dans les seeks ni dans leur distance moyenne.
    var recalibrationSeconds = 0.0
    var recalibrations = 0

    /// Ce que le tampon a fait. Des lectures servies sans que le bras bouge ;
    /// des secteurs lus d'avance, et le temps que la tête y a passé sans que
    /// personne le demande ; des écritures acquittées avant d'être posées, et
    /// les vidages qui les ont posées. Les seeks des vidages sont comptés avec
    /// les autres : ce sont ceux des écritures, différés.
    var bufferHits = 0
    var readAheadSectors = 0
    var readAheadSeconds = 0.0
    var cachedWrites = 0
    var destageWrites = 0

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
    /// scénario ne s'en sert.
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

    /// Têtes garées sur une rampe hors du plateau (NoTouch chez WD) : elles
    /// n'y sont jamais posées, donc rien ne se décolle à la mise en route et
    /// rien n'atterrit à la coupure. Le clic de chargement sur la rampe n'a pas
    /// de voix : aucune source ne le décrit.
    var rampLoad = false

    /// Un disque qu'on laisse tourner, bras là où il est.
    static let none = IdleBehavior()

    /// Un disque de bureau de l'année donnée : jamais parqué au repos, et
    /// recalibré périodiquement s'il est d'avant 1997.
    static func desktop(year: Int, coldStart: Bool = false,
                        stopAfter: Double? = nil, stopDuration: Double = 0,
                        rampLoad: Bool = false) -> IdleBehavior {
        IdleBehavior(parkAfter: nil, stopDuration: stopDuration, stopAfter: stopAfter,
                     coldStart: coldStart,
                     recalibration: ThermalRecalibration.era(year: year),
                     rampLoad: rampLoad)
    }

    /// Le disque de bureau d'un matériel donné : son année à lui, sa rampe.
    static func desktop(_ hardware: DriveHardware, coldStart: Bool = false,
                        stopAfter: Double? = nil, stopDuration: Double = 0) -> IdleBehavior {
        desktop(year: hardware.year, coldStart: coldStart, stopAfter: stopAfter,
                stopDuration: stopDuration, rampLoad: hardware.rampLoad)
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
/// File d'attente FIFO, sans réordonnancement des commandes : c'est volontaire,
/// un contrôleur IDE de cette époque ne réordonnait quasiment rien, et c'est
/// précisément ce qui rend le crépitement si dense. Seul le cache d'écriture du
/// disque pose ce qu'il a acquitté dans l'ordre de l'ascenseur.
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
                    idle: IdleBehavior = .none,
                    drive: DriveInterface = .direct) -> DiskTrace {

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
                                      idle: idle, drive: drive)
        mechanics.start(events: &events)
        for request in requests {
            timings.append(mechanics.serve(request, events: &events, samples: &samples))
        }
        let parkAt = mechanics.finish(events: &events, samples: &samples)
        // Déjà dans l'ordre, sauf si la coupure du moteur tombe avant la fin du
        // travail — un scénario dont les requêtes débordent sur son extinction.
        events.sort { $0.time < $1.time }

        let end = max(max(totalDuration, mechanics.idleAt), parkAt ?? 0)
        return DiskTrace(events: events, headSamples: samples, timings: timings,
                         spindle: mechanics.spindle, parkAt: parkAt, duration: end,
                         stats: mechanics.stats)
    }
}

/// Ce qu'une requête a produit : ce que le bras a fait depuis la précédente et
/// pour elle, et quand l'hôte a eu sa réponse.
struct ServedRequest {
    /// Lecture anticipée, vidages du cache d'écriture, puis la requête
    /// elle-même si elle a eu besoin du bras. Vide pour une requête servie par
    /// le tampon sans que la tête bouge.
    var samples: [HeadSample]
    let timing: RequestTiming
}

/// Le disque, une requête après l'autre.
///
/// Rien de ce qu'il calcule ne dépend des requêtes à venir : chacune part quand
/// la précédente est acquittée et que le système l'a émise ; entre les deux, le
/// bras a fait ce que le disque fait de lui-même — lire d'avance, poser ce qu'il
/// avait acquitté — jusqu'à l'instant où elle arrive, pas au-delà ; le plateau
/// est à l'angle que donne l'horloge. C'est cette causalité qui permet de
/// simuler une passe **à mesure qu'on la planifie**, sans jamais tenir la liste
/// de ses requêtes.
///
/// Les événements sortent dans l'ordre chronologique, celui du bras : la mise en
/// rotation d'abord, puis le travail de fond et chaque requête, puis le parcage
/// et la coupure du moteur.
struct DiskMechanics {

    let geometry: DriveGeometry
    let seekModel: SeekModel
    let spinUpAt: Double
    let spinUpDuration: Double
    let idle: IdleBehavior
    /// Le tampon du disque, son bus et ce que coûte une commande.
    let drive: DriveInterface

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

    /// Fin de la dernière requête **acquittée** — ou fin de la mise en rotation,
    /// si aucune ne l'a encore été. C'est l'horloge de l'hôte : avec un tampon,
    /// le bras peut encore travailler après elle.
    private(set) var clock: Double
    /// Quand le fil de l'hôte est prêt à émettre : la fin de sa dernière
    /// requête au premier plan, avancée du calcul qu'il a fait pendant que le
    /// disque servait des requêtes qu'il n'attendait pas (`RequestFlow`). Égal
    /// à `clock` tant que tout est au premier plan.
    private var hostReady: Double
    /// La fin de la dernière requête du premier plan : ce d'où se compte le
    /// délai d'une requête d'arrière-plan.
    private var foregroundEnd: Double
    private(set) var stats = TraceStats()
    private var headCylinder: Int
    private var headIndex = 0
    private var served = false
    /// Prochaine recalibration thermique, si le disque en fait.
    private var nextRecalibration: Double?
    /// Instant de coupure du moteur, une fois connu : daté d'avance par le
    /// scénario, ou compté depuis la dernière requête à la fin du travail.
    private(set) var stopAt: Double?

    // MARK: Le bras et le tampon

    /// Fin du travail engagé par le bras. Sans tampon, c'est `clock`.
    private var armFree: Double
    /// Secteur qui suit le dernier lu ou écrit : c'est de là que part l'ordre
    /// d'ascenseur d'un vidage.
    private var headLBA = 0
    /// La lecture anticipée en cours, s'il y en a une.
    private var stream: ReadStream?
    /// Ce que le tampon tient de propre, de la plus ancienne entrée à la plus
    /// récente : une **file**, qu'un succès ne réordonne pas (`DriveBuffer`).
    private var segments: [BufferedRange] = []
    /// Les écritures acquittées pas encore posées, triées par secteur.
    private var pending: [PendingWrite] = []
    private var pendingSectors = 0
    private let cacheSectors: Int
    /// Secteurs qu'une requête n'a pas pu transférer : elle débordait du
    /// disque, qui la tronque.
    private var truncatedSectors = 0

    init(geometry: DriveGeometry, seekModel: SeekModel,
         spinUpAt: Double, spinUpDuration: Double, idle: IdleBehavior = .none,
         drive: DriveInterface = .direct) {
        self.geometry = geometry
        self.seekModel = seekModel
        self.spinUpAt = spinUpAt
        self.spinUpDuration = spinUpDuration
        self.idle = idle
        self.drive = drive
        self.cacheSectors = drive.cacheSectors
        self.skew = geometry.skew(seekModel: seekModel)
        self.clock = spinUpAt + spinUpDuration
        self.hostReady = clock
        self.foregroundEnd = clock
        self.armFree = clock
        // Au repos le bras est parqué au diamètre intérieur, sur la zone
        // d'atterrissage. Un plateau qui tournait déjà l'y a laissé ; un disque
        // qu'on allume en part pour chercher sa piste 0 (`start`).
        let park = geometry.parkCylinder(rampLoad: idle.rampLoad)
        self.headCylinder = park
        self.headLBA = geometry.lba(of: DriveGeometry.Position(cylinder: park, head: 0, sector: 0))
        self.nextRecalibration = idle.recalibration.map { clock + $0.firstAfter }
    }

    /// Le disque a fini tout ce qu'on lui a demandé, y compris ce qu'il
    /// avait acquitté sans l'avoir encore écrit.
    var idleAt: Double { max(clock, armFree) }

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
        if !idle.rampLoad {
            events.append(DiskEvent(time: spinUpAt + StartupSequence.unstickDelay, kind: .headUnstick))
        }

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
        headLBA = 0
        // Une montée trop courte pour la salve retarde le disque prêt ; aucune
        // des rampes des scénarios ne l'est.
        clock = max(clock, t)
        hostReady = clock
        foregroundEnd = clock
        armFree = clock
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
        headLBA = geometry.lba(of: DriveGeometry.Position(cylinder: headCylinder, head: 0, sector: 0))
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

    // MARK: - Une requête

    /// Sert une requête, et rend ce qu'elle a produit. Commode pour les tests ;
    /// la chaîne passe par la variante qui ne crée pas de tableau.
    mutating func serve(_ request: BlockRequest, events: inout [DiskEvent]) -> ServedRequest {
        var samples: [HeadSample] = []
        let timing = serve(request, events: &events, samples: &samples)
        return ServedRequest(samples: samples, timing: timing)
    }

    /// Sert une requête.
    ///
    /// Le travail de fond du disque — la lecture anticipée qui continue, les
    /// écritures acquittées qu'il pose — est d'abord joué jusqu'à l'instant où
    /// la commande arrive ; puis la commande est servie par le tampon si elle
    /// peut l'être, par le bras sinon. Rien ne dépend des requêtes à venir.
    mutating func serve(_ request: BlockRequest,
                        events: inout [DiskEvent],
                        samples: inout [HeadSample]) -> RequestTiming {
        // Le disque ne repart pas à la milliseconde où il s'est arrêté :
        // la machine a peut-être quelque chose à faire de ce qu'elle vient
        // de lire. Le calcul part de l'instant où le fil de l'hôte est libre
        // (`hostReady`) ; une requête qu'il n'attend pas part dès que le
        // disque l'est, et son calcul avance le fil sans retenir le disque.
        let computed: Double
        switch request.flow {
        case .foreground:
            computed = hostReady + request.thinkTime
        case .barrier:
            computed = max(hostReady, clock) + request.thinkTime
        case .background:
            computed = foregroundEnd + request.thinkTime
            hostReady += request.hostWork
        case .backgroundBarrier:
            hostReady = max(hostReady, clock)
            foregroundEnd = hostReady
            computed = foregroundEnd + request.thinkTime
            hostReady += request.hostWork
        }
        let issued = max(clock, computed, request.issueTime)
        // Le calcul ne compte que ce qui s'est écoulé disque arrêté, avant la
        // prise en charge ; le reste de l'écart est un disque qui attend
        // qu'on lui demande.
        let thought = request.flow.isBackground ? 0 : max(min(issued, computed) - clock, 0)
        stats.thinkSeconds += thought
        stats.waitSeconds += max(issued - clock - thought, 0)

        let end: Double
        truncatedSectors = 0
        if request.isWrite {
            end = serveWrite(request, at: issued, events: &events, samples: &samples)
        } else {
            end = serveRead(request, at: issued, events: &events, samples: &samples)
        }

        let bytes = (request.sectorCount - truncatedSectors) * DriveGeometry.bytesPerSector
        if request.isWrite { stats.bytesWritten += bytes } else { stats.bytesRead += bytes }
        stats.requestCount += 1
        clock = end
        if !request.flow.isBackground {
            hostReady = end
            foregroundEnd = end
        }
        served = true
        return RequestTiming(start: issued, end: end)
    }

    private func busTime(sectors: Int, isWrite: Bool) -> Double {
        let rate = isWrite ? drive.writeBytesPerSecond : drive.readBytesPerSecond
        guard rate.isFinite else { return 0 }
        return Double(sectors * DriveGeometry.bytesPerSector) / rate
    }

    private mutating func serveRead(_ request: BlockRequest, at issued: Double,
                                    events: inout [DiskEvent],
                                    samples: inout [HeadSample]) -> Double {
        let first = request.lba
        let last = request.lba + request.sectorCount
        let overhead = drive.commandOverhead
        let hostFloor = issued + overhead + busTime(sectors: request.sectorCount, isWrite: false)
        let sectorBus = busTime(sectors: 1, isWrite: false)

        advanceBackground(until: issued, events: &events, samples: &samples)

        // 1. La lecture anticipée en cours l'a lue, ou va la lire : elle
        //    continue, et la requête prend les secteurs à mesure qu'ils passent.
        if var reading = stream, first >= reading.origin, first <= reading.stop {
            reading.stop = max(reading.stop,
                               min(last + readAheadDepth(at: last), geometry.totalSectors))
            let ready = last <= reading.next ? reading.ready : projectedReady(reading, through: last)
            stream = reading
            fitBuffer()
            stats.bufferHits += 1
            let done = max(hostFloor, ready + sectorBus)
            stats.bufferSeconds += done - issued
            return done
        }

        // 2. Le tampon la tient déjà : le bras ne bouge pas.
        let covered = coveredPrefix(from: first, to: last)
        if covered >= last {
            stats.bufferHits += 1
            stats.bufferSeconds += hostFloor - issued
            return hostFloor
        }

        // 3. Il faut aller la lire. Ce que le tampon tient du début est servi
        //    par lui ; le bras lit la suite.
        continueStream(until: issued + overhead, events: &events, samples: &samples)
        abandonStream()
        let (mediaEnd, firstReady) = mechanicalAccess(lba: covered, sectors: last - covered,
                                                      isWrite: false, at: issued + overhead,
                                                      readAhead: drive.readAhead,
                                                      origin: first,
                                                      events: &events, samples: &samples)
        if !drive.readAhead, cacheSectors > 0 {
            remember(BufferedRange(start: first, end: last))
        }
        // Sans bus à borner — la mécanique seule —, la fin du transfert est la
        // réponse, au bit près de ce qu'elle était avant le tampon.
        guard sectorBus > 0 else { return max(hostFloor, mediaEnd) }
        // Le bus reprend les secteurs à mesure qu'ils arrivent : il ne peut
        // pas commencer avant le premier, ni finir avant le dernier.
        return max(hostFloor,
                   mediaEnd + sectorBus,
                   firstReady + busTime(sectors: request.sectorCount, isWrite: false))
    }

    private mutating func serveWrite(_ request: BlockRequest, at issued: Double,
                                     events: inout [DiskEvent],
                                     samples: inout [HeadSample]) -> Double {
        let first = request.lba
        let last = request.lba + request.sectorCount
        let overhead = drive.commandOverhead
        let transfer = busTime(sectors: request.sectorCount, isWrite: true)
        let hostFloor = issued + overhead + transfer

        advanceBackground(until: issued, events: &events, samples: &samples)
        forget(first, last)

        // Le cache d'écriture l'acquitte dès qu'il la tient — à condition d'avoir
        // la place. Sinon il pose d'abord ce qu'il avait.
        if drive.writeCache, request.sectorCount <= cacheSectors {
            var room = issued + overhead
            while pendingSectors + request.sectorCount > cacheSectors {
                continueStream(until: room, events: &events, samples: &samples)
                abandonStream()
                guard let done = destage(at: max(room, armFree),
                                         events: &events, samples: &samples) else { break }
                room = done
            }
            let accepted = max(hostFloor, room + transfer)
            insertPending(PendingWrite(start: first, end: last, acceptedAt: accepted))
            fitBuffer()
            stats.cachedWrites += 1
            stats.bufferSeconds += accepted - issued
            return accepted
        }

        // Sans cache d'écriture, ou trop grosse pour lui : le bras l'écrit,
        // et l'hôte attend.
        continueStream(until: issued + overhead, events: &events, samples: &samples)
        abandonStream()
        let (mediaEnd, _) = mechanicalAccess(lba: first, sectors: request.sectorCount,
                                             isWrite: true, at: issued + overhead,
                                             readAhead: false, origin: first,
                                             events: &events, samples: &samples)
        return max(hostFloor, mediaEnd)
    }

    // MARK: - Le bras

    /// Le bras est demandé à `t` : une recalibration thermique échue passe
    /// avant. Le disque finit la commande en cours, puis s'interrompt ; échue
    /// pendant un repos, elle s'y loge et ne retarde personne.
    private mutating func armStart(at requested: Double, events: inout [DiskEvent]) -> Double {
        var t = max(requested, armFree)
        guard let recalibration = idle.recalibration else { return t }
        var free = armFree
        while let due = nextRecalibration, due <= t {
            let end = recalibrate(recalibration, at: max(due, free), events: &events)
            free = end
            nextRecalibration = due + recalibration.period
            if end > t {
                stats.recalibrationSeconds += end - t
                t = end
            }
        }
        armFree = max(armFree, free)
        return t
    }

    /// Un accès mécanique : seek, latence, transfert. Rend la fin du transfert
    /// et l'instant où le premier secteur, dans l'ordre, est dans le tampon.
    ///
    /// Une lecture qui tient sur une piste profite de la lecture sans latence
    /// si le disque la fait : la tête lit ce qui se présente, le tampon remet
    /// dans l'ordre. Une lecture est suivie de sa lecture anticipée si le
    /// disque la fait.
    private mutating func mechanicalAccess(lba: Int, sectors count: Int, isWrite: Bool,
                                           at requested: Double, readAhead: Bool, origin: Int,
                                           events: inout [DiskEvent],
                                           samples: inout [HeadSample]) -> (end: Double, firstReady: Double) {
        let revolution = geometry.revolutionDuration
        var t = armStart(at: requested, events: &events)

        let target = geometry.position(ofLBA: lba)

        // 1. Déplacement du bras. Avant une écriture, la tête doit être mieux
        //    posée : le settle dure plus (`SeekModel.writeLaw`).
        if target.cylinder != headCylinder {
            let distance = abs(target.cylinder - headCylinder)
            let profile = seekModel.profile(distance: distance, isWrite: isWrite)
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
        let spt = geometry.sectorsPerTrack(cylinder: target.cylinder)
        let sector = Double(revolution) / Double(spt)

        // La lecture sans latence : la tête arrive au milieu de ce qu'on lui
        // demande, elle en lit la fin, attend le tour, lit le début. Un tour
        // exactement, au lieu de la latence plus le transfert.
        let onTrack = min(count, spt - target.sector)
        if !isWrite, drive.zeroLatencyRead, onTrack == count,
           latency > revolution - Double(onTrack) * sector + Self.angularTolerance * revolution {
            let arrival = t
            let transfer = Double(onTrack) / Double(spt) * revolution
            events.append(DiskEvent(time: t, kind: .transfer(duration: revolution,
                                                             sectors: count, isWrite: false)))
            t += revolution
            stats.rotationSeconds += revolution - transfer
            stats.busySeconds += transfer
            samples.append(HeadSample(time: arrival, duration: Float(revolution),
                                      cylinder: Int32(headCylinder), endCylinder: Int32(headCylinder),
                                      head: UInt8(min(headIndex, Int(UInt8.max))), isWrite: false,
                                      latency: 0))
            // Le début de la requête, dans l'ordre, est lu en dernier : les
            // secteurs d'avant l'arrivée de la tête.
            let late = Int(((revolution - latency) / sector).rounded(.up))
            let firstReady = t - Double(max(late - 1, 0)) * sector
            armFree = t
            // Pendant ce tour, la tête a aussi lu la fin de la piste : la
            // lecture anticipée repart de la piste suivante, au prochain
            // passage de la fin de celle-ci.
            let trackEnd = geometry.lba(of: DriveGeometry.Position(cylinder: target.cylinder,
                                                                    head: target.head, sector: 0)) + spt
            headLBA = trackEnd
            let untilTrackEnd = latency + Double(spt - target.sector) * sector
            if readAhead {
                startStream(origin: origin, next: trackEnd, time: arrival + untilTrackEnd,
                            ready: t, busyUntil: t)
            } else if cacheSectors > 0 {
                remember(BufferedRange(start: origin, end: trackEnd))
            }
            return (t, firstReady)
        }

        t += latency
        stats.rotationSeconds += latency
        let firstReady = t + sector

        // L'échantillon d'affichage est refermé après le transfert, une fois
        // connu le cylindre d'arrivée : c'est lui qui fait avancer le bras
        // à l'écran pendant une lecture séquentielle.
        let sampleTime = t
        let sampleCylinder = headCylinder
        let sampleHead = headIndex

        // 3. Transfert, piste par piste.
        var remaining = count
        var position = target.sector
        var transferSeconds = 0.0

        while remaining > 0 {
            let spt = geometry.sectorsPerTrack(cylinder: headCylinder)
            let onThisTrack = min(remaining, spt - position)
            let dt = Double(onThisTrack) / Double(spt) * revolution

            events.append(DiskEvent(time: t, kind: .transfer(
                duration: dt, sectors: onThisTrack, isWrite: isWrite)))

            t += dt
            transferSeconds += dt
            remaining -= onThisTrack
            position = 0

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

        samples.append(HeadSample(time: sampleTime,
                                  duration: Float(t - sampleTime),
                                  cylinder: Int32(sampleCylinder),
                                  endCylinder: Int32(headCylinder),
                                  head: UInt8(min(sampleHead, Int(UInt8.max))),
                                  isWrite: isWrite,
                                  latency: Float16(latency)))
        stats.busySeconds += transferSeconds
        armFree = t
        headLBA = lba + (count - remaining)
        truncatedSectors = remaining
        if readAhead, remaining == 0 {
            startStream(origin: origin, next: headLBA, time: t, ready: t, busyUntil: t)
        }
        return (t, firstReady)
    }

    // MARK: - La lecture anticipée

    /// Ce que la lecture anticipée lit d'avance : une piste, ce que tient le
    /// cache du Fireball — 76 Ko pour une piste externe de 69 Ko — et l'ordre de
    /// grandeur que donne la revue (« jusqu'à la fin de la piste »). Borné par
    /// le cache.
    private func readAheadDepth(at lba: Int) -> Int {
        let cylinder = geometry.position(ofLBA: min(lba, geometry.totalSectors - 1)).cylinder
        return min(geometry.sectorsPerTrack(cylinder: cylinder), cacheSectors)
    }

    private mutating func startStream(origin: Int, next: Int, time: Double,
                                      ready: Double, busyUntil: Double) {
        let stop = min(next + readAheadDepth(at: next), geometry.totalSectors)
        guard stop > next else {
            remember(BufferedRange(start: origin, end: next))
            return
        }
        stream = ReadStream(origin: origin, next: next, time: time, ready: ready,
                            busyUntil: busyUntil, stop: stop)
        fitBuffer()
    }

    /// Le pas suivant d'une lecture anticipée : franchir une piste, ou lire ce
    /// qui reste sur celle-ci jusqu'à `limit`. Rend `false` si rien n'a pu être
    /// entrepris avant `deadline`.
    ///
    /// La même fonction joue la lecture anticipée pour de bon et la prévoit : la
    /// date à laquelle une requête servie en cours de lecture reçoit ses
    /// secteurs est celle que le bras atteindra, à l'identique.
    private func streamStep(_ s: inout ReadStream, cylinder: inout Int, head: inout Int,
                            limit: Int, deadline: Double,
                            emit: Bool, events: inout [DiskEvent]) -> (read: Int, reading: Double, moving: Double)? {
        guard s.next < limit, s.time < deadline else { return nil }
        let revolution = geometry.revolutionDuration
        let position = geometry.position(ofLBA: s.next)
        if position.cylinder != cylinder || position.head != head {
            // La piste suivante : même franchissement qu'au milieu d'un
            // transfert, rattrapé par le même skew.
            let cost: Double
            if position.cylinder == cylinder {
                cost = seekModel.headSwitchDuration
                if emit { events.append(DiskEvent(time: s.time, kind: .headSwitch)) }
            } else {
                cost = seekModel.duration(distance: abs(position.cylinder - cylinder))
                if emit { events.append(DiskEvent(time: s.time, kind: .trackStep)) }
            }
            cylinder = position.cylinder
            head = position.head
            let arrival = s.time + cost
            let wait = rotationalWait(to: position, at: arrival)
            s.busyUntil = arrival
            s.time = arrival + wait
            return (0, 0, cost + wait)
        }
        let spt = geometry.sectorsPerTrack(cylinder: cylinder)
        var count = min(limit - s.next, spt - position.sector)
        if deadline.isFinite {
            let sector = revolution / Double(spt)
            count = min(count, max(Int(((deadline - s.time) / sector).rounded(.up)), 1))
        }
        let dt = Double(count) / Double(spt) * revolution
        if emit {
            events.append(DiskEvent(time: s.time, kind: .transfer(duration: dt, sectors: count,
                                                                  isWrite: false)))
        }
        s.time += dt
        s.busyUntil = s.time
        s.ready = s.time
        s.next += count
        return (count, dt, 0)
    }

    /// Quand le secteur `last - 1` sera dans le tampon, si rien n'interrompt
    /// la lecture anticipée.
    private func projectedReady(_ reading: ReadStream, through last: Int) -> Double {
        var s = reading
        var cylinder = headCylinder
        var head = headIndex
        var scratch: [DiskEvent] = []
        while streamStep(&s, cylinder: &cylinder, head: &head, limit: last,
                         deadline: .infinity, emit: false, events: &scratch) != nil {}
        return s.ready
    }

    /// Joue la lecture anticipée jusqu'à `deadline` : tout ce qu'elle a
    /// entrepris avant cet instant est fait, et s'entend.
    private mutating func continueStream(until deadline: Double,
                                         events: inout [DiskEvent],
                                         samples: inout [HeadSample]) {
        guard var s = stream else { return }
        let startCylinder = headCylinder
        let startHead = headIndex
        var began: Double?
        while let step = streamStep(&s, cylinder: &headCylinder, head: &headIndex,
                                    limit: s.stop, deadline: deadline,
                                    emit: true, events: &events) {
            if began == nil { began = s.time - step.reading - step.moving }
            stats.readAheadSectors += step.read
            stats.readAheadSeconds += step.reading + step.moving
        }
        if let began {
            samples.append(HeadSample(time: began, duration: Float(s.busyUntil - began),
                                      cylinder: Int32(startCylinder), endCylinder: Int32(headCylinder),
                                      head: UInt8(min(startHead, Int(UInt8.max))), isWrite: false,
                                      latency: 0))
        }
        headLBA = s.next
        armFree = max(armFree, s.busyUntil)
        if s.next >= s.stop {
            stream = nil
            remember(BufferedRange(start: s.origin, end: s.next))
        } else {
            stream = s
        }
    }

    /// La tête est demandée ailleurs : la lecture anticipée s'arrête là où
    /// elle en est, et ce qu'elle a lu reste dans le tampon.
    private mutating func abandonStream() {
        guard let s = stream else { return }
        stream = nil
        armFree = max(armFree, s.busyUntil)
        if s.next > s.origin { remember(BufferedRange(start: s.origin, end: s.next)) }
    }

    // MARK: - Le travail de fond

    /// Ce que le disque fait de lui-même jusqu'à `deadline`, l'instant où la
    /// commande suivante arrive : finir sa lecture anticipée, puis poser, dans
    /// l'ordre de l'ascenseur, les écritures qu'il a acquittées.
    private mutating func advanceBackground(until deadline: Double,
                                            events: inout [DiskEvent],
                                            samples: inout [HeadSample]) {
        continueStream(until: deadline, events: &events, samples: &samples)
        guard stream == nil else { return }
        while !pending.isEmpty {
            let earliest = pending.map(\.acceptedAt).min() ?? .infinity
            let start = max(armFree, earliest)
            guard start < deadline else { return }
            guard destage(at: start, events: &events, samples: &samples) != nil
            else { return }
        }
    }

    /// Pose un paquet d'écritures acquittées : la première devant la tête dans
    /// l'ordre des secteurs — ou la plus basse, si la tête est au-delà de toutes
    /// —, et avec elle celles qui la prolongent sans trou. Rend la fin de
    /// l'écriture, ou `nil` si rien n'était prêt à `start`.
    @discardableResult
    private mutating func destage(at start: Double,
                                  events: inout [DiskEvent],
                                  samples: inout [HeadSample]) -> Double? {
        let readyIndices = pending.indices.filter { pending[$0].acceptedAt <= start }
        guard !readyIndices.isEmpty else { return nil }
        let first = readyIndices.first { pending[$0].start >= headLBA } ?? readyIndices[0]
        var end = pending[first].end
        var taken = [first]
        var index = first + 1
        while index < pending.count, pending[index].start <= end {
            if pending[index].acceptedAt <= start {
                end = max(end, pending[index].end)
                taken.append(index)
            } else if pending[index].start == end {
                break
            }
            index += 1
        }
        let lba = pending[first].start
        for index in taken.reversed() { pending.remove(at: index) }
        pendingSectors = pending.reduce(0) { $0 + $1.end - $1.start }
        let (done, _) = mechanicalAccess(lba: lba, sectors: end - lba, isWrite: true,
                                         at: start, readAhead: false, origin: lba,
                                         events: &events, samples: &samples)
        stats.destageWrites += 1
        return done
    }

    // MARK: - Le contenu du tampon

    /// Jusqu'où le tampon tient, d'un seul morceau, ce qui commence à `first`.
    private func coveredPrefix(from first: Int, to last: Int) -> Int {
        guard cacheSectors > 0 else { return first }
        var reach = first
        for range in segments where range.contains(first) { reach = max(reach, range.end) }
        for write in pending where write.start <= first && write.end > first {
            reach = max(reach, write.end)
        }
        return min(reach, last)
    }

    private mutating func remember(_ range: BufferedRange) {
        guard cacheSectors > 0, range.count > 0 else { return }
        segments.append(range)
        fitBuffer()
    }

    /// Une écriture rend caduc ce que le tampon tenait de ces secteurs.
    private mutating func forget(_ first: Int, _ last: Int) {
        guard cacheSectors > 0 else { return }
        var kept: [BufferedRange] = []
        kept.reserveCapacity(segments.count + 1)
        for range in segments {
            guard range.overlaps(first, last) else { kept.append(range); continue }
            if range.start < first { kept.append(BufferedRange(start: range.start, end: first)) }
            if range.end > last { kept.append(BufferedRange(start: last, end: range.end)) }
        }
        segments = kept
        if var s = stream, s.origin < last, s.next > first {
            s.origin = max(s.origin, min(last, s.next))
            stream = s
        }
        // Une écriture plus récente des mêmes secteurs remplace l'ancienne.
        pending.removeAll { $0.start >= first && $0.end <= last }
        pendingSectors = pending.reduce(0) { $0 + $1.end - $1.start }
    }

    private mutating func insertPending(_ write: PendingWrite) {
        var low = 0
        var high = pending.count
        while low < high {
            let mid = (low + high) / 2
            if pending[mid].start < write.start { low = mid + 1 } else { high = mid }
        }
        pending.insert(write, at: low)
        pendingSectors += write.end - write.start
    }

    /// Le cache ne tient pas plus que sa taille : les écritures en attente
    /// d'abord, la lecture anticipée ensuite, et ce qui reste de place aux
    /// entrées les plus récemment servies.
    private mutating func fitBuffer() {
        guard cacheSectors > 0 else { return }
        var room = cacheSectors - pendingSectors
        if var s = stream {
            let span = s.stop - s.origin
            if span > room {
                s.origin = min(s.next, max(s.origin, s.stop - max(room, 0)))
                stream = s
            }
            room -= s.stop - s.origin
        }
        var used = segments.reduce(0) { $0 + $1.count }
        var drop = 0
        while used > room && drop < segments.count {
            let excess = used - room
            if segments[drop].count > excess && drop == segments.count - 1 {
                segments[drop].start += excess
                used -= excess
                break
            }
            used -= segments[drop].count
            drop += 1
        }
        if drop > 0 { segments.removeFirst(drop) }
    }

    // MARK: - La fin

    /// Le travail est fini ; le disque, lui, ne l'est pas. Il finit sa lecture
    /// anticipée et pose ce qu'il a acquitté, puis se parque s'il le fait.
    /// Rend l'instant où le bras repart se parquer, s'il le fait.
    ///
    /// Le parcage n'entre pas dans `stats` : ces compteurs décrivent ce qu'on
    /// a demandé au disque, et personne n'a demandé celui-ci. L'y inclure
    /// décalerait le seek moyen d'une passe sans qu'aucune requête ait bougé.
    mutating func finish(events: inout [DiskEvent], samples: inout [HeadSample]) -> Double? {
        advanceBackground(until: .infinity, events: &events, samples: &samples)
        let quiet = idleAt
        var tail: [DiskEvent] = []
        var parkAt: Double?
        let stopAt = idle.stopAt ?? (served ? idle.stopAfter.map { quiet + $0 } : nil)
        self.stopAt = stopAt
        // Un disque parque toujours ses têtes **avant** de couper le moteur :
        // sans couple, plus de coussin d'air. Un disque de bureau ne le fait
        // qu'à la coupure ; un disque à rampe, aussi au bout d'un repos.
        let parkDelay = idle.parkAfter ?? (stopAt != nil ? .infinity : nil)
        if let delay = parkDelay, served {
            let distance = abs(geometry.parkCylinder(rampLoad: idle.rampLoad) - headCylinder)
            let travel = seekModel.duration(distance: distance)
            // Si la coupure vient avant le délai d'inactivité, c'est elle qui
            // déclenche le voyage.
            var moment = quiet + delay
            if let stopAt { moment = min(moment, stopAt - travel) }
            moment = max(moment, quiet)
            if distance > 0 {
                tail.append(DiskEvent(
                    time: moment, kind: .seek(seekModel.profile(distance: distance))))
                parkAt = moment
                headCylinder = geometry.parkCylinder(rampLoad: idle.rampLoad)
            }
        }

        if let stopAt {
            tail.append(DiskEvent(time: stopAt, kind: .spinDown(duration: idle.stopDuration)))
            // Le moteur ralentit ; les têtes finissent par toucher le plateau —
            // sauf sur une rampe, où le bras les a retirées avant.
            if !idle.rampLoad {
                let landing = stopAt + StartupSequence.landingDelay(stopDuration: idle.stopDuration)
                tail.append(DiskEvent(time: landing, kind: .headLand))
            }
        }

        tail.sort { $0.time < $1.time }
        events.append(contentsOf: tail)
        return parkAt
    }

    /// La même chose, pour qui n'a que faire des échantillons.
    mutating func finish(events: inout [DiskEvent]) -> Double? {
        var samples: [HeadSample] = []
        return finish(events: &events, samples: &samples)
    }
}
