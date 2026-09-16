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

/// Ce qu'on sait d'une défragmentation avant de l'avoir écoutée : le volume
/// tel qu'il est, et l'outil qui va le ranger. Le reste — ce que la passe a
/// déplacé, l'état d'arrivée — n'est connu qu'à la fin, dans `PassEnd`.
struct DefragPlayback {
    let partition: PartitionGeometry
    let strategy: any DefragStrategy
    let before: VolumeStats
    let initialRuns: [MapRun]
}

/// Ce qu'un démarrage lira, connu d'avance : un démarrage décrit en fichiers
/// sait ce qu'il ouvre, pas combien de temps le disque le fera attendre.
struct BootPlayback {
    let osName: String
    let appName: String?
    let filesRead: Int
    let residentFiles: Int
    /// Ce que le système aurait mis sans disque : la somme des calculs.
    let thinkSeconds: Double
    /// Le silence qui suit la dernière lecture.
    let tail: Double
    /// Ce qu'aurait duré le même démarrage si le volume n'avait jamais vieilli :
    /// mêmes fichiers, mêmes tailles, même ordre, chacun d'un seul tenant. La
    /// différence avec la durée réelle est le prix de la fragmentation, et il
    /// n'y a aucun autre écart entre les deux mesures.
    let freshSeconds: Double
    /// Ce que le démarrage lira, en octets.
    let bytesRead: Int
    /// Le format du volume : c'est lui qui dit si le témoin a une chance de
    /// perdre — NTFS place mieux qu'un empilement, FAT non.
    let fileSystem: FileSystemKind
    /// Le système relit sa liste dans l'ordre du disque — le préchargeur de
    /// Windows XP, puis SuperFetch — plutôt que dans l'ordre du registre.
    let readsByPosition: Bool
    /// Seeks du témoin, pour les mettre en regard de ceux qu'on écoute.
    let freshSeeks: Int
    let freshAverageSeek: Int

    /// Ce que le disque a ajouté par-dessus le calcul, une fois la passe finie.
    func diskSeconds(duration: Double) -> Double {
        max(duration - tail - thinkSeconds, 0)
    }
}

/// Un scénario : ce qu'il faut pour **produire** une passe, pas la passe.
///
/// Tout était calculé avant que le premier son ne sorte — requêtes, chronologie
/// mécanique, repères audio, séries d'affichage. Sur les gros volumes de la
/// galerie cela plafonnait à 780 Mo, pour une passe dont on n'écoute jamais que
/// l'instant présent. Le scénario ne garde plus que le disque, sa chronologie
/// et la source des requêtes ; la passe se calcule à mesure qu'on l'écoute.
struct Scenario {
    let kind: ScenarioKind
    let label: ScenarioLabel
    let geometry: DriveGeometry
    let seekModel: SeekModel
    let setup: PassSetup
    let phases: [PhaseDescriptor]
    /// Les phases à durée imposée du démarrage livré. `nil` en boucle fermée,
    /// où chacune commence à sa première requête.
    let fixedSpans: [PhaseSpan]?

    let defrag: DefragPlayback?
    let boot: BootPlayback?

    /// Nourrit la chaîne, requête après requête, et rend le plan s'il y en a
    /// un. Le second argument dit si l'écoute a abandonné la passe.
    fileprivate let feed: @Sendable (PassPipeline, @escaping () -> Bool) -> DefragPlan?

    /// Toute la passe, sur le fil courant. `nil` si elle a été abandonnée.
    @discardableResult
    func produce(batchRequests: Int = 256,
                 batchSeconds: Double = 0.05,
                 isCancelled: @escaping () -> Bool = { false },
                 deliver: @escaping PassPipeline.Delivery) -> PassEnd? {
        let pipeline = PassPipeline(setup: setup, batchRequests: batchRequests,
                                    batchSeconds: batchSeconds, deliver: deliver)
        for span in fixedSpans ?? [] { pipeline.mark(phase: span.index, at: span.start) }
        let plan = feed(pipeline, isCancelled)
        guard !isCancelled() else { return nil }
        return pipeline.finish(plan: plan)
    }

    /// La passe telle qu'on l'écoute : produite sur son propre fil, quelques
    /// secondes en avance.
    func startLivePass() -> LivePass {
        let scenario = self
        let session = PassSession { outlet in
            scenario.produce(isCancelled: { outlet.isCancelled },
                             deliver: outlet.deliver)
        }
        let live = LivePass(session: session,
                            geometry: geometry,
                            seekModel: seekModel,
                            spindle: setup.spindle,
                            phases: phases,
                            map: defrag.map { ($0.partition.clusterCount, $0.initialRuns) })
        session.start()
        return live
    }

    /// Les phases datées, une fois la passe finie.
    func spans(of end: PassEnd) -> [PhaseSpan] {
        fixedSpans ?? PhaseSpan.closedLoop(firstStarts: end.firstStarts,
                                           descriptors: phases,
                                           duration: end.duration)
    }
}

enum ScenarioBuilder {

    static let bucketDuration = ActivityBucket.duration

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

        // Une minute et quelques milliers de requêtes : les générer d'avance ne
        // coûte rien, et c'est la chronologie des phases qui les date.
        let generator = WorkloadGenerator(geometry: geometry)
        let (requests, spans) = generator.generate(phases: phases)
        let total = spans.last?.end ?? 0

        // La chronologie du moteur vient des phases, plus d'ici : la première
        // le lance, la dernière le coupe. Le bras va se parquer avant la
        // coupure, ce que le scénario n'avait pas à dire.
        let spin = SpinSchedule(phases: phases, spans: spans)

        let setup = PassSetup(geometry: geometry, seekModel: seekModel,
                              spinUpAt: spin.spinUpAt,
                              spinUpDuration: spin.spinUpDuration,
                              idle: IdleBehavior(parkAfter: parkDelay,
                                                 stopAt: spin.idle.stopAt,
                                                 stopDuration: spin.idle.stopDuration),
                              tail: nil,
                              minimumDuration: total,
                              datesPhases: false)

        return Scenario(
            kind: .windowsBoot,
            label: ScenarioKind.windowsBoot.label,
            geometry: geometry,
            seekModel: seekModel,
            setup: setup,
            phases: phases.map(\.descriptor),
            fixedSpans: spans,
            defrag: nil,
            boot: nil,
            feed: { pipeline, isCancelled in
                for request in requests {
                    guard !isCancelled() else { break }
                    pipeline.serve(request)
                }
                return nil
            }
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
    /// `rangedBy` nomme l'outil qui a rangé ce disque, quand on démarre le
    /// volume qu'une passe a laissé : c'est le même disque, et le titre le dit.
    static func build(boot disk: GeneratedDisk, rangedBy: String? = nil) -> Scenario {
        let plan = BootPlanner.plan(disk: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: plan.partition.totalSectors)
        let spinUpDuration = max(plan.post - 0.6, 0.5)

        // Le témoin : le même contenu jamais fragmenté. Une seconde passe de
        // planification et de simulation, sur quelques milliers de requêtes et
        // d'un bloc — le prix d'une phrase qui dit ce que ce volume-ci coûte.
        // Il doit être connu avant l'écoute, puisque c'est à lui qu'on la
        // compare.
        let fresh = BootPlanner.plan(disk: disk.freshlyInstalled())
        let freshTrace = DiskSimulator.run(geometry: hardware.geometry,
                                           seekModel: hardware.seek,
                                           requests: fresh.requests,
                                           totalDuration: 0,
                                           spinUpAt: 0.35,
                                           spinUpDuration: spinUpDuration)
        let freshSeconds = (freshTrace.timings.last?.end ?? 0) + fresh.tail

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

        let requests = plan.requests
        return Scenario(
            kind: .windowsBoot,
            label: ScenarioLabel(title: rangedBy == nil ? disk.spec.displayName
                                     : "\(disk.spec.displayName), rangé",
                                 summary: "Démarrage de \(plan.osName)\(launch), "
                                     + (rangedBy.map { "après le passage de \($0), " } ?? "")
                                     + "sur \(hardware.geometry.model)",
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             spinUpAt: 0.35,
                             spinUpDuration: spinUpDuration,
                             // Pas d'arrêt moteur : la machine vient de démarrer.
                             // Mais le bras n'a plus rien à faire, et la queue
                             // du scénario est faite pour ça.
                             idle: IdleBehavior(parkAfter: parkDelay),
                             tail: plan.tail),
            phases: plan.phases,
            fixedSpans: nil,
            defrag: nil,
            boot: BootPlayback(osName: plan.osName,
                               appName: plan.appName,
                               filesRead: plan.filesRead,
                               residentFiles: plan.residentFiles,
                               thinkSeconds: plan.thinkSeconds,
                               tail: plan.tail,
                               freshSeconds: freshSeconds,
                               bytesRead: plan.bytesRead,
                               fileSystem: disk.spec.fileSystem.type,
                               readsByPosition: BootScript.Era.matching(disk.spec).prefetch == .byPosition,
                               freshSeeks: freshTrace.stats.seekCount,
                               freshAverageSeek: freshTrace.stats.averageSeekDistance),
            feed: { pipeline, isCancelled in
                for request in requests {
                    guard !isCancelled() else { break }
                    pipeline.serve(request)
                }
                return nil
            }
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

    /// Silence final, une fois la passe terminée. Il n'est plus tout à fait
    /// silencieux : le bras s'y parque.
    private static let tailDuration = 3.5

    /// Délai d'inactivité avant que le bras retourne se parquer.
    ///
    /// Une seconde, pas les minutes d'une vraie temporisation de veille : ce
    /// qu'on veut entendre, c'est que la passe se referme sur un dernier
    /// mouvement plutôt que sur un blanc. La queue d'un scénario le porte
    /// largement, seek de course complète compris.
    private static let parkDelay = 1.0

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
    static func build(generated disk: GeneratedDisk,
                      using strategy: (any DefragStrategy)? = nil) throws -> Scenario {
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: volume.partition.totalSectors)

        let note = "« \(disk.spec.displayName) », généré par la galerie : "
            + "\(disk.spec.fileSystem.type.rawValue.uppercased()) de \(disk.spec.disk.sizeMB) Mo "
            + "en clusters de \(disk.clusterBytes / 1_024) Ko, vieilli sur \(disk.dayCount) jours. "
            + "Les fichiers gardent exactement les clusters que l'allocateur leur a donnés — "
            + "c'est ce volume-là qui est défragmenté, pas une approximation."

        return assembleDefrag(volume: volume,
                              strategy: strategy,
                              geometry: hardware.geometry,
                              seekModel: hardware.seek,
                              label: ScenarioLabel(title: disk.spec.displayName,
                                                   summary: disk.spec.summary
                                                       ?? "Passe de défragmentation sur un disque généré",
                                                   volumeNote: note))
    }

    /// Décrit la passe d'un outil sur un volume et un disque donnés.
    ///
    /// Rien n'est planifié ici : la stratégie tournera sur le fil producteur,
    /// sur sa propre copie du volume, et émettra ses opérations à mesure.
    private static func assembleDefrag(volume: DefragVolume,
                                       strategy chosen: (any DefragStrategy)? = nil,
                                       geometry: DriveGeometry,
                                       seekModel: SeekModel,
                                       label: ScenarioLabel) -> Scenario {
        let partition = volume.partition
        precondition(geometry.totalSectors >= partition.totalSectors,
                     "la partition déborde du disque qui la porte")

        let strategy = chosen ?? DefragPlanner.strategy(for: partition.format)

        // Le plateau tourne déjà : Windows est démarré. La rampe de 0,9 s n'est
        // qu'un fondu pour que la couche de rotation s'installe.
        let setup = PassSetup(geometry: geometry, seekModel: seekModel,
                              spinUpAt: 0, spinUpDuration: 0.9,
                              idle: IdleBehavior(parkAfter: parkDelay),
                              tail: tailDuration)

        return Scenario(
            kind: .defrag,
            label: label,
            geometry: geometry,
            seekModel: seekModel,
            setup: setup,
            phases: strategy.phases,
            fixedSpans: nil,
            defrag: DefragPlayback(partition: partition,
                                   strategy: strategy,
                                   before: volume.stats,
                                   initialRuns: volume.categoryRuns()),
            boot: nil,
            feed: { pipeline, isCancelled in
                // Une passe abandonnée ne s'interrompt pas — les stratégies
                // n'ont pas de point d'arrêt — mais elle cesse de simuler : le
                // planificateur finit son calcul à vide.
                let sink = OperationSink { operation, mutations, progress, moves in
                    guard !isCancelled() else { return }
                    pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
                }
                return strategy.plan(volume: volume, into: sink)
            }
        )
    }
}
