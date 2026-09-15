import Foundation

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

/// Position de la tête échantillonnée au fil du temps, pour l'affichage.
struct HeadSample {
    let time: Double
    let cylinder: Int
    let isWrite: Bool
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
    let duration: Double
    let stats: TraceStats
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
        timings.reserveCapacity(requests.count)
        var stats = TraceStats()

        events.append(DiskEvent(time: spinUpAt, kind: .spinUp(duration: spinUpDuration)))

        let revolution = geometry.revolutionDuration
        var clock = spinUpAt + spinUpDuration
        // Au repos le bras est parqué au diamètre intérieur (ou sur une rampe
        // hors plateau). Le premier accès est donc une course quasi complète :
        // c'est le « clac » franc qu'on entend juste après le lancement du moteur.
        var headCylinder = geometry.cylinders - 1
        var headIndex = 0

        for request in requests {
            let issued = max(clock, request.issueTime)
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

            samples.append(HeadSample(time: t, cylinder: headCylinder, isWrite: request.isWrite))

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

            let bytes = request.sectorCount * DriveGeometry.bytesPerSector
            if request.isWrite { stats.bytesWritten += bytes } else { stats.bytesRead += bytes }
            stats.requestCount += 1
            stats.busySeconds += transferSeconds
            timings.append(RequestTiming(start: issued, end: t))

            clock = t
        }

        events.sort { $0.time < $1.time }

        let end = max(totalDuration, clock)
        return DiskTrace(events: events, headSamples: samples, timings: timings,
                         duration: end, stats: stats)
    }
}
