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

    init(index: Int) {
        self.index = index
    }

    static func index(at time: Double) -> Int {
        max(Int(time / duration), 0)
    }

    var start: Double { Double(index) * Self.duration }
}

/// Une phase commence.
struct PhaseMark: Sendable, Equatable {
    let index: Int
    let time: Double
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
    /// Ce que dure la passe après sa dernière requête. `nil` : la durée est
    /// celle de la trace — la dernière requête, le parcage, ou
    /// `minimumDuration` si le scénario impose plus long.
    var tail: Double?
    var minimumDuration = 0.0
    /// Les phases sont-elles datées par la simulation ? Oui en boucle fermée,
    /// où chacune commence à sa première requête. Un scénario à durées
    /// imposées les pose lui-même avec `mark(phase:at:)`.
    var datesPhases = true

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

    private var mechanics: DiskMechanics
    private var cueStream: CueStream
    private var events: [DiskEvent] = []
    private var batch = PassBatch()
    private let deliver: Delivery

    /// Un paquet part dès qu'il porte autant de requêtes, ou couvre autant de
    /// temps de passe.
    private let batchRequests: Int
    private let batchSeconds: Double
    private var batchedRequests = 0
    private var lastDelivery = 0.0

    private var openBuckets: [ActivityBucket] = []
    private var firstStarts: [Int: Double] = [:]
    private var currentPhase: Int?
    private var lastProgress = -1.0
    private var eventCount = 0
    private var workEnd = 0.0
    private var finished = false

    init(setup: PassSetup,
         batchRequests: Int = 256,
         batchSeconds: Double = 0.05,
         deliver: @escaping Delivery) {
        self.setup = setup
        self.deliver = deliver
        self.batchRequests = batchRequests
        self.batchSeconds = batchSeconds
        mechanics = DiskMechanics(geometry: setup.geometry, seekModel: setup.seekModel,
                                  spinUpAt: setup.spinUpAt,
                                  spinUpDuration: setup.spinUpDuration,
                                  idle: setup.idle)
        cueStream = CueStream(cylinders: setup.geometry.cylinders)
        mechanics.start(events: &events)
        ingestEvents()
    }

    /// La rotation du plateau : des dates, connues avant toute requête.
    var spindle: SpindleTimeline { mechanics.spindle }

    /// Une phase imposée par le scénario.
    func mark(phase index: Int, at time: Double) {
        batch.phases.append(PhaseMark(index: index, time: time))
    }

    /// Une requête sans conséquence sur la carte : un démarrage.
    @discardableResult
    func serve(_ request: BlockRequest) -> RequestTiming {
        let timing = simulate(request)
        batchedRequests += 1
        deliverIfDue()
        return timing
    }

    private func simulate(_ request: BlockRequest) -> RequestTiming {
        let before = mechanics.stats
        let (sample, timing) = mechanics.serve(request, events: &events)
        ingestEvents()
        batch.samples.append(sample)
        workEnd = timing.end

        // Datation des phases.
        let phase = request.phaseIndex
        if let first = firstStarts[phase] {
            firstStarts[phase] = min(first, timing.start)
        } else {
            firstStarts[phase] = timing.start
        }
        if setup.datesPhases && currentPhase != phase {
            batch.phases.append(PhaseMark(index: phase, time: timing.start))
            currentPhase = phase
        }

        // Plus aucune requête ne partira avant celle-ci : les tranches
        // antérieures sont closes.
        let index = ActivityBucket.index(at: timing.start)
        closeBuckets(before: index)
        let after = mechanics.stats
        updateBucket(index) {
            $0.requests += 1
            $0.bytes += request.sectorCount * DriveGeometry.bytesPerSector
            $0.seeks += after.seekCount - before.seekCount
            $0.seekDistance += after.totalSeekDistance - before.totalSeekDistance
        }
        return timing
    }

    /// Une opération de défragmentation, et ce qu'elle change à la carte.
    func serve(_ operation: DiskOperation,
               mutations: ArraySlice<MapMutation>,
               progress: Double) {
        let timing = simulate(BlockRequest(issueTime: operation.issueTime,
                                        lba: operation.lba,
                                        sectorCount: operation.sectors,
                                        isWrite: operation.isWrite,
                                        phaseIndex: operation.phase))

        if abs(progress - lastProgress) >= 0.001 {
            batch.progress.append(ProgressMark(time: timing.start, value: progress))
            lastProgress = progress
        }
        for mutation in mutations {
            batch.mutations.append(TimedMutation(time: timing.end,
                                                 start: mutation.start,
                                                 count: mutation.count,
                                                 category: mutation.category.rawValue))
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
        deliverIfDue()
    }

    /// Le travail est fini : le disque se parque, le moteur se coupe s'il doit
    /// l'être, et le bilan part avec le dernier paquet.
    @discardableResult
    func finish(plan: DefragPlan? = nil) -> PassEnd {
        precondition(!finished, "une passe ne se termine qu'une fois")
        finished = true

        let parkAt = mechanics.finish(events: &events)
        ingestEvents()
        cueStream.finish()
        closeBuckets(before: .max)

        let duration = setup.tail.map { workEnd + $0 }
            ?? max(max(setup.minimumDuration, mechanics.clock), parkAt ?? 0)
        let end = PassEnd(stats: mechanics.stats,
                          requestCount: mechanics.stats.requestCount,
                          eventCount: eventCount,
                          workEnd: workEnd,
                          parkAt: parkAt,
                          duration: duration,
                          firstStarts: firstStarts,
                          plan: plan)
        batch.end = end
        flush()
        return end
    }

    // MARK: - Détails

    private func ingestEvents() {
        eventCount += events.count
        for event in events { cueStream.ingest(event) }
        events.removeAll(keepingCapacity: true)
    }

    private func updateBucket(_ index: Int, _ change: (inout ActivityBucket) -> Void) {
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

    private func closeBuckets(before index: Int) {
        var count = 0
        while count < openBuckets.count && openBuckets[count].index < index { count += 1 }
        guard count > 0 else { return }
        batch.buckets.append(contentsOf: openBuckets[0..<count])
        openBuckets.removeFirst(count)
    }

    private func deliverIfDue() {
        if batchedRequests >= batchRequests || mechanics.clock - lastDelivery >= batchSeconds {
            flush()
        }
    }

    private func flush() {
        cueStream.release(into: &batch.cues)
        batch.cueWatermark = cueStream.watermark
        batch.clock = mechanics.clock
        let outgoing = batch
        batch = PassBatch()
        batchedRequests = 0
        lastDelivery = mechanics.clock
        deliver(outgoing)
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
