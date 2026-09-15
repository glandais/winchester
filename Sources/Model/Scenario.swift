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
            return "Démarrage Windows puis lancement d'une suite bureautique, sur un IDE de 2001"
        case .defrag:
            return "Passe complète du défragmenteur de Windows 95 sur un volume FAT16 vieilli"
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

/// Ce que le sélecteur de scénario propose.
///
/// Les deux scénarios livrés sont toujours là ; un disque de la galerie s'y
/// ajoute quand on demande à le défragmenter, et y reste tant qu'on n'en
/// défragmente pas un autre.
enum ScenarioSelection: Hashable, Identifiable {
    case builtin(ScenarioKind)
    /// Identifiant du profil de la galerie.
    case generated(String)

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
        case let .generated(id):
            return "1\(id)"
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

/// Un scénario entièrement calculé : requêtes, chronologie mécanique, repères
/// audio et séries d'affichage.
struct Scenario {
    let kind: ScenarioKind
    let label: ScenarioLabel
    let geometry: DriveGeometry
    let seekModel: SeekModel
    let requests: [BlockRequest]
    let spans: [PhaseSpan]
    let trace: DiskTrace
    let cues: [AudioCue]
    let duration: Double

    let iops: [Double]
    let throughputMBs: [Double]
    let peakIOPS: Double

    let defrag: DefragPlayback?

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
            requests: requests,
            spans: spans,
            trace: trace,
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: trace.duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: nil
        )
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

        return assembleDefrag(volume: volume,
                              geometry: DriveCatalog.defragDrive.geometry,
                              seekModel: DriveCatalog.defragDrive.seekModel,
                              label: ScenarioKind.defrag.label)
    }

    // MARK: - Défragmentation d'un disque de la galerie

    /// Même passe, sur un volume venu du générateur de disques d'époque.
    ///
    /// Le disque est converti en `Volume` par `GeneratedVolumeBridge` — qui
    /// refuse tout ce qu'un défragmenteur de 1995 n'aurait pas su ouvrir — et le
    /// matériel est celui que décrit la fiche du profil, pas le disque de 1996
    /// du scénario livré : un 210 Mo à 3 600 tr/min de 1993 ne sonne pas comme
    /// un 1 Go à 4 500 tr/min de 1996, et c'est tout l'intérêt de l'exercice.
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
    /// `DefragPlanner.plan` **consomme** le volume : il y rejoue chaque
    /// déplacement pour connaître l'état d'arrivée. Le volume passé ici ne doit
    /// donc pas être réutilisé ensuite.
    private static func assembleDefrag(volume: Volume,
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

            for mutation in operation.mutations {
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
            requests: requests,
            spans: spans,
            trace: trace,
            cues: AudioCueBuilder.build(from: trace, cylinders: geometry.cylinders),
            duration: duration,
            iops: series.iops,
            throughputMBs: series.throughput,
            peakIOPS: series.peak,
            defrag: DefragPlayback(partition: partition,
                                   plan: plan,
                                   mutations: mutations,
                                   activity: activity,
                                   movedBytes: movedBytes,
                                   workEndTime: workEnd)
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

        var indices = Array(0..<descriptors.count).filter { firstTime[$0] != nil || $0 == descriptors.count - 1 }
        indices.sort()

        var spans: [PhaseSpan] = []
        for (position, index) in indices.enumerated() {
            let start = firstTime[index] ?? (trace.timings.last?.end ?? 0)
            let end: Double
            if position + 1 < indices.count {
                end = firstTime[indices[position + 1]] ?? duration
            } else {
                end = duration
            }
            spans.append(PhaseSpan(descriptor: descriptors[index], index: index,
                                   start: max(start, spans.last?.end ?? 0), end: end))
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
