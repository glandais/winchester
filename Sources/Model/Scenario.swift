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
            return "Démarrage de Windows 98 SE puis d'Office 97, sur « Secrétariat, 1999 » "
                + "du catalogue : un FAT32 de 4,2 Go vieilli par deux ans de bureautique"
        case .defrag:
            return "Tassage à la frontière sur « Développeur, 1993 » du catalogue : "
                + "un FAT16 de 210 Mo vieilli par deux ans de compilations"
        }
    }

    /// Le disque du catalogue sur lequel la démo tourne.
    ///
    /// Les deux démos n'ont plus de volume à elles : elles prennent un disque
    /// d'époque de la galerie, celui dont l'histoire raconte le mieux ce
    /// qu'elles font entendre. Le matériel suit le disque — c'est la fiche du
    /// profil qui le décrit, et non plus un modèle choisi à côté — et tout ce
    /// que la galerie sait faire d'un disque vaut désormais pour la démo :
    /// comparer deux outils sur son volume, redémarrer celui qu'une passe a
    /// rangé, retrouver son bilan.
    var profileID: String {
        switch self {
        // Windows 98 SE et Office 97, deux ans de documents et rien d'autre,
        // sur un FAT32 rempli à 88 %. C'est le volume de la galerie où la
        // fragmentation coûte le plus à un démarrage (+4 % sur le témoin), et
        // son système n'a pas encore le préchargeur de XP : les fichiers
        // partent dans l'ordre du registre, et le bras suit.
        case .windowsBoot: return "secretaire-1999"
        // Le plus proche parent du volume écrit à la main qu'il remplace : un
        // FAT16 en clusters de 8 Ko, plein à 74 %, là où l'ancien était un
        // FAT16 de 180 Mo à 78 %. Sa passe tient en cinq minutes, et sa carte
        // est assez petite pour qu'un bloc d'écran vaille peu de clusters.
        case .defrag: return "dev-1993"
        }
    }

    /// L'outil de la démo, quand elle en demande un ; `nil` laisse le format
    /// décider, comme pour un disque de la galerie.
    ///
    /// Le tassage à la frontière plutôt que le défragmenteur de 95 : c'est
    /// celui qu'on **regarde** le mieux, une frontière balayant le volume
    /// depuis son début, tout ce qui est dessous étant rangé. Et il arrive au
    /// même résultat que l'outil d'époque sur ce volume — aucun fichier
    /// déplaçable en morceaux, un seul trou libre — en 5 min 22 au lieu de
    /// 30 min 35.
    var strategy: (any DefragStrategy)? {
        switch self {
        case .windowsBoot: return nil
        case .defrag:      return FrontierCompactionStrategy()
        }
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
    case install
    /// Revivre toute l'histoire du disque : ce n'est pas une passe, mais un
    /// défilement, dont on sort pour écouter une journée.
    case life

    /// Ce que le bouton de la galerie dit qu'il va faire.
    var action: String {
        switch self {
        case .boot:    return "Démarrer cet OS"
        case .defrag:  return "Défragmenter ce disque"
        case .install: return "Installer ce disque"
        case .life:    return "Revivre ce disque"
        }
    }
}

/// Ce que le sélecteur de scénario propose.
///
/// Les deux démos sont toujours là ; un disque de la galerie s'y ajoute quand on
/// demande à le démarrer ou à le défragmenter, et y reste tant qu'on n'en confie
/// pas un autre au simulateur.
enum ScenarioSelection: Hashable, Identifiable {
    case builtin(ScenarioKind)
    /// Identifiant du profil de la galerie, et ce qu'on lui demande.
    case generated(String, GeneratedActivity)

    var isGenerated: Bool {
        if case .generated = self { return true }
        return false
    }

    /// Clé d'ordre stable : les deux démos d'abord, dans l'ordre de leur
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
/// Un disque venu de la galerie les tire de son profil ; une démo garde cette
/// note de volume et remplace les deux premiers par les siens. C'est la seule
/// chose qui les distingue une fois la passe planifiée.
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
    /// Fichiers dont la date de dernier accès a été réécrite, et en combien
    /// d'écritures une fois groupées.
    let stampedFiles: Int
    let stampWrites: Int
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

/// Ce qu'on sait d'une installation avant de l'écouter : tout ce qu'elle va
/// poser, et le disque qu'elle laissera.
struct InstallPlayback {
    let partition: PartitionGeometry
    let osName: String
    let applications: [String]
    /// La source du système : « CD-ROM 24x », « 6 disquettes ».
    let medium: String
    let files: Int
    let bytes: Int
    let temporaryFiles: Int
    let temporaryBytes: Int
    let reboots: Int
    /// La carte d'un volume vierge.
    let initialRuns: [MapRun]
    /// Le disque au soir de l'installation, prêt à démarrer.
    let installed: GeneratedDisk
}

/// Ce qu'une activité ne peut pas donner.
enum ActivityError: Error, CustomStringConvertible {
    /// Revivre un disque n'est pas une passe : cela se conduit depuis son
    /// propre écran.
    case notAPass

    var description: String {
        "revivre un disque ne se joue pas comme une passe : passer par son écran"
    }
}

/// Ce qu'on sait d'une journée avant de l'écouter.
struct DayPlayback {
    let day: UInt32
    /// La date, telle que la fiche du profil la compte.
    let date: String
    let partition: PartitionGeometry
    let activities: [DayActivity]
    /// Ce que la journée va écrire, annoncé par l'histoire.
    let bytes: Int
    let initialRuns: [MapRun]
    /// Le disque au matin.
    let disk: GeneratedDisk
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
    /// Ce que l'écran en dit. Une démo reprend le scénario d'un disque du
    /// catalogue et n'en change que ce titre et cette phrase.
    var label: ScenarioLabel
    let geometry: DriveGeometry
    let seekModel: SeekModel
    let setup: PassSetup
    let phases: [PhaseDescriptor]

    let defrag: DefragPlayback?
    let boot: BootPlayback?
    let install: InstallPlayback?
    let dayPlayback: DayPlayback?

    /// La carte que montre la passe, si elle en a une : le volume à ranger,
    /// ou le volume vierge qu'on installe.
    var map: (partition: PartitionGeometry, initialRuns: [MapRun])? {
        if let defrag { return (defrag.partition, defrag.initialRuns) }
        if let install { return (install.partition, install.initialRuns) }
        if let dayPlayback { return (dayPlayback.partition, dayPlayback.initialRuns) }
        return nil
    }

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
                            map: map.map { ($0.partition.clusterCount, $0.initialRuns) })
        session.start()
        return live
    }

    /// Les phases datées, une fois la passe finie. Aucune durée n'est imposée :
    /// chacune commence à sa première requête.
    func spans(of end: PassEnd) -> [PhaseSpan] {
        PhaseSpan.closedLoop(firstStarts: end.firstStarts,
                             descriptors: phases,
                             duration: end.duration)
    }
}

enum ScenarioBuilder {

    static let bucketDuration = ActivityBucket.duration

    // MARK: - Les deux démos

    /// Le disque du catalogue sur lequel tourne une démo.
    ///
    /// C'est le générateur de la galerie, sur le profil que la démo a choisi :
    /// un disque d'époque de deux ans se fabrique en quelques dizaines de
    /// millisecondes, et les deux démos ont été prises parmi les plus légers.
    static func disk(of kind: ScenarioKind) throws -> GeneratedDisk {
        try DiskGenerator.generate(ScenarioLibrary.load(kind.profileID))
    }

    /// Une démo : la passe d'un disque du catalogue, sous le nom de la démo.
    ///
    /// Rien n'est calculé ici qui ne le soit pour un disque de la galerie — ce
    /// sont les deux mêmes constructeurs. La démo n'ajoute que son titre et sa
    /// phrase ; les notes de modélisation restent celles que le volume généré
    /// sait dire de lui-même, et elles sont plus précises que ce qu'un texte
    /// écrit d'avance pouvait annoncer.
    static func build(_ kind: ScenarioKind, disk: GeneratedDisk) throws -> Scenario {
        var scenario: Scenario
        switch kind {
        case .windowsBoot: scenario = build(boot: disk)
        case .defrag:      scenario = try build(generated: disk, using: kind.strategy)
        }
        scenario.label = ScenarioLabel(title: kind.title, summary: kind.summary,
                                       volumeNote: scenario.label.volumeNote)
        return scenario
    }

    // MARK: - Démarrage d'un disque de la galerie

    /// Démarrer un disque qu'on vient de fabriquer.
    ///
    /// Le scénario de démarrage écrit à la main, que la démo a remplacé, nommait
    /// des **fractions du plateau** ; celui-ci nomme des **fichiers**, et les
    /// prend là où l'allocateur les a laissés. C'est ce qui lui permet d'exister
    /// sur les vingt disques de la galerie au lieu d'un seul, et c'est aussi ce
    /// qui rend sa durée intéressante : elle n'est pas décrétée. Le système calcule entre deux lectures — c'est le
    /// plancher — et le disque ajoute ce qu'il ajoute.
    ///
    /// Rien n'est refusé ici : lire des fichiers ne suppose aucune stratégie de
    /// rangement, donc NTFS démarre comme les autres.
    /// `rangedBy` nomme l'outil qui a rangé ce disque, quand on démarre le
    /// volume qu'une passe a laissé : c'est le même disque, et le titre le dit.
    /// `freshlyInstalled` dit qu'on démarre le disque qu'une installation vient
    /// de poser, avant tout usage.
    static func build(boot disk: GeneratedDisk, rangedBy: String? = nil,
                      freshlyInstalled: Bool = false) -> Scenario {
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
            + "en clusters de \(disk.clusterBytes / 1_024) Ko, "
            + (freshlyInstalled ? "tel que l'installation vient de le poser. "
                                : "vieilli sur \(disk.dayCount) jours. ")
            + "Le démarrage n'est pas décrit en fractions du plateau mais en fichiers : "
            + "\(plan.filesRead) fichiers du catalogue sont ouverts et lus là où l'allocateur "
            + "les a laissés. Le système compte \(format(seconds: plan.thinkSeconds)) de calcul "
            + "entre deux lectures ; tout ce que la passe dure en plus vient du disque. "
            + "Le même contenu jamais fragmenté démarrerait en "
            + "\(format(seconds: freshSeconds))."

        let requests = plan.requests
        return Scenario(
            kind: .windowsBoot,
            label: ScenarioLabel(title: rangedBy != nil ? "\(disk.spec.displayName), rangé"
                                     : freshlyInstalled ? "\(disk.spec.displayName), installé"
                                     : disk.spec.displayName,
                                 summary: "Démarrage de \(plan.osName)\(launch), "
                                     + (rangedBy.map { "après le passage de \($0), " } ?? "")
                                     + (freshlyInstalled ? "juste après l'installation, " : "")
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
            defrag: nil,
            boot: BootPlayback(osName: plan.osName,
                               appName: plan.appName,
                               filesRead: plan.filesRead,
                               residentFiles: plan.residentFiles,
                               stampedFiles: plan.stampedFiles,
                               stampWrites: plan.stampWrites,
                               thinkSeconds: plan.thinkSeconds,
                               tail: plan.tail,
                               freshSeconds: freshSeconds,
                               bytesRead: plan.bytesRead,
                               fileSystem: disk.spec.fileSystem.type,
                               readsByPosition: BootScript.Era.matching(disk.spec).prefetch == .byPosition,
                               freshSeeks: freshTrace.stats.seekCount,
                               freshAverageSeek: freshTrace.stats.averageSeekDistance),
            install: nil,
            dayPlayback: nil,
            feed: { pipeline, isCancelled in
                for request in requests {
                    guard !isCancelled() else { break }
                    pipeline.serve(request)
                }
                return nil
            }
        )
    }

    // MARK: - Installation d'un disque de la galerie

    /// Rejoue l'installation d'un disque : le jour 0 de son histoire, sur un
    /// volume vierge et le matériel de sa fiche.
    ///
    /// Tout est décidé avant : quels fichiers, où, dans quel ordre — c'est le
    /// générateur qui l'a écrit. Ce qui reste à planifier, et que le fil
    /// producteur fait pendant l'écoute, c'est ce que la machine en fait :
    /// lire la source, extraire, écrire les tables, redémarrer.
    static func build(install installed: InstalledDisk) -> Scenario {
        let disk = installed.disk
        let partition = GeneratedVolumeBridge.partition(of: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec, atLeast: partition.totalSectors)
        let phases = InstallPhases(installed)
        let summary = InstallSummary(installed)

        let systems = installed.steps.filter { $0.kind == .system }
        let applications = installed.steps.filter { $0.kind == .application }
        let osName = systems.map(\.displayName).joined(separator: " puis ")
        let medium = systems.last.map { $0.style.label(bytes: ByteCount(summary.totalBytes)) } ?? "—"
        let reboots = installed.steps.reduce(0) { $0 + $1.style.reboots }

        let playback = InstallPlayback(partition: partition,
                                       osName: osName.isEmpty ? disk.spec.os : osName,
                                       applications: applications.map(\.displayName),
                                       medium: medium,
                                       files: summary.totalFiles,
                                       bytes: summary.totalBytes,
                                       temporaryFiles: summary.temporaryFiles,
                                       temporaryBytes: summary.temporaryBytes,
                                       reboots: reboots,
                                       initialRuns: InstallPlanner.initialRuns(of: installed),
                                       installed: disk)

        let apps = applications.isEmpty ? ""
            : ", puis \(applications.map(\.displayName).joined(separator: ", "))"
        let note = "« \(disk.spec.displayName) », généré par la galerie : "
            + "\(disk.spec.fileSystem.type.rawValue.uppercased()) de \(disk.spec.disk.sizeMB) Mo "
            + "en clusters de \(disk.clusterBytes / 1_024) Ko. L'installation rejoue le premier jour "
            + "de son histoire : \(summary.totalFiles) fichiers posés là où l'allocateur les a mis, "
            + "\(summary.temporaryFiles) archives extraites puis effacées, \(reboots) redémarrages. "
            + "Le disque d'arrivée est celui que la galerie vieillit."

        let bytesPerSecond = hardware.geometry.outerSustainedMBs * 1_000_000
        return Scenario(
            kind: .defrag,
            label: ScenarioLabel(title: disk.spec.displayName,
                                 summary: "Installation de \(playback.osName)\(apps), "
                                     + "sur \(hardware.geometry.model)",
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            // On a démarré sur la disquette ou le CD : le disque tourne déjà.
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             spinUpAt: 0, spinUpDuration: 0.9,
                             idle: IdleBehavior(parkAfter: parkDelay),
                             tail: tailDuration),
            phases: phases.descriptors,
            defrag: nil,
            boot: nil,
            install: playback,
            dayPlayback: nil,
            feed: { pipeline, isCancelled in
                let sink = OperationSink { operation, mutations, progress, moves in
                    guard !isCancelled() else { return }
                    pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
                }
                InstallPlanner.plan(installed: installed, diskBytesPerSecond: bytesPerSecond,
                                    into: sink, isCancelled: isCancelled)
                return nil
            }
        )
    }

    // MARK: - Une journée de la vie d'un disque

    /// Une journée d'usage : démarrage, séances, arrêt.
    ///
    /// `replay` doit être arrêté au matin de ce jour-là — les jours précédents
    /// rejoués ou sautés. La journée est **jouée pendant l'écoute** : le disque
    /// avance à mesure que la passe se planifie.
    static func build(day: UInt32, replay: HistoryReplay) throws -> Scenario {
        let disk = replay.snapshot()
        let partition = GeneratedVolumeBridge.partition(of: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec, atLeast: partition.totalSectors)
        let volume = try GeneratedVolumeBridge.volume(from: disk)
        // Les séances datent les phases ; les activités, chacune une fois,
        // résument la journée.
        let sessions = DayPlanner.sessions(of: day, in: replay)
        let activities = DayPlanner.activities(of: day, in: replay)
        let date = disk.spec.timeline.start.adding(days: Int(day)).description

        let playback = DayPlayback(day: day, date: date, partition: partition,
                                   activities: activities,
                                   bytes: replay.writtenBytes(of: day),
                                   initialRuns: volume.categoryRuns(),
                                   disk: disk)

        let note = "« \(disk.spec.displayName) », jour \(day) sur \(disk.spec.timeline.dayCount) : "
            + "le volume est à \(Int(disk.metrics.fill * 100)) %, "
            + "\(disk.metrics.fragmentedFileCount) fichiers en morceaux. "
            + "La journée est rejouée telle que l'histoire du profil la décrit — "
            + "ce qu'elle écrit vient d'elle, ce qu'elle lit vient de ce que "
            + "l'activité suppose."

        let bytesPerSecond = hardware.geometry.outerSustainedMBs * 1_000_000
        let phases = DayPlanner.phases(of: sessions)
        return Scenario(
            kind: .defrag,
            label: ScenarioLabel(title: "\(disk.spec.displayName), \(date)",
                                 summary: activities.isEmpty
                                     ? "Journée sans activité, sur \(hardware.geometry.model)"
                                     : activities.map(\.label).joined(separator: ", ")
                                         + ", sur \(hardware.geometry.model)",
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             spinUpAt: 0.35, spinUpDuration: 1.2,
                             idle: IdleBehavior(parkAfter: parkDelay),
                             tail: tailDuration),
            phases: phases,
            defrag: nil,
            boot: nil,
            install: nil,
            dayPlayback: playback,
            feed: { pipeline, isCancelled in
                let sink = OperationSink { operation, mutations, progress, moves in
                    guard !isCancelled() else { return }
                    pipeline.serve(operation, mutations: mutations, progress: progress, moves: moves)
                }
                DayPlanner.plan(day: day, replay: replay, disk: disk,
                                diskBytesPerSecond: bytesPerSecond, into: sink,
                                isCancelled: isCancelled)
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

    // MARK: - Défragmentation d'un disque de la galerie

    /// Même passe, sur un volume venu du générateur de disques d'époque.
    ///
    /// Le disque est converti en volume à défragmenter par
    /// `GeneratedVolumeBridge` — qui refuse les formats que l'outil simulé ne
    /// sait pas ranger — et le matériel est celui que décrit la fiche du
    /// profil, jamais un modèle choisi à côté : un 210 Mo à 3 600 tr/min de 1993
    /// ne sonne pas comme un 1 Go à 5 400 tr/min de 1996, et c'est tout
    /// l'intérêt de l'exercice.
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
            defrag: DefragPlayback(partition: partition,
                                   strategy: strategy,
                                   before: volume.stats,
                                   initialRuns: volume.categoryRuns()),
            boot: nil,
            install: nil,
            dayPlayback: nil,
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
