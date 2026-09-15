import Foundation
import DiskCore

struct ChatterSeek {
    let offset: Double
    let profile: SeekProfile
    let travelMix: Double
}

enum AudioCueKind {
    case spinUp(duration: Double)
    case spinDown(duration: Double)
    case seek(profile: SeekProfile, travelMix: Double)
    case chatter(run: [ChatterSeek], duration: Double)
    case tick(SeekSynth.Tick)
}

struct AudioCue {
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
    private static let coalesceWindow = 0.030

    /// Un train plus long est découpé : borne le coût de rendu et la latence.
    private static let maxChatterDuration = 1.0

    /// Espacement minimal entre deux micro-transitoires. Sans ce filtrage, une
    /// grosse lecture séquentielle produit une mitraillette de commutations de
    /// tête au lieu d'un ronronnement.
    private static let minimumTickSpacing = 0.018

    static func build(from trace: DiskTrace, cylinders: Int) -> [AudioCue] {

        var seeks: [(time: Double, profile: SeekProfile)] = []
        var ticks: [(time: Double, kind: SeekSynth.Tick)] = []
        var cues: [AudioCue] = []

        for event in trace.events {
            switch event.kind {
            case .spinUp(let d):
                cues.append(AudioCue(time: event.time, kind: .spinUp(duration: d)))
            case .spinDown(let d):
                cues.append(AudioCue(time: event.time, kind: .spinDown(duration: d)))
            case .seek(let profile):
                seeks.append((event.time, profile))
            case .headSwitch:
                ticks.append((event.time, .headSwitch))
            case .trackStep:
                ticks.append((event.time, .trackStep))
            case .transfer:
                break
            }
        }

        func travelMix(_ distance: Int) -> Double {
            min(max(Double(distance) / Double(max(cylinders - 1, 1)), 0), 1)
        }

        // Regroupement des seeks en trains.
        var covered: [(start: Double, end: Double)] = []
        var index = 0
        while index < seeks.count {
            let start = seeks[index].time
            var end = start + seeks[index].profile.total
            var run = [ChatterSeek(offset: 0,
                                   profile: seeks[index].profile,
                                   travelMix: travelMix(seeks[index].profile.distance))]
            var next = index + 1

            while next < seeks.count,
                  seeks[next].time < end + coalesceWindow,
                  seeks[next].time - start < maxChatterDuration {
                let offset = seeks[next].time - start
                run.append(ChatterSeek(offset: offset,
                                       profile: seeks[next].profile,
                                       travelMix: travelMix(seeks[next].profile.distance)))
                end = max(end, seeks[next].time + seeks[next].profile.total)
                next += 1
            }

            if run.count == 1 {
                cues.append(AudioCue(time: start,
                                     kind: .seek(profile: run[0].profile,
                                                 travelMix: run[0].travelMix)))
            } else {
                cues.append(AudioCue(time: start,
                                     kind: .chatter(run: run, duration: end - start)))
            }

            covered.append((start, end))
            index = next
        }

        // Les micro-transitoires masqués par un seek en cours sont absorbés.
        var coverIndex = 0
        var lastTickTime = -Double.infinity
        for tick in ticks {
            while coverIndex < covered.count && covered[coverIndex].end < tick.time {
                coverIndex += 1
            }
            if coverIndex < covered.count,
               tick.time >= covered[coverIndex].start,
               tick.time <= covered[coverIndex].end {
                continue
            }
            guard tick.time - lastTickTime >= minimumTickSpacing else { continue }
            lastTickTime = tick.time
            cues.append(AudioCue(time: tick.time, kind: .tick(tick.kind)))
        }

        cues.sort { $0.time < $1.time }
        return cues
    }
}
