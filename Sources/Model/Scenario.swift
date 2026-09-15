import Foundation
import DiskCore

enum ScenarioKind: String, CaseIterable, Identifiable {
    case windowsBoot
    case defrag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsBoot: return "Démarrage"
        case .defrag:      return "Défragmentation"
        }
    }

    var summary: String {
        switch self {
        case .windowsBoot:
            return "Démarrage Windows puis lancement d'une suite bureautique, "
                + "sur un Barracuda ATA IV de 2001"
        case .defrag:
            return "Passe complète du défragmenteur de Windows 95 sur un volume FAT16 vieilli, "
                + "sur un Quantum Fireball 1080AT de 1996"
        }
    }

    /// Ce que disent les notes de modélisation du volume sous la passe. Un
    /// disque venu de la galerie n'a pas la même histoire qu'un volume vieilli
    /// sur place, et c'est la seule ligne des notes qui change.
    var volumeNote: String {
        switch self {
        case .windowsBoot:
            return ""
        case .defrag:
            return "Partition FAT16 vieillie par deux ans d'usage simulé : installation, "
                + "puis créations, suppressions et réenregistrements. L'allocateur next-fit "
                + "de VFAT suffit à tout disperser, aucun mécanisme exotique n'intervient."
        }
    }

    var label: ScenarioLabel {
        ScenarioLabel(title: title, summary: summary, volumeNote: volumeNote)
    }
}

/// Ce qu'on demande à un disque de la galerie : de démarrer, ou d'être rangé.
///
/// Les deux passent par le même disque et le même matériel, et diffèrent
/// entièrement par ce qu'ils vont chercher — l'un lit des fichiers là où ils
/// sont, l'autre les déplace là où ils devraient être.
enum GeneratedActivity: String, Hashable, CaseIterable, Sendable {
    case boot
    case defrag

    /// Ce que le bouton de la galerie dit qu'il va faire.
    var action: String {
        switch self {
        case .boot:   return "Démarrer cet OS"
        case .defrag: return "Défragmenter ce disque"
        }
    }
}

/// Ce que le sélecteur de scénario propose.
///
/// Les deux scénarios livrés sont toujours là ; un disque de la galerie s'y
/// ajoute quand on demande à le démarrer ou à le défragmenter, et y reste tant
/// qu'on n'en confie pas un autre au simulateur.
enum ScenarioSelection: Hashable, Identifiable {
    case builtin(ScenarioKind)
    /// Identifiant du profil de la galerie, et ce qu'on lui demande.
    case generated(String, GeneratedActivity)

    var isGenerated: Bool {
        if case .generated = self { return true }
        return false
    }

    /// Clé d'ordre stable : les scénarios livrés d'abord, dans l'ordre de leur
    /// déclaration, puis les disques générés par identifiant de profil.
    var sortKey: String {
        switch self {
        case let .builtin(kind):
            return "0\(ScenarioKind.allCases.firstIndex(of: kind) ?? 0)"
        case let .generated(id, activity):
            return "1\(activity.rawValue)\(id)"
        }
    }

    var id: String { sortKey }
}

/// Ce que l'interface affiche d'un scénario : son nom dans le sélecteur, sa
/// phrase de résumé sous le titre, et la description de son volume dans les
/// notes de modélisation.
///
/// Les deux scénarios livrés tirent ces trois textes de leur `ScenarioKind` ;
/// un disque venu de la galerie les tire de son profil. C'est la seule chose
/// qui les distingue une fois la passe planifiée.
struct ScenarioLabel {
    let title: String
    let summary: String
    let volumeNote: String
}

/// Mutation de la carte des clusters, datée par la simulation.
struct TimedMutation {
    let time: Double
    let start: Int
    let count: Int
    let category: UInt8
}

/// Cluster touché à un instant donné, pour surligner la carte.
struct ClusterActivity {
    let start: Double
    let end: Double
    let cluster: Int
    let isWrite: Bool
}

/// Tout ce qu'il faut pour rejouer visuellement une défragmentation.
struct DefragPlayback {
    let partition: PartitionGeometry
    let plan: DefragPlan
    let mutations: [TimedMutation]
    let activity: [ClusterActivity]
    /// Octets déplacés cumulés, par tranche de `SimulationModel.bucketDuration`.
    let movedBytes: [Double]
    let workEndTime: Double
}

/// Ce qu'un démarrage a lu, une fois la passe simulée. C'est le bilan que
/// l'écran affiche et que le rendu hors-ligne imprime : un démarrage n'a pas de
/// carte de clusters à montrer — il ne déplace rien — mais il a des comptes à
/// rendre.
struct BootPlayback {
    let osName: String
    let appName: String?
    let filesRead: Int
    let residentFiles: Int
    /// Ce que le système aurait mis sans disque : la somme des calculs.
    let thinkSeconds: Double
    /// Ce que le disque a ajouté par-dessus.
    let diskSeconds: Double
    /// Ce qu'aurait duré le même démarrage si le volume n'avait jamais vieilli :
    /// mêmes fichiers, mêmes tailles, même ordre, chacun d'un seul tenant. La
    /// différence avec la durée réelle est le prix de la fragmentation, et il
    /// n'y a aucun autre écart entre les deux mesures.
    let freshSeconds: Double
}

/// Un scénario entièrement calculé : requêtes, chronologie mécanique, repères
/// audio et séries d'affichage.
struct Scenario {
    let kind: ScenarioKind
    let label: ScenarioLabel
    let geometry: DriveGeometry
    let seekModel: SeekModel
    /// Nombre de requêtes bloc de la passe. La liste elle-même n'est pas
    /// conservée : rien ne la relit une fois la chronologie mécanique obtenue,
    /// et elle compte plus d'un million d'entrées sur les gros volumes.
    let requestCount: Int
    let spans: [PhaseSpan]
    let trace: DiskTrace
    let cues: [AudioCue]
    let duration: Double

    let iops: [Double]
    let throughputMBs: [Double]
    let peakIOPS: Double

    let defrag: DefragPlayback?
    let boot: BootPlayback?

    var stats: TraceStats { trace.stats }
}

enum ScenarioBuilder {

    static let bucketDuration = 0.1

    static func build(_ kind: ScenarioKind) -> Scenario {
        switch kind {
        case .windowsBoot: return buildWindowsBoot()
        case .defrag:      return buildDefrag()
        }
    }

    // MARK: - Démarrage Windows

    private static func buildWindowsBoot() -> Scenario {
        let drive = DriveCatalog.bootDrive
        let geometry = drive.geometry
        let seekModel = drive.seekModel
        let phases = WorkloadLibrary.windowsBootAndOffice

        let generator = WorkloadGenerator(geometry: geometry)
        let (requests, spans) = generator.generate(phases: phases)
        let total = spans.last?.end ?? 0
        let spinUpDuration = (phases.first?.duration ?? 6) - 0.6

        let trace = DiskSimulator.run(
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            totalDuration: total,
            spinUpAt: 0.35,
            spinUpDuration: spinUpDuration
        )

        let series = buildSeries(requests: requests, trace: trace, duration: trace.duration)

        return Scenario(
            kind: .windowsBoot,
            label: ScenarioKind.windowsBoot.label,
            geometry: geometry,
            seekModel: seekModel,
            requestCount: requests.count,
            spans: spans,
            trace: trace.summarized(),
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: trace.duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: nil,
            boot: nil
        )
    }

    // MARK: - Démarrage d'un disque de la galerie

    /// Le même geste que le démarrage livré, mais sur un disque qu'on vient de
    /// fabriquer — et surtout, décrit autrement.
    ///
    /// Le scénario livré nomme des **fractions du plateau** ; celui-ci nomme
    /// des **fichiers**, et les prend là où l'allocateur les a laissés. C'est
    /// ce qui lui permet d'exister sur les vingt disques de la galerie au lieu
    /// d'un seul, et c'est aussi ce qui rend sa durée intéressante : elle n'est
    /// pas décrétée. Le système calcule entre deux lectures — c'est le
    /// plancher — et le disque ajoute ce qu'il ajoute.
    ///
    /// Rien n'est refusé ici : lire des fichiers ne suppose aucune stratégie de
    /// rangement, donc NTFS démarre comme les autres.
    static func build(boot disk: GeneratedDisk) -> Scenario {
        let plan = BootPlanner.plan(disk: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: plan.partition.totalSectors)

        let trace = DiskSimulator.run(
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            requests: plan.requests,
            totalDuration: 0,
            spinUpAt: 0.35,
            spinUpDuration: max(plan.post - 0.6, 0.5)
        )

        let duration = (trace.timings.last?.end ?? 0) + plan.tail

        // Le témoin : le même contenu jamais fragmenté. Une seconde passe de
        // planification et de simulation, sur quelques milliers de requêtes —
        // le prix d'une phrase qui dit ce que ce volume-ci coûte.
        let fresh = BootPlanner.plan(disk: disk.freshlyInstalled())
        let freshTrace = DiskSimulator.run(geometry: hardware.geometry,
                                           seekModel: hardware.seek,
                                           requests: fresh.requests,
                                           totalDuration: 0,
                                           spinUpAt: 0.35,
                                           spinUpDuration: max(plan.post - 0.6, 0.5))
        let freshSeconds = (freshTrace.timings.last?.end ?? 0) + fresh.tail

        let spans = closedLoopSpans(requests: plan.requests,
                                    trace: trace,
                                    descriptors: plan.phases,
                                    duration: duration)
        let series = buildSeries(requests: plan.requests, trace: trace, duration: duration)

        let launch = plan.appName.map { " puis lancement de \($0)" } ?? ""
        let note = "« \(disk.spec.displayName) », généré par la galerie : "
            + "\(disk.spec.fileSystem.type.rawValue.uppercased()) de \(disk.spec.disk.sizeMB) Mo "
            + "en clusters de \(disk.clusterBytes / 1_024) Ko, vieilli sur \(disk.dayCount) jours. "
            + "Le démarrage n'est pas décrit en fractions du plateau mais en fichiers : "
            + "\(plan.filesRead) fichiers du catalogue sont ouverts et lus là où l'allocateur "
            + "les a laissés. Le système compte \(format(seconds: plan.thinkSeconds)) de calcul "
            + "entre deux lectures ; tout ce que la passe dure en plus vient du disque. "
            + "Le même contenu jamais fragmenté démarrerait en "
            + "\(format(seconds: freshSeconds))."

        return Scenario(
            kind: .windowsBoot,
            label: ScenarioLabel(title: disk.spec.displayName,
                                 summary: "Démarrage de \(plan.osName)\(launch), "
                                     + "sur \(hardware.geometry.model)",
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            requestCount: plan.requests.count,
            spans: spans,
            trace: trace.summarized(),
            cues: AudioCueBuilder.build(from: trace, cylinders: hardware.geometry.cylinders),
            duration: duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: nil,
            boot: BootPlayback(osName: plan.osName,
                               appName: plan.appName,
                               filesRead: plan.filesRead,
                               residentFiles: plan.residentFiles,
                               thinkSeconds: plan.thinkSeconds,
                               diskSeconds: max(duration - plan.tail - plan.thinkSeconds, 0),
                               freshSeconds: freshSeconds)
        )
    }

    private static func format(seconds: Double) -> String {
        seconds >= 60
            ? String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
            : String(format: "%.1f s", seconds).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Défragmentation

    /// Partition C: de 180 Mo en tête d'un disque de 876 Mo, clusters de 4 Ko —
    /// ce que donnait `FORMAT` pour cette taille en FAT16. Elle occupe les 21 %
    /// extérieurs du plateau, et les tables d'allocation sont à son tout début :
    /// valider un déplacement fait revenir le bras au bord, d'où le
    /// « clac … clac » régulier.
    ///
    /// Une passe complète dure ici un peu plus de trois minutes. Sur un volume
    /// de l'époque réellement dimensionné (500 Mo à 1 Go) elle en prenait vingt
    /// à quarante-cinq : c'est le volume qui est réduit, pas le modèle.
    static let partitionSectors = 180_000_000 / DriveGeometry.bytesPerSector
    static let clusterSectors = 8
    static let volumeFill = 0.78

    /// Silence final, une fois la passe terminée.
    private static let tailDuration = 3.5

    private static func buildDefrag() -> Scenario {
        let partition = PartitionGeometry(startLBA: 0,
                                          sectors: partitionSectors,
                                          clusterSectors: clusterSectors)
        let volume = VolumeFactory.agedWindows95(partition: partition, fill: volumeFill)

        return assembleDefrag(volume: volume.defragVolume(),
                              geometry: DriveCatalog.defragDrive.geometry,
                              seekModel: DriveCatalog.defragDrive.seekModel,
                              label: ScenarioKind.defrag.label)
    }

    // MARK: - Défragmentation d'un disque de la galerie

    /// Même passe, sur un volume venu du générateur de disques d'époque.
    ///
    /// Le disque est converti en volume à défragmenter par
    /// `GeneratedVolumeBridge` — qui refuse les formats que l'outil simulé ne
    /// sait pas ranger — et le matériel est celui que décrit la fiche du
    /// profil, pas le disque de 1996 du scénario livré : un 210 Mo à
    /// 3 600 tr/min de 1993 ne sonne pas comme un 1 Go à 5 400 tr/min de 1996,
    /// et c'est tout l'intérêt de l'exercice.
    static func build(generated disk: GeneratedDisk) throws -> Scenario {
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: volume.partition.totalSectors)

        let note = "« \(disk.spec.displayName) », généré par la galerie : "
            + "\(disk.spec.fileSystem.type.rawValue.uppercased()) de \(disk.spec.disk.sizeMB) Mo "
            + "en clusters de \(disk.clusterBytes / 1_024) Ko, vieilli sur \(disk.dayCount) jours. "
            + "Les fichiers gardent exactement les clusters que l'allocateur leur a donnés — "
            + "c'est ce volume-là qui est défragmenté, pas une approximation."

        return assembleDefrag(volume: volume,
                              geometry: hardware.geometry,
                              seekModel: hardware.seek,
                              label: ScenarioLabel(title: disk.spec.displayName,
                                                   summary: disk.spec.summary
                                                       ?? "Passe de défragmentation sur un disque généré",
                                                   volumeNote: note))
    }

    /// Planifie la passe sur un volume donné, la fait tourner sur le disque
    /// donné, et date tout ce que l'écran doit en montrer.
    ///
    /// `DefragPlanner.plan` travaille sur sa propre copie du volume — il y
    /// rejoue chaque déplacement pour connaître l'état d'arrivée — et ne touche
    /// pas à celui qu'on lui passe.
    private static func assembleDefrag(volume: DefragVolume,
                                       geometry: DriveGeometry,
                                       seekModel: SeekModel,
                                       label: ScenarioLabel) -> Scenario {
        let partition = volume.partition
        precondition(geometry.totalSectors >= partition.totalSectors,
                     "la partition déborde du disque qui la porte")

        let plan = DefragPlanner.plan(volume: volume)

        let requests = plan.operations.map {
            BlockRequest(issueTime: $0.issueTime,
                         lba: $0.lba,
                         sectorCount: $0.sectors,
                         isWrite: $0.isWrite,
                         phaseIndex: $0.phase)
        }

        // Le plateau tourne déjà : Windows est démarré. La rampe de 0,9 s n'est
        // qu'un fondu pour que la couche de rotation s'installe.
        let trace = DiskSimulator.run(
            geometry: geometry,
            seekModel: seekModel,
            requests: requests,
            totalDuration: 0,
            spinUpAt: 0,
            spinUpDuration: 0.9
        )

        let workEnd = trace.timings.last?.end ?? 0
        let duration = workEnd + tailDuration

        // Datation des mutations de la carte et des surlignages.
        var mutations: [TimedMutation] = []
        var activity: [ClusterActivity] = []
        var movedBytes = [Double](repeating: 0, count: bucketCount(duration))

        for (index, operation) in plan.operations.enumerated() {
            guard index < trace.timings.count else { break }
            let timing = trace.timings[index]

            for index in Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount) {
                let mutation = plan.mutations[index]
                mutations.append(TimedMutation(time: timing.end,
                                               start: mutation.start,
                                               count: mutation.count,
                                               category: mutation.category.rawValue))
            }
            if let cluster = operation.cluster {
                activity.append(ClusterActivity(start: timing.start, end: timing.end,
                                                cluster: cluster, isWrite: operation.isWrite))
            }
            if operation.kind == .writeExtent {
                let bucket = min(Int(timing.end / bucketDuration), movedBytes.count - 1)
                movedBytes[bucket] += Double(operation.sectors * DriveGeometry.bytesPerSector)
            }
        }
        mutations.sort { $0.time < $1.time }
        for index in 1..<max(movedBytes.count, 1) { movedBytes[index] += movedBytes[index - 1] }

        let spans = closedLoopSpans(requests: requests,
                                    trace: trace,
                                    descriptors: plan.phases,
                                    duration: duration)
        let series = buildSeries(requests: requests, trace: trace, duration: duration)

        return Scenario(
            kind: .defrag,
            label: label,
            geometry: geometry,
            seekModel: seekModel,
            requestCount: requests.count,
            spans: spans,
            trace: trace.summarized(),
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: DefragPlayback(partition: partition,
                                   plan: plan.summarized(),
                                   mutations: mutations,
                                   activity: activity,
                                   movedBytes: movedBytes,
                                   workEndTime: workEnd),
            boot: nil
        )
    }

    // MARK: - Outils communs

    private static func bucketCount(_ duration: Double) -> Int {
        max(Int(ceil(duration / bucketDuration)), 1)
    }

    /// Les phases d'un scénario en boucle fermée ne se datent qu'après coup :
    /// chacune commence quand sa première opération est prise en charge et
    /// s'arrête quand la suivante démarre.
    private static func closedLoopSpans(requests: [BlockRequest],
                                        trace: DiskTrace,
                                        descriptors: [PhaseDescriptor],
                                        duration: Double) -> [PhaseSpan] {
        var firstTime: [Int: Double] = [:]
        for (index, request) in requests.enumerated() where index < trace.timings.count {
            let time = trace.timings[index].start
            if let existing = firstTime[request.phaseIndex] {
                firstTime[request.phaseIndex] = min(existing, time)
            } else {
                firstTime[request.phaseIndex] = time
            }
        }

        // Une phase peut n'avoir aucune opération — le POST d'un démarrage, où
        // le plateau monte en régime sans que rien ne soit lu. Elle garde sa
        // place et sa durée : elle s'arrête quand la suivante commence.
        var starts = [Double](repeating: duration, count: descriptors.count)
        var next = duration
        for index in stride(from: descriptors.count - 1, through: 0, by: -1) {
            if let time = firstTime[index] { next = min(next, time) }
            starts[index] = next
        }

        var spans: [PhaseSpan] = []
        var cursor = 0.0
        for index in descriptors.indices {
            // La première phase commence à zéro : ce qui précède la première
            // opération lui appartient, c'est le temps de mise en rotation.
            let start = index == 0 ? 0 : max(starts[index], cursor)
            let end = index + 1 < descriptors.count
                ? max(starts[index + 1], start)
                : duration
            spans.append(PhaseSpan(descriptor: descriptors[index], index: index,
                                   start: start, end: end))
            cursor = end
        }
        return spans
    }

    /// Séries d'affichage bâties sur les **temps simulés** et non sur les dates
    /// d'émission : en boucle fermée, toutes les requêtes sont émises à zéro et
    /// c'est le disque qui décide du rythme.
    private static func buildSeries(requests: [BlockRequest],
                                    trace: DiskTrace,
                                    duration: Double) -> (iops: [Double], throughput: [Double], peak: Double) {
        let count = bucketCount(duration)
        var counts = [Double](repeating: 0, count: count)
        var bytes = [Double](repeating: 0, count: count)

        for (index, request) in requests.enumerated() {
            let time = index < trace.timings.count ? trace.timings[index].start : request.issueTime
            let bucket = min(max(Int(time / bucketDuration), 0), count - 1)
            counts[bucket] += 1
            bytes[bucket] += Double(request.sectorCount * DriveGeometry.bytesPerSector)
        }

        let iops = counts.map { $0 / bucketDuration }
        return (iops,
                bytes.map { $0 / bucketDuration / 1_000_000 },
                max(iops.max() ?? 1, 1))
    }
}
