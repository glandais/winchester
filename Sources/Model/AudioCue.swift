import Foundation
import DiskCore

struct ChatterSeek: Sendable {
    let offset: Double
    let profile: SeekProfile
    let travelMix: Double
}

/// Les deux micro-transitoires d'une lecture : commutation de tête et pas de
/// piste.
///
/// Ils vivent ici et non dans `SeekSynth`, qui les rend : la traduction de la
/// chronologie mécanique en repères appartient à la couche modèle, où elle se
/// teste, et le synthétiseur n'a pas à être compilé pour cela.
enum HeadTick: Sendable {
    case headSwitch
    case trackStep
}

/// Un micro-transitoire dans un train, daté depuis le début du train.
struct TrainTick: Sendable, Equatable {
    let offset: Double
    let kind: HeadTick
}

enum AudioCueKind: Sendable {
    case spinUp(duration: Double)
    case spinDown(duration: Double)
    case seek(profile: SeekProfile, travelMix: Double)
    case chatter(run: [ChatterSeek], duration: Double)
    case tick(HeadTick)
    /// Micro-transitoires trop rapprochés pour s'éteindre l'un avant l'autre :
    /// rendus ensemble, d'un seul passage dans le banc de résonateurs.
    case tickTrain(ticks: [TrainTick], duration: Double)
    /// Décollement des têtes à la mise sous tension.
    case unstick
    /// Atterrissage des têtes à l'arrêt.
    case landing
}

struct AudioCue: Sendable {
    let time: Double
    let kind: AudioCueKind
}

/// Traduit la chronologie mécanique en repères audio jouables.
///
/// C'est ici que vit la règle héritée de l'émulation de lecteur de disquette
/// de MAME : *« We start with a step sample. If another step occurs before the
/// step sample has completed, we switch to the seek sample. »* Deux seeks
/// rapprochés ne donnent jamais deux one-shots superposés mais un seul rendu
/// continu, avec le transitoire terminal replacé à la fin du train.
enum AudioCueBuilder {

    /// Au-delà de ce silence entre deux seeks, on considère que le premier a eu
    /// le temps de s'éteindre et qu'un nouveau one-shot est légitime.
    static let coalesceWindow = 0.030

    /// Un train plus long est découpé : borne le coût de rendu et la latence.
    static let maxChatterDuration = 1.0

    /// Au-delà de ce silence entre deux micro-transitoires, le premier s'est
    /// éteint et le second repart en one-shot. En deçà, ils forment un train.
    ///
    /// Il remplace un filtre qui, pour éviter la mitraillette, supprimait tout
    /// micro-transitoire à moins de 18 ms du précédent. Or une lecture
    /// séquentielle sur un disque à une tête franchit une piste à chaque tour —
    /// 8,33 ms à 7 200 tr/min : une cadence de 120 Hz, qui n'est plus une suite
    /// de tics mais une **hauteur**, le sifflement d'une grosse lecture. Le
    /// filtre en supprimait un sur deux et en faisait un cliquetis à 60 Hz.
    /// Sur un disque à quatre têtes, il écrasait les deux périodicités
    /// emboîtées — la commutation à chaque tour, le pas de piste tous les
    /// quatre — qui sont le son d'une lecture sur plusieurs plateaux. La
    /// mitraillette ne venait pas de la densité, mais de one-shots superposés :
    /// la réponse est celle des seeks rapprochés, un rendu continu.
    static let tickWindow = 0.030

    /// Tous les repères d'une trace entière. C'est le flux ci-dessous, nourri
    /// d'un coup : il n'y a qu'une règle, et elle ne dépend pas de la façon dont
    /// les événements arrivent.
    static func build(from trace: DiskTrace, cylinders: Int) -> [AudioCue] {
        var stream = CueStream(cylinders: cylinders)
        for event in trace.events { stream.ingest(event) }
        stream.finish()
        var cues: [AudioCue] = []
        stream.release(into: &cues)
        return cues
    }
}

/// Les repères audio, calculés au fil des événements mécaniques.
///
/// Les regroupements du constructeur sont tous **causaux à horizon borné** :
/// un train de seeks se referme au plus tard une seconde après son début, et un
/// micro-transitoire ne dépend que des trains commencés avant lui. On peut donc
/// les décider à mesure que la simulation avance, à condition de retenir ce qui
/// n'est pas encore tranché :
///
/// - le **train ouvert**, qu'un seek à venir peut encore allonger ;
/// - les **micro-transitoires tombés pendant ce train**, dont on ne sait pas
///   encore s'il les recouvrira — sa fin peut reculer.
///
/// Tout le reste sort dès qu'il est acquis. Le résultat est exactement celui du
/// calcul sur la trace entière, dans le même ordre : le flux ne relâche un
/// repère que lorsque plus aucun repère plus ancien ne peut apparaître, et la
/// garde est `watermark`.
///
/// Suppose les événements fournis dans l'ordre chronologique, ce que garantit
/// `DiskMechanics` : le bras ne fait qu'une chose à la fois, et son travail de
/// fond n'est joué que jusqu'à la requête qui arrive.
struct CueStream {

    private let cylinders: Int

    // Le train ouvert.
    private var run: [ChatterSeek] = []
    private var runStart = 0.0
    private var runEnd = 0.0

    /// Les intervalles couverts par les trains déjà refermés, du plus ancien au
    /// plus récent. Ceux qui se terminent avant le dernier micro-transitoire
    /// examiné ne peuvent plus rien recouvrir, et sortent par la tête.
    private var covers: [(start: Double, end: Double)] = []
    private var coverHead = 0

    /// Micro-transitoires en attente du verdict du train ouvert.
    private var pendingTicks: [(time: Double, kind: HeadTick)] = []

    /// Le train de micro-transitoires ouvert, qu'un tick à venir peut encore
    /// allonger.
    private var train: [TrainTick] = []
    private var trainStart = 0.0
    private var trainLast = 0.0

    /// Repères décidés, pas encore relâchés.
    private var ready: [AudioCue] = []
    private var lastEventTime = -Double.infinity
    private var finished = false

    init(cylinders: Int) {
        self.cylinders = cylinders
    }

    /// Instant avant lequel plus aucun repère ne peut apparaître.
    var watermark: Double {
        if finished { return .infinity }
        var mark = lastEventTime
        if !run.isEmpty { mark = min(mark, runStart) }
        if let first = pendingTicks.first { mark = min(mark, first.time) }
        if !train.isEmpty { mark = min(mark, trainStart) }
        return mark
    }

    mutating func ingest(_ event: DiskEvent) {
        let time = event.time
        lastEventTime = max(lastEventTime, time)

        // Un train qu'aucun seek à venir ne peut plus rejoindre est refermé
        // tout de suite, quel que soit l'événement qui le constate : c'est ce
        // qui laisse avancer la garde pendant une longue lecture.
        if !run.isEmpty,
           time >= runEnd + AudioCueBuilder.coalesceWindow
            || time - runStart >= AudioCueBuilder.maxChatterDuration {
            closeRun()
        }

        switch event.kind {
        case .spinUp(let duration):
            ready.append(AudioCue(time: time, kind: .spinUp(duration: duration)))
        case .spinDown(let duration):
            ready.append(AudioCue(time: time, kind: .spinDown(duration: duration)))
        case .seek(let profile):
            let seek = ChatterSeek(offset: run.isEmpty ? 0 : time - runStart,
                                   profile: profile,
                                   travelMix: travelMix(profile.distance))
            if run.isEmpty {
                runStart = time
                runEnd = time + profile.total
            } else {
                runEnd = max(runEnd, time + profile.total)
            }
            run.append(seek)
        case .headSwitch:
            tick(at: time, .headSwitch)
        case .trackStep:
            tick(at: time, .trackStep)
        case .transfer:
            break
        case .headUnstick:
            ready.append(AudioCue(time: time, kind: .unstick))
        case .headLand:
            ready.append(AudioCue(time: time, kind: .landing))
        }
        closeTrainIfSettled(now: time)
    }

    /// La trace est finie : ce qui était en suspens est tranché.
    mutating func finish() {
        if !run.isEmpty { closeRun() }
        if !train.isEmpty { closeTrain() }
        finished = true
    }

    /// Relâche, dans l'ordre chronologique, les repères que plus rien ne peut
    /// précéder.
    mutating func release(into output: inout [AudioCue]) {
        guard !ready.isEmpty else { return }
        let mark = watermark
        ready.sort { $0.time < $1.time }
        var count = 0
        while count < ready.count && ready[count].time < mark { count += 1 }
        guard count > 0 else { return }
        output.append(contentsOf: ready[0..<count])
        ready.removeFirst(count)
    }

    private func travelMix(_ distance: Int) -> Double {
        min(max(Double(distance) / Double(max(cylinders - 1, 1)), 0), 1)
    }

    private mutating func tick(at time: Double, _ kind: HeadTick) {
        if run.isEmpty {
            resolve(time: time, kind: kind)
        } else {
            pendingTicks.append((time, kind))
        }
    }

    private mutating func closeRun() {
        if run.count == 1 {
            ready.append(AudioCue(time: runStart,
                                  kind: .seek(profile: run[0].profile, travelMix: run[0].travelMix)))
        } else {
            ready.append(AudioCue(time: runStart,
                                  kind: .chatter(run: run, duration: runEnd - runStart)))
        }
        covers.append((runStart, runEnd))
        run.removeAll(keepingCapacity: true)

        let waiting = pendingTicks
        pendingTicks.removeAll(keepingCapacity: true)
        for tick in waiting { resolve(time: tick.time, kind: tick.kind) }
    }

    /// Les micro-transitoires masqués par un seek en cours sont absorbés ; les
    /// autres rejoignent le train ouvert ou en commencent un.
    private mutating func resolve(time: Double, kind: HeadTick) {
        while coverHead < covers.count && covers[coverHead].end < time { coverHead += 1 }
        if coverHead > 1_024 && coverHead * 2 > covers.count {
            covers.removeFirst(coverHead)
            coverHead = 0
        }
        if coverHead < covers.count,
           time >= covers[coverHead].start,
           time <= covers[coverHead].end {
            return
        }
        if !train.isEmpty && !joinsTrain(time) { closeTrain() }
        if train.isEmpty { trainStart = time }
        train.append(TrainTick(offset: time - trainStart, kind: kind))
        trainLast = time
    }

    /// Un micro-transitoire à cet instant rejoindrait-il le train ouvert ? Même
    /// règle que les seeks : le précédent ne s'est pas encore éteint, et le
    /// train ne dépasse pas une seconde.
    private func joinsTrain(_ time: Double) -> Bool {
        time < trainLast + AudioCueBuilder.tickWindow
            && time - trainStart < AudioCueBuilder.maxChatterDuration
    }

    /// Referme le train dès qu'aucun micro-transitoire à venir ne peut plus le
    /// rejoindre. Le plus précoce possible est le premier en attente d'un
    /// train de seeks, ou à défaut l'événement qu'on vient de lire : c'est ce
    /// qui laisse avancer la garde pendant une longue lecture.
    private mutating func closeTrainIfSettled(now time: Double) {
        guard !train.isEmpty else { return }
        let earliest = min(pendingTicks.first?.time ?? time, time)
        if !joinsTrain(earliest) { closeTrain() }
    }

    private mutating func closeTrain() {
        if train.count == 1 {
            ready.append(AudioCue(time: trainStart, kind: .tick(train[0].kind)))
        } else {
            ready.append(AudioCue(time: trainStart,
                                  kind: .tickTrain(ticks: train, duration: trainLast - trainStart)))
        }
        train.removeAll(keepingCapacity: true)
    }
}
