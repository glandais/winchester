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

struct DiskTrace {
    let events: [DiskEvent]
    let headSamples: [HeadSample]
    let timings: [RequestTiming]
    /// Montée en régime du plateau, pour l'affichage.
    let spindle: SpindleTimeline
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
                  spindle: spindle, duration: duration, stats: stats)
    }
}

/// Rejoue une liste de requêtes bloc sur la géométrie et le modèle de seek,
/// et en déduit la chronologie mécanique exacte.
///
/// File d'attente FIFO, sans réordonnancement d'ascenseur : c'est volontaire,
/// un contrôleur IDE de cette époque ne réordonnait quasiment rien, et c'est
/// précisément ce qui rend le crépitement si dense.
enum DiskSimulator {

    static func run(geometry: DriveGeometry,
                    seekModel: SeekModel,
                    requests: [BlockRequest],
                    totalDuration: Double,
                    spinUpAt: Double,
                    spinUpDuration: Double) -> DiskTrace {

        var events: [DiskEvent] = []
        var samples: [HeadSample] = []
        var timings: [RequestTiming] = []
        // Une passe d'époque produit des millions d'événements. Sans réserve,
        // chaque doublement de tableau recopie tout et garde transitoirement
        // les deux versions : c'est un pic de mémoire pour rien.
        timings.reserveCapacity(requests.count)
        samples.reserveCapacity(requests.count)
        events.reserveCapacity(requests.count * 3)
        var stats = TraceStats()

        events.append(DiskEvent(time: spinUpAt, kind: .spinUp(duration: spinUpDuration)))

        let revolution = geometry.revolutionDuration
        var clock = spinUpAt + spinUpDuration
        // Au repos le bras est parqué au diamètre intérieur (ou sur une rampe
        // hors plateau). Le premier accès est donc une course quasi complète :
        // c'est le « clac » franc qu'on entend juste après le lancement du moteur.
        var headCylinder = geometry.parkCylinder
        var headIndex = 0

        for request in requests {
            // Le disque ne repart pas à la milliseconde où il s'est arrêté :
            // la machine a peut-être quelque chose à faire de ce qu'elle vient
            // de lire. `thinkTime` est nul partout sauf pour un démarrage.
            let issued = max(clock + request.thinkTime, request.issueTime)
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
                headCylinder = target.cylinder
            } else if target.head != headIndex {
                events.append(DiskEvent(time: t, kind: .headSwitch))
                t += seekModel.headSwitchDuration
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
                } else {
                    headIndex = 0
                    headCylinder = min(headCylinder + 1, geometry.cylinders - 1)
                    events.append(DiskEvent(time: t, kind: .trackStep))
                    t += seekModel.duration(distance: 1)
                }
            }

            samples.append(HeadSample(time: sampleTime,
                                      duration: Float(t - sampleTime),
                                      cylinder: Int32(sampleCylinder),
                                      endCylinder: Int32(headCylinder),
                                      head: UInt8(min(sampleHead, Int(UInt8.max))),
                                      isWrite: request.isWrite))

            let bytes = request.sectorCount * DriveGeometry.bytesPerSector
            if request.isWrite { stats.bytesWritten += bytes } else { stats.bytesRead += bytes }
            stats.requestCount += 1
            stats.busySeconds += transferSeconds
            timings.append(RequestTiming(start: issued, end: t))

            clock = t
        }

        events.sort { $0.time < $1.time }

        let end = max(totalDuration, clock)
        let spindle = SpindleTimeline(spinUpAt: spinUpAt, duration: spinUpDuration, rpm: geometry.rpm)
        return DiskTrace(events: events, headSamples: samples, timings: timings,
                         spindle: spindle, duration: end, stats: stats)
    }
}
