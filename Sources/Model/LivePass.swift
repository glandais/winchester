import Foundation
import DiskCore

/// Ce que le moteur audio attend d'une passe qu'on écoute.
protocol PassFeed: AnyObject {
    /// L'écoute en est là : ce qui est dû est appliqué, ce qui est passé est
    /// oublié, et la suite est réclamée au producteur.
    func update(now: Double)
    /// Les repères antérieurs à `time`, retirés de la file.
    func takeCues(before time: Double) -> [AudioCue]
    /// Jusqu'où les repères sont complets. Au-delà, l'audio manquerait.
    var cueWatermark: Double { get }
    /// Fin de la passe, queue comprise, une fois connue.
    var endTime: Double? { get }
}

/// Le cumul de l'activité jusqu'à l'instant écouté.
struct ActivityTotals: Sendable, Equatable {
    var requests = 0
    var seeks = 0
    var seekDistance = 0
    var movedBytes = 0
    var detail = ActivityDetail()

    var averageSeekDistance: Int { seeks > 0 ? seekDistance / seeks : 0 }
}

/// Une passe telle qu'on l'écoute : l'instant présent, et rien d'autre.
///
/// Tout ce qui s'affichait à un instant quelconque de la passe se lit ici à
/// l'instant écouté seulement. Ce qui est passé est oublié dès qu'aucune image
/// ne peut plus le montrer — une traînée de deux secondes sur le plateau, un
/// tiers de seconde sur la carte, une minute d'activité pour le bandeau — et ce
/// qui est à venir attend son instant. La mémoire suit ces fenêtres, pas la
/// durée de la passe.
///
/// Ni la durée totale ni le retour en arrière n'existent plus : le bilan n'est
/// connu qu'une fois la passe finie, et revenir au début, c'est en relancer
/// une.
final class LivePass: PassFeed {

    /// Ce que le bandeau d'activité montre du passé.
    static let activityWindow = 60.0
    /// Ce que le plateau garde d'échantillons écoulés : sa traînée dure au plus
    /// deux secondes.
    private static let sampleMemory = 2.5
    /// Ce que la carte garde d'accès écoulés : sa rémanence dure un tiers de
    /// seconde, et le surlignage d'un bloc un peu plus d'un dixième.
    private static let activityMemory = 1.0

    let geometry: DriveGeometry
    let seekModel: SeekModel
    let spindle: SpindleTimeline
    let phases: [PhaseDescriptor]
    let map: ClusterMapPlayer?

    private let session: PassSession?

    private(set) var now = 0.0

    // Plateau.
    private(set) var samples: [HeadSample] = []
    private(set) var parkAt: Double?

    // Carte.
    private(set) var activity: [ClusterActivity] = []

    // Audio.
    private var cues: [AudioCue] = []
    private var cueHead = 0
    private(set) var cueWatermark = -Double.infinity

    // Activité.
    private(set) var buckets: [ActivityBucket] = []
    private(set) var totals = ActivityTotals()
    private var totalledThrough = -1
    private(set) var phaseMarks: [PhaseMark] = []
    /// Le temps écouté dans chaque phase, dans l'ordre où elles sont apparues.
    ///
    /// Les repères, eux, sont oubliés au bout d'une minute, et une passe alterne
    /// sans cesse entre deux phases — les fichiers d'une catégorie, puis la
    /// réécriture des tables, fichier après fichier. Ce cumul est la seule trace
    /// qui reste de tout ce qui a été écouté : quelques entrées, une par phase.
    private(set) var phaseTimes: [PhaseTime] = []
    /// Jusqu'où le cumul est fait.
    private var phaseClock = 0.0
    private var progressMarks: [ProgressMark] = []
    private var moveMarks: [MoveMark] = []

    /// Fin de la dernière requête produite : jusqu'où la passe est connue.
    private(set) var producedThrough = 0.0
    private(set) var end: PassEnd?

    /// - Parameters:
    ///   - session: le producteur, ou `nil` pour une passe nourrie à la main
    ///     avec `absorb(_:)`.
    ///   - map: l'état de départ de la carte, pour une défragmentation.
    init(session: PassSession?,
         geometry: DriveGeometry,
         seekModel: SeekModel,
         spindle: SpindleTimeline,
         phases: [PhaseDescriptor],
         map: (clusterCount: Int, initialRuns: [MapRun])? = nil) {
        self.session = session
        self.geometry = geometry
        self.seekModel = seekModel
        self.spindle = spindle
        self.phases = phases
        if let map {
            let player = ClusterMapPlayer()
            player.load(clusterCount: map.clusterCount, initialRuns: map.initialRuns)
            self.map = player
        } else {
            self.map = nil
        }
    }

    deinit {
        // Un producteur qui attend l'écoute l'attendrait sinon pour toujours.
        session?.cancel()
    }

    // MARK: - Le fil de l'écoute

    var endTime: Double? { end?.duration }

    var isFinished: Bool { end.map { now >= $0.duration } ?? false }

    func update(now time: Double) {
        if let session {
            absorb(session.drain(listenedThrough: time))
        }
        advance(to: time)
    }

    /// Range un paquet produit, sans rien appliquer.
    func absorb(_ batch: PassBatch) {
        cues.append(contentsOf: batch.cues)
        cueWatermark = max(cueWatermark, batch.cueWatermark)
        samples.append(contentsOf: batch.samples)
        activity.append(contentsOf: batch.activity)
        map?.enqueue(batch.mutations)
        buckets.append(contentsOf: batch.buckets)
        phaseMarks.append(contentsOf: batch.phases)
        progressMarks.append(contentsOf: batch.progress)
        moveMarks.append(contentsOf: batch.moves)
        producedThrough = max(producedThrough, batch.clock)
        if let end = batch.end {
            self.end = end
            parkAt = end.parkAt
            cueWatermark = .infinity
        }
    }

    /// Avance l'écoute : la carte applique ce qui est dû, et ce qu'aucune
    /// image ne montrera plus est oublié. On n'avance jamais à reculons.
    func advance(to time: Double) {
        guard time >= now else { return }
        now = time
        map?.advance(to: time)

        // Le cumul prend chaque tranche une fois, quand l'écoute la dépasse.
        let current = ActivityBucket.index(at: time)
        for bucket in buckets where bucket.index > totalledThrough && bucket.index <= current {
            totals.requests += bucket.requests
            totals.seeks += bucket.seeks
            totals.seekDistance += bucket.seekDistance
            totals.movedBytes += bucket.movedBytes
            totals.detail.add(bucket.detail)
            totalledThrough = bucket.index
        }

        accountPhases(until: time)
        forget()
    }

    /// Ajoute au cumul par phase le temps écouté depuis le dernier appel. Les
    /// repères utiles sont encore là : l'oubli garde la dernière phase entamée,
    /// et l'écoute n'avance jamais d'une minute d'un coup.
    private func accountPhases(until time: Double) {
        guard time > phaseClock else { return }
        var cursor = phaseClock
        var current = phaseMarks.last { $0.time <= cursor }?.index ?? 0
        for mark in phaseMarks where mark.time > cursor && mark.time <= time {
            addPhaseTime(current, mark.time - cursor)
            cursor = mark.time
            current = mark.index
        }
        addPhaseTime(current, time - cursor)
        phaseClock = time
    }

    private func addPhaseTime(_ index: Int, _ seconds: Double) {
        if let slot = phaseTimes.firstIndex(where: { $0.index == index }) {
            phaseTimes[slot].seconds += seconds
        } else if seconds > 0 {
            phaseTimes.append(PhaseTime(index: index, seconds: seconds))
        }
    }

    func takeCues(before time: Double) -> [AudioCue] {
        var count = 0
        while cueHead + count < cues.count && cues[cueHead + count].time < time { count += 1 }
        guard count > 0 else { return [] }
        let taken = Array(cues[cueHead..<(cueHead + count)])
        cueHead += count
        if cueHead > 1_024 && cueHead * 2 > cues.count {
            cues.removeFirst(cueHead)
            cueHead = 0
        }
        return taken
    }

    private func forget() {
        // Un échantillon sert tant qu'il est le dernier commencé : c'est de
        // lui que part le bras au prochain seek. On ne retire donc le premier
        // que si le suivant, déjà commencé, est lui-même hors de la traînée.
        let sampleHorizon = now - Self.sampleMemory
        var drop = 0
        while drop + 1 < samples.count && samples[drop + 1].time <= sampleHorizon { drop += 1 }
        if drop > 0 { samples.removeFirst(drop) }

        let activityHorizon = now - Self.activityMemory
        drop = 0
        while drop + 1 < activity.count && activity[drop + 1].start <= activityHorizon { drop += 1 }
        if drop > 0 { activity.removeFirst(drop) }

        let bucketHorizon = ActivityBucket.index(at: max(now - Self.activityWindow, 0))
        drop = 0
        while drop < buckets.count && buckets[drop].index < bucketHorizon { drop += 1 }
        if drop > 0 { buckets.removeFirst(drop) }

        // Une phase sortie du bandeau reste utile tant qu'elle est la phase en
        // cours, et l'avancement ne sert que par sa dernière valeur écoulée.
        let windowStart = now - Self.activityWindow
        drop = 0
        while drop + 1 < phaseMarks.count && phaseMarks[drop + 1].time <= windowStart { drop += 1 }
        if drop > 0 { phaseMarks.removeFirst(drop) }

        drop = 0
        while drop + 1 < progressMarks.count && progressMarks[drop + 1].time <= now { drop += 1 }
        if drop > 0 { progressMarks.removeFirst(drop) }

        drop = 0
        while drop + 1 < moveMarks.count && moveMarks[drop + 1].time <= now { drop += 1 }
        if drop > 0 { moveMarks.removeFirst(drop) }
    }

    // MARK: - Lectures à l'instant écouté

    /// La phase en cours.
    var phaseIndex: Int {
        phaseMarks.last { $0.time <= now }?.index ?? 0
    }

    var phase: PhaseDescriptor? {
        phases.indices.contains(phaseIndex) ? phases[phaseIndex] : phases.first
    }

    /// Fichiers déplacés et évacuations comptés par la stratégie jusqu'à
    /// l'instant écouté ; `nil` tant qu'elle n'a rien compté, ou pour un
    /// démarrage.
    var moves: MoveCount? {
        moveMarks.last { $0.time <= now }?.moves
    }

    /// L'avancement annoncé par l'outil, s'il en annonce un.
    var progress: Double? {
        guard end.map({ now >= $0.workEnd }) != true else { return 1 }
        return progressMarks.last { $0.time <= now }?.value
    }

    /// La tranche d'activité en cours.
    var currentBucket: ActivityBucket? {
        let index = ActivityBucket.index(at: now)
        return buckets.last { $0.index == index }
    }

    var requestRate: Double {
        Double(currentBucket?.requests ?? 0) / ActivityBucket.duration
    }

    var throughputMBs: Double {
        Double(currentBucket?.bytes ?? 0) / ActivityBucket.duration / 1_000_000
    }

    var platter: PlatterTrack {
        PlatterTrack(geometry: geometry, seekModel: seekModel, samples: samples,
                     spindle: spindle, parkAt: parkAt)
    }

    /// Cellule en cours d'accès, s'il y en a une à cet instant.
    func activeCell() -> (cell: Int, isWrite: Bool)? {
        guard let map, let current = activity.last(where: { $0.start <= now }) else { return nil }
        // Au-delà de la fin de l'opération on garde le surlignage un court
        // instant : à 60 images par seconde, la plupart des transferts durent
        // moins d'une image et clignoteraient.
        guard now - current.end < 0.12 else { return nil }
        return (map.cell(ofCluster: current.cluster), current.isWrite)
    }

    /// Les accès encore visibles sur la carte.
    func mapTrail() -> [MapTrailPoint] {
        guard let map else { return [] }
        return MapTrail.points(in: activity, at: now) { map.cell(ofCluster: $0) }
    }
}
