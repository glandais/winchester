import Foundation
import DiskCore

// MARK: - Ce qui sort d'une passe

/// Ce qu'une tranche de cent millisecondes a vu passer.
///
/// C'est la granularité des séries d'affichage depuis le premier jour : assez
/// fine pour que le voyant d'activité clignote au rythme des rafales, assez
/// grossière pour qu'une passe de cinq heures n'en compte que cent quatre-vingt
/// mille. Les requêtes et les seeks y sont comptés à leur prise en charge, les
/// octets déplacés à la fin de l'écriture qui les pose.
struct ActivityBucket: Sendable, Equatable {
    static let duration = 0.1

    let index: Int
    var requests = 0
    /// Octets demandés au disque, lectures et écritures confondues.
    var bytes = 0
    var seeks = 0
    var seekDistance = 0
    var movedBytes = 0
    /// Ce que les instruments en disent de plus. Hors de la comparaison avec le
    /// calcul d'un bloc, qui ne les a jamais produits.
    var detail = ActivityDetail()

    init(index: Int) {
        self.index = index
    }

    static func index(at time: Double) -> Int {
        max(Int(time / duration), 0)
    }

    var start: Double { Double(index) * Self.duration }
}

/// Le détail d'une tranche, pour les instruments.
struct ActivityDetail: Sendable, Equatable {
    var readRequests = 0
    var readBytes = 0
    var writeBytes = 0
    /// Le temps des requêtes prises en charge dans la tranche, par composante.
    /// Le transfert comprend les pas de piste d'une lecture séquentielle.
    var seekSeconds = 0.0
    var rotationSeconds = 0.0
    var transferSeconds = 0.0
    var thinkSeconds = 0.0
    var waitSeconds = 0.0
    /// Ce que le tampon du disque a fait attendre : le bus, la commande, la
    /// lecture anticipée qui n'était pas encore arrivée.
    var bufferSeconds = 0.0
    /// Seeks par classe de distance (`SeekClass`).
    var seekClasses = [Int](repeating: 0, count: SeekClass.allCases.count)
    /// Requêtes par bande de cylindres, du bord (bande 0) vers le moyeu.
    var cylinderBands = [Int](repeating: 0, count: ActivityDetail.bandCount)

    static let bandCount = 24

    static func band(cylinder: Int, of cylinders: Int) -> Int {
        guard cylinders > 0 else { return 0 }
        return min(max(cylinder * bandCount / cylinders, 0), bandCount - 1)
    }

    mutating func add(_ other: ActivityDetail) {
        readRequests += other.readRequests
        readBytes += other.readBytes
        writeBytes += other.writeBytes
        seekSeconds += other.seekSeconds
        rotationSeconds += other.rotationSeconds
        transferSeconds += other.transferSeconds
        thinkSeconds += other.thinkSeconds
        waitSeconds += other.waitSeconds
        bufferSeconds += other.bufferSeconds
        for i in seekClasses.indices { seekClasses[i] += other.seekClasses[i] }
        for i in cylinderBands.indices { cylinderBands[i] += other.cylinderBands[i] }
    }
}

/// La distance d'un seek, rapportée à la course du bras.
enum SeekClass: Int, CaseIterable, Sendable {
    /// Une piste : le pas d'une lecture qui continue ailleurs.
    case adjacent
    /// Au plus 1 % de la course.
    case short
    /// Au plus 10 %.
    case medium
    /// Au plus la moitié.
    case long
    /// Plus de la moitié : ce que `TraceStats.fullStrokeSeeks` compte.
    case full

    init(distance: Int, cylinders: Int) {
        if distance <= 1 { self = .adjacent }
        else if distance * 100 <= cylinders { self = .short }
        else if distance * 10 <= cylinders { self = .medium }
        else if distance <= cylinders / 2 { self = .long }
        else { self = .full }
    }

    var label: String {
        switch self {
        case .adjacent: return String(localized: "seekClass.adjacent", defaultValue: "next track")
        case .short:    return String(localized: "seekClass.short", defaultValue: "short")
        case .medium:   return String(localized: "seekClass.medium", defaultValue: "medium")
        case .long:     return String(localized: "seekClass.long", defaultValue: "long")
        case .full:     return String(localized: "seekClass.full", defaultValue: "full stroke")
        }
    }
}

/// Les compteurs de la stratégie, datés.
struct MoveMark: Sendable, Equatable {
    let time: Double
    let moves: MoveCount
}

/// Une phase commence.
struct PhaseMark: Sendable, Equatable {
    let index: Int
    let time: Double
}

/// Le temps écouté dans une phase, toutes ses reprises confondues.
struct PhaseTime: Sendable, Equatable {
    let index: Int
    var seconds: Double
}

/// L'avancement annoncé par l'outil, à un instant donné.
struct ProgressMark: Sendable, Equatable {
    let time: Double
    let value: Double
}

/// Le bilan d'une passe, connu seulement quand elle est finie.
struct PassEnd: Sendable {
    let stats: TraceStats
    let requestCount: Int
    let eventCount: Int
    /// Fin de la dernière requête, zéro s'il n'y en a pas eu.
    let workEnd: Double
    let parkAt: Double?
    /// Coupure du moteur, si la passe finit par elle.
    var stopAt: Double? = nil
    var stopDuration: Double = 0
    /// Tout ce qui s'entend, queue comprise.
    let duration: Double
    /// Première prise en charge de chaque phase, pour dater les phases après
    /// coup comme le faisait le calcul d'un bloc.
    let firstStarts: [Int: Double]
    /// Ce que le défragmenteur dit de sa passe, s'il y en a un. Sans
    /// opérations ni mutations : elles sont parties au fil de l'eau.
    let plan: DefragPlan?
}

/// Un paquet de passe : tout ce que la simulation a produit depuis le paquet
/// précédent, daté.
///
/// Les repères audio sont les seuls à être retenus en amont — un train de seeks
/// ne se referme qu'une seconde après son début — et `cueWatermark` dit jusqu'où
/// ils sont complets. Tout le reste est livré dès qu'il est calculé.
struct PassBatch: Sendable {
    var cues: [AudioCue] = []
    /// Instant avant lequel tous les repères sont livrés.
    var cueWatermark = -Double.infinity
    var samples: [HeadSample] = []
    var mutations: [TimedMutation] = []
    var activity: [ClusterActivity] = []
    /// Tranches refermées : plus aucune requête n'y tombera.
    var buckets: [ActivityBucket] = []
    var phases: [PhaseMark] = []
    var progress: [ProgressMark] = []
    var moves: [MoveMark] = []
    /// Fin de la dernière requête simulée.
    var clock = 0.0
    var end: PassEnd?

    /// Accole le paquet suivant.
    mutating func append(_ next: PassBatch) {
        cues.append(contentsOf: next.cues)
        cueWatermark = max(cueWatermark, next.cueWatermark)
        samples.append(contentsOf: next.samples)
        mutations.append(contentsOf: next.mutations)
        activity.append(contentsOf: next.activity)
        buckets.append(contentsOf: next.buckets)
        phases.append(contentsOf: next.phases)
        progress.append(contentsOf: next.progress)
        moves.append(contentsOf: next.moves)
        clock = max(clock, next.clock)
        if let end = next.end { self.end = end }
    }
}

// MARK: - La chaîne

/// Le disque et sa chronologie, pour une passe donnée.
struct PassSetup {
    var geometry: DriveGeometry
    var seekModel: SeekModel
    var spinUpAt: Double
    var spinUpDuration: Double
    var idle: IdleBehavior = .none
    /// Le tampon du disque, son bus, ce que coûte une commande. `.direct` : la
    /// mécanique seule, sans tampon ni coût de commande.
    var drive: DriveInterface = .direct
    /// Ce que dure la passe après sa dernière requête. `nil` : la durée est
    /// celle de la trace — la dernière requête, ou le parcage s'il vient après.
    var tail: Double?
    /// Année du disque : elle décide de son palier, donc de son ronronnement.
    var year: Int?

    /// Ce que le plateau fait entendre de lui-même.
    var character: SpindleCharacter { SpindleCharacter(geometry: geometry, year: year) }

    /// Où le bras attend la première requête, et depuis quand : au bord, une
    /// fois la recherche de la piste 0 d'une mise sous tension finie. `nil`
    /// pour un plateau qui tournait déjà, parqué au moyeu.
    var armReady: (time: Double, cylinder: Int)? {
        idle.coldStart ? (spinUpAt + spinUpDuration, 0) : nil
    }

    /// La rotation du plateau : la montée comme la coupure sont des dates,
    /// connues avant la moindre requête.
    var spindle: SpindleTimeline {
        SpindleTimeline(spinUpAt: spinUpAt, duration: spinUpDuration, rpm: geometry.rpm,
                        spinDownAt: idle.stopAt, spinDownDuration: idle.stopDuration)
    }
}

/// Planificateur → simulateur → repères, une requête à la fois.
///
/// C'est tout ce qu'un scénario calculait d'un bloc, ramené à ce qui dépend
/// de la requête qu'on sert : la mécanique du disque est causale, les repères
/// audio ne regardent qu'une seconde en arrière, et les dates de la carte ne
/// sont que celles des transferts. Rien n'y a besoin de la passe entière.
///
/// Ce qui sort est remis par paquets à `deliver`, qui en fait ce qu'il veut :
/// l'application les tamponne pour l'écoute, le rendu hors-ligne les mixe, les
/// tests les recollent pour les comparer au calcul d'un bloc.
final class PassPipeline {

    typealias Delivery = (PassBatch) -> Void

    let setup: PassSetup

    /// Tout l'état de la chaîne tient dans une valeur, modifiée d'un seul
    /// accès par requête. Réparti en propriétés de la classe, chaque lecture
    /// et chaque écriture passait par une vérification d'exclusivité à
    /// l'exécution : une dizaine par requête, 15 % du calcul d'une passe.
    private var chain: Chain
    private let deliver: Delivery
    private var finished = false

    init(setup: PassSetup,
         batchRequests: Int = 256,
         batchSeconds: Double = 0.05,
         deliver: @escaping Delivery) {
        self.setup = setup
        self.deliver = deliver
        chain = Chain(setup: setup, batchRequests: batchRequests, batchSeconds: batchSeconds)
    }

    /// La rotation du plateau : des dates, connues avant toute requête.
    var spindle: SpindleTimeline { chain.mechanics.spindle }

    /// Une requête sans conséquence sur la carte : un démarrage. `cluster`
    /// l'y allume pendant qu'elle se sert, sans rien y changer.
    @discardableResult
    func serve(_ request: BlockRequest, cluster: Int? = nil) -> RequestTiming {
        let timing = chain.serve(request, cluster: cluster)
        if chain.isDue { deliver(chain.flush()) }
        return timing
    }

    /// Une opération qui change la carte — un déplacement de défragmentation,
    /// une écriture d'installation — et ce qu'elle y change.
    func serve(_ operation: DiskOperation,
               mutations: ArraySlice<MapMutation>,
               progress: Double,
               moves: MoveCount = MoveCount()) {
        chain.serve(operation, mutations: mutations, progress: progress, moves: moves)
        if chain.isDue { deliver(chain.flush()) }
    }

    /// Le travail est fini : le disque se parque, le moteur se coupe s'il doit
    /// l'être, et le bilan part avec le dernier paquet.
    @discardableResult
    func finish(plan: DefragPlan? = nil) -> PassEnd {
        precondition(!finished, "une passe ne se termine qu'une fois")
        finished = true
        let end = chain.finish(plan: plan)
        deliver(chain.flush())
        return end
    }
}

/// L'état de la chaîne, et tout ce qui le fait avancer.
private struct Chain {

    let setup: PassSetup

    var mechanics: DiskMechanics
    private var cueStream: CueStream
    private var events: [DiskEvent] = []
    var batch = PassBatch()

    /// Un paquet part dès qu'il porte autant de requêtes, ou couvre autant de
    /// temps de passe.
    private let batchRequests: Int
    private let batchSeconds: Double
    private var batchedRequests = 0
    private var lastDelivery = 0.0

    private var openBuckets: [ActivityBucket] = []
    private var firstStarts: [Int: Double] = [:]
    /// Phase de la requête précédente. Les requêtes partent dans l'ordre : la
    /// première d'une phase est aussi la plus précoce, et le dictionnaire n'a
    /// à être consulté qu'au changement de phase.
    private var lastPhase: Int?
    private var currentPhase: Int?
    private var lastProgress = -1.0
    private var lastMoves = MoveCount()
    private var eventCount = 0
    private var workEnd = 0.0

    init(setup: PassSetup, batchRequests: Int, batchSeconds: Double) {
        self.setup = setup
        self.batchRequests = batchRequests
        self.batchSeconds = batchSeconds
        mechanics = DiskMechanics(geometry: setup.geometry, seekModel: setup.seekModel,
                                  spinUpAt: setup.spinUpAt,
                                  spinUpDuration: setup.spinUpDuration,
                                  idle: setup.idle,
                                  drive: setup.drive)
        cueStream = CueStream(cylinders: setup.geometry.cylinders)
        mechanics.start(events: &events)
        ingestEvents()
    }

    var isDue: Bool {
        batchedRequests >= batchRequests || mechanics.clock - lastDelivery >= batchSeconds
    }

    mutating func serve(_ request: BlockRequest, cluster: Int? = nil) -> RequestTiming {
        let timing = simulate(request)
        if let cluster {
            batch.activity.append(ClusterActivity(start: timing.start, end: timing.end,
                                                  cluster: cluster, isWrite: request.isWrite))
        }
        batchedRequests += 1
        return timing
    }

    private mutating func simulate(_ request: BlockRequest) -> RequestTiming {
        let before = mechanics.stats
        let timing = mechanics.serve(request, events: &events, samples: &batch.samples)
        ingestEvents()
        workEnd = timing.end

        // Datation des phases.
        let phase = request.phaseIndex
        if lastPhase != phase {
            if firstStarts[phase] == nil { firstStarts[phase] = timing.start }
            lastPhase = phase
        }
        if currentPhase != phase {
            batch.phases.append(PhaseMark(index: phase, time: timing.start))
            currentPhase = phase
        }

        // Plus aucune requête ne partira avant celle-ci : les tranches
        // antérieures sont closes.
        let index = ActivityBucket.index(at: timing.start)
        closeBuckets(before: index)
        let after = mechanics.stats
        let cylinders = setup.geometry.cylinders
        let requestCylinder = setup.geometry.position(ofLBA: request.lba).cylinder
        let distance = after.totalSeekDistance - before.totalSeekDistance
        updateBucket(index) {
            $0.requests += 1
            $0.bytes += request.sectorCount * DriveGeometry.bytesPerSector
            $0.seeks += after.seekCount - before.seekCount
            $0.seekDistance += distance
            let bytes = request.sectorCount * DriveGeometry.bytesPerSector
            if request.isWrite {
                $0.detail.writeBytes += bytes
            } else {
                $0.detail.readRequests += 1
                $0.detail.readBytes += bytes
            }
            $0.detail.seekSeconds += after.seekSeconds - before.seekSeconds
            $0.detail.rotationSeconds += after.rotationSeconds - before.rotationSeconds
            $0.detail.transferSeconds += (after.busySeconds - before.busySeconds)
                + (after.stepSeconds - before.stepSeconds)
            $0.detail.thinkSeconds += after.thinkSeconds - before.thinkSeconds
            $0.detail.waitSeconds += after.waitSeconds - before.waitSeconds
            $0.detail.bufferSeconds += after.bufferSeconds - before.bufferSeconds
            if after.seekCount > before.seekCount {
                $0.detail.seekClasses[SeekClass(distance: distance, cylinders: cylinders).rawValue] += 1
            }
            // La bande de ce qu'on a demandé, que le tampon l'ait servi ou le
            // bras.
            $0.detail.cylinderBands[ActivityDetail.band(cylinder: requestCylinder,
                                                        of: cylinders)] += 1
        }
        return timing
    }

    mutating func serve(_ operation: DiskOperation,
                        mutations: ArraySlice<MapMutation>,
                        progress: Double,
                        moves: MoveCount) {
        let timing = simulate(BlockRequest(issueTime: operation.issueTime,
                                        lba: operation.lba,
                                        sectorCount: operation.sectors,
                                        isWrite: operation.isWrite,
                                        phaseIndex: operation.phase,
                                        thinkTime: operation.thinkTime))

        if abs(progress - lastProgress) >= 0.001 {
            batch.progress.append(ProgressMark(time: timing.start, value: progress))
            lastProgress = progress
        }
        if moves != lastMoves {
            batch.moves.append(MoveMark(time: timing.end, moves: moves))
            lastMoves = moves
        }
        for mutation in mutations {
            batch.mutations.append(TimedMutation(time: timing.end,
                                                 start: mutation.start,
                                                 count: mutation.count,
                                                 category: mutation.category.rawValue,
                                                 contiguous: mutation.contiguous))
        }
        if let cluster = operation.cluster {
            batch.activity.append(ClusterActivity(start: timing.start, end: timing.end,
                                                  cluster: cluster, isWrite: operation.isWrite))
        }
        if operation.kind == .writeExtent {
            updateBucket(ActivityBucket.index(at: timing.end)) {
                $0.movedBytes += operation.sectors * DriveGeometry.bytesPerSector
            }
        }
        batchedRequests += 1
    }

    mutating func finish(plan: DefragPlan?) -> PassEnd {
        let parkAt = mechanics.finish(events: &events, samples: &batch.samples)
        ingestEvents()
        cueStream.finish()
        closeBuckets(before: .max)

        // Les derniers comptes d'une stratégie peuvent suivre sa dernière
        // opération : le plan fait foi, à la fin du travail.
        if let plan {
            let final = MoveCount(filesMoved: plan.filesMoved, evacuations: plan.evacuations)
            if final != lastMoves {
                batch.moves.append(MoveMark(time: workEnd, moves: final))
                lastMoves = final
            }
        }

        // Le disque ne s'arrête pas à la dernière réponse : il pose encore ce
        // qu'il a acquitté sans l'avoir écrit.
        let duration = setup.tail.map { max(workEnd + $0, mechanics.idleAt) }
            ?? max(mechanics.idleAt, parkAt ?? 0)
        let end = PassEnd(stats: mechanics.stats,
                          requestCount: mechanics.stats.requestCount,
                          eventCount: eventCount,
                          workEnd: workEnd,
                          parkAt: parkAt,
                          stopAt: mechanics.stopAt,
                          stopDuration: setup.idle.stopDuration,
                          duration: duration,
                          firstStarts: firstStarts,
                          plan: plan)
        batch.end = end
        return end
    }

    /// Rend le paquet en cours, et en ouvre un neuf.
    mutating func flush() -> PassBatch {
        cueStream.release(into: &batch.cues)
        batch.cueWatermark = cueStream.watermark
        batch.clock = mechanics.clock
        let outgoing = batch
        batch = PassBatch()
        batchedRequests = 0
        lastDelivery = mechanics.clock
        return outgoing
    }

    // MARK: - Détails

    private mutating func ingestEvents() {
        eventCount += events.count
        for event in events { cueStream.ingest(event) }
        events.removeAll(keepingCapacity: true)
    }

    private mutating func updateBucket(_ index: Int, _ change: (inout ActivityBucket) -> Void) {
        // Deux ou trois tranches ouvertes au plus : une recherche linéaire
        // depuis la fin suffit.
        var position = openBuckets.count
        while position > 0 && openBuckets[position - 1].index > index { position -= 1 }
        if position > 0 && openBuckets[position - 1].index == index {
            change(&openBuckets[position - 1])
        } else {
            var bucket = ActivityBucket(index: index)
            change(&bucket)
            openBuckets.insert(bucket, at: position)
        }
    }

    private mutating func closeBuckets(before index: Int) {
        var count = 0
        while count < openBuckets.count && openBuckets[count].index < index { count += 1 }
        guard count > 0 else { return }
        batch.buckets.append(contentsOf: openBuckets[0..<count])
        openBuckets.removeFirst(count)
    }
}

// MARK: - Garder toute l'histoire

/// Recolle tous les paquets d'une passe.
///
/// C'est l'écoute qui a le moins de mémoire qui fixe le modèle — l'application
/// ne garde que l'instant présent. Ce récepteur-ci garde tout, et il ne sert
/// qu'à ceux qui ont besoin de relire une passe entière : les tests, qui la
/// comparent à un calcul d'un bloc.
final class PassRecorder {
    private(set) var history = PassBatch()

    var end: PassEnd? { history.end }

    func receive(_ batch: PassBatch) {
        history.append(batch)
    }
}
