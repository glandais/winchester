import Foundation
import DiskCore

enum ScenarioKind: String, CaseIterable, Identifiable {
    case windowsBoot
    case defrag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsBoot: return String(localized: "pass.title.boot", defaultValue: "Boot")
        case .defrag:      return String(localized: "scenario.defrag.title", defaultValue: "Defragmentation")
        }
    }

    var summary: String {
        switch self {
        case .windowsBoot:
            return String(localized: "scenario.boot.summary", defaultValue: "Booting Windows 98 SE then Office 97, on “Office work, 1999” from the catalogue: a 4.2 GB FAT32 aged by two years of office work")
        case .defrag:
            return String(localized: "scenario.defrag.summary", defaultValue: "Frontier compaction on “Developer, 1993” from the catalogue: a 210 MB FAT16 aged by two years of builds")
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
        case .boot:    return String(localized: "action.boot", defaultValue: "Boot this OS")
        case .defrag:  return String(localized: "action.defrag", defaultValue: "Defragment this disk")
        case .install: return String(localized: "action.install", defaultValue: "Install this disk")
        case .life:    return String(localized: "action.life", defaultValue: "Relive this disk")
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
    /// Ce que le cache du système a fait, pour le bilan (`BootPlan`).
    var softwareCache: String? = nil
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
    /// Le volume tel que le démarrage le trouve, pour la carte. Un démarrage ne
    /// déplace rien : la carte ne change pas, seules les lectures s'y allument.
    /// `nil` quand le volume ne se convertit pas en carte.
    var partition: PartitionGeometry? = nil
    var initialRuns: [MapRun]? = nil

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
        String(localized: "error.notAPass", defaultValue: "reliving a disk is not played like a pass: go through its own screen")
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
        if let boot, let partition = boot.partition, let runs = boot.initialRuns {
            return (partition, runs)
        }
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
                            armReady: setup.armReady,
                            rampLoad: setup.idle.rampLoad,
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
        try DiskGenerator.generate(ScenarioLibrary.load(kind.profileID).localized())
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
        let spinUpDuration = BootScript.Era.matching(disk.spec).spinUpDuration

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
                                           spinUpDuration: spinUpDuration,
                                           idle: .desktop(hardware,
                                                          coldStart: true),
                                           drive: hardware.interface)
        let freshSeconds = (freshTrace.timings.last?.end ?? 0) + fresh.tail

        let launch = plan.appName.map {
            String(localized: "scenario.boot.launch", defaultValue: " then launching \($0)")
        } ?? ""
        let volumeLine = String(localized: "scenario.volume.generated",
                                defaultValue: "“\(disk.spec.displayName)”, generated by the gallery: \(disk.spec.fileSystem.type.rawValue.uppercased()) of \(disk.spec.disk.sizeMB) MB in \(disk.clusterBytes / 1_024) KB clusters, ",
                                comment: "Début de la fiche d'un volume généré")
        let age = freshlyInstalled
            ? String(localized: "scenario.volume.freshlyInstalled", defaultValue: "just as the installation laid it down. ")
            : String(localized: "scenario.volume.aged",
                     defaultValue: "aged over \(disk.dayCount) days. ")
        let note = volumeLine + age
            + String(localized: "scenario.boot.note",
                     defaultValue: "The boot is not described in fractions of the platter but in files: \(plan.filesRead) files of the catalogue are opened and read where the allocator left them. The system counts \(format(seconds: plan.thinkSeconds)) of computing between two reads; everything the pass lasts beyond that comes from the disk. The same contents, never fragmented, would boot in \(format(seconds: freshSeconds)).")

        let requests = plan.requests
        // La carte est celle du volume, comme pour une journée : les fichiers
        // où l'allocateur les a laissés. Un volume que le pont refuse garde
        // le plateau seul.
        let initialRuns = (try? GeneratedVolumeBridge.volume(from: disk))?.categoryRuns()
        let partition = plan.partition
        return Scenario(
            kind: .windowsBoot,
            label: ScenarioLabel(title: rangedBy != nil
                                     ? String(localized: "scenario.title.tidied",
                                              defaultValue: "\(disk.spec.displayName), tidied")
                                     : freshlyInstalled
                                     ? String(localized: "scenario.title.installed",
                                              defaultValue: "\(disk.spec.displayName), installed")
                                     : disk.spec.displayName,
                                 summary: String(localized: "scenario.boot.summary.head",
                                                 defaultValue: "Booting \(plan.osName)\(launch), ")
                                     + (rangedBy.map {
                                         String(localized: "scenario.boot.summary.after",
                                                defaultValue: "after \($0) went through, ")
                                     } ?? "")
                                     + (freshlyInstalled
                                        ? String(localized: "scenario.boot.summary.fresh", defaultValue: "right after the installation, ") : "")
                                     + String(localized: "scenario.summary.on",
                                              defaultValue: "on \(hardware.geometry.model)"),
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             spinUpAt: 0.35,
                             spinUpDuration: spinUpDuration,
                             // Une vraie mise sous tension, et pas d'arrêt
                             // moteur : la machine vient de démarrer. Le bras
                             // reste où la dernière lecture l'a laissé.
                             idle: .desktop(hardware, coldStart: true),
                             drive: hardware.interface,
                             tail: plan.tail,
                             year: hardware.year),
            phases: plan.phases,
            defrag: nil,
            boot: BootPlayback(osName: plan.osName,
                               appName: plan.appName,
                               filesRead: plan.filesRead,
                               residentFiles: plan.residentFiles,
                               stampedFiles: plan.stampedFiles,
                               stampWrites: plan.stampWrites,
                               softwareCache: plan.softwareCache,
                               thinkSeconds: plan.thinkSeconds,
                               tail: plan.tail,
                               freshSeconds: freshSeconds,
                               bytesRead: plan.bytesRead,
                               fileSystem: disk.spec.fileSystem.type,
                               readsByPosition: BootScript.Era.matching(disk.spec).prefetch == .byPosition,
                               freshSeeks: freshTrace.stats.seekCount,
                               freshAverageSeek: freshTrace.stats.averageSeekDistance,
                               partition: plan.partition,
                               initialRuns: initialRuns),
            install: nil,
            dayPlayback: nil,
            feed: { pipeline, isCancelled in
                for request in requests {
                    guard !isCancelled() else { break }
                    // Le cluster que la lecture touche, pour l'allumer sur la
                    // carte ; rien pour les tables, qui n'y figurent pas.
                    let offset = request.lba - partition.dataStartLBA
                    let cluster = offset / partition.clusterSectors
                    pipeline.serve(request, cluster: offset >= 0 && cluster < partition.clusterCount
                                   ? cluster : nil)
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

        let apps = applications.isEmpty ? "" : String(
            localized: "scenario.install.apps",
            defaultValue: ", then \(applications.map(\.displayName).joined(separator: ", "))")
        let note = String(localized: "scenario.volume.generated",
                          defaultValue: "“\(disk.spec.displayName)”, generated by the gallery: \(disk.spec.fileSystem.type.rawValue.uppercased()) of \(disk.spec.disk.sizeMB) MB in \(disk.clusterBytes / 1_024) KB clusters, ")
            + String(localized: "scenario.install.note",
                     defaultValue: "The installation replays the first day of its history: \(summary.totalFiles) files laid where the allocator put them, \(summary.temporaryFiles) archives extracted then deleted, \(reboots) restarts. The disk it arrives at is the one the gallery ages.")

        let bytesPerSecond = hardware.geometry.outerSustainedMBs * 1_000_000
        return Scenario(
            kind: .defrag,
            label: ScenarioLabel(title: disk.spec.displayName,
                                 summary: String(localized: "scenario.install.summary",
                                                 defaultValue: "Installing \(playback.osName)\(apps), ")
                                     + String(localized: "scenario.summary.on",
                                              defaultValue: "on \(hardware.geometry.model)"),
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            // On a démarré sur la disquette ou le CD : le disque tourne déjà.
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             spinUpAt: 0, spinUpDuration: 0.9,
                             idle: .desktop(hardware),
                             drive: hardware.interface,
                             tail: tailDuration,
                             year: hardware.year),
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

        let note = String(localized: "scenario.day.note",
                          defaultValue: "“\(disk.spec.displayName)”, day \(day) of \(disk.spec.timeline.dayCount): the volume is \(Int(disk.metrics.fill * 100)) %% full, \(disk.metrics.fragmentedFileCount) files in pieces. The day is replayed just as the profile's history describes it — what it writes comes from the history, what it reads from what the activity implies.")

        let bytesPerSecond = hardware.geometry.outerSustainedMBs * 1_000_000
        let phases = DayPlanner.phases(of: sessions)
        return Scenario(
            kind: .defrag,
            label: ScenarioLabel(title: "\(disk.spec.displayName), \(date)",
                                 summary: (activities.isEmpty
                                     ? String(localized: "pass.title.idleDay", defaultValue: "A day with no activity")
                                     : activities.map(\.label).joined(separator: ", "))
                                     + ", " + String(localized: "scenario.summary.on",
                                                     defaultValue: "on \(hardware.geometry.model)"),
                                 volumeNote: note),
            geometry: hardware.geometry,
            seekModel: hardware.seek,
            setup: PassSetup(geometry: hardware.geometry, seekModel: hardware.seek,
                             // Une mise sous tension à froid, la même que
                             // celle du démarrage : la journée commence par
                             // lui, et `DayPlanner` attend déjà le POST.
                             spinUpAt: 0.35,
                             spinUpDuration: BootScript.Era.matching(disk.spec).spinUpDuration,
                             // La machine s'allume le matin et s'éteint le
                             // soir : la journée se referme sur la coupure, le
                             // bras qui se retire et les têtes qui se posent.
                             idle: .desktop(hardware, coldStart: true,
                                            stopAfter: powerOffDelay,
                                            stopDuration: spinDownDuration),
                             drive: hardware.interface,
                             tail: tailDuration,
                             year: hardware.year),
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

    /// Ce qui suit la dernière requête : le disque qui tourne seul, ou, en fin
    /// de journée, la coupure et l'atterrissage des têtes.
    private static let tailDuration = 3.5

    /// Délai entre la dernière écriture d'une journée et la coupure du courant :
    /// le temps que Windows affiche qu'on peut éteindre, ou qu'une carte ATX
    /// coupe d'elle-même. **Un ordre de grandeur**, sans source.
    ///
    /// Aucun disque de bureau de cette période ne parquait au repos — c'est une
    /// pratique des disques à rampe des portables des années 2000 : il laisse
    /// son bras où il est et ne le retire qu'à la coupure. Le dernier mouvement
    /// n'appartient donc qu'aux passes qui finissent vraiment par une coupure,
    /// la journée ; une défragmentation, un démarrage et une installation se
    /// referment sur le disque qui tourne.
    private static let powerOffDelay = 1.0

    /// Durée de la redescente du plateau après la coupure, au sens de
    /// `SpindleTimeline` : l'atterrissage des têtes tombe 1,0 s après la
    /// coupure, dans la queue de la journée.
    ///
    /// **Un choix de rendu, pas une fiche** : le seul manuel du catalogue qui
    /// chiffre l'arrêt, celui du Fireball TM, donne « Drive Ready to Power Down
    /// 10.0 seconds » (table 4-3), trois fois plus. Une redescente de dix
    /// secondes allongerait d'autant la queue de chaque journée.
    private static let spinDownDuration = 3.5

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
        // Sans outil demandé, celui que la machine avait : daté comme l'écran
        // de choix le date, par l'année du scénario — celle du logiciel. Le
        // matériel ne s'en mêle pas : un disque nommé garde sa propre année
        // (`DriveHardware.year`), qui n'est pas l'âge du système (B#25).
        let strategy = prepared(strategy ?? DefragPlanner.strategy(for: volume.partition.format,
                                                                   year: disk.spec.timeline.start.year),
                                for: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: volume.partition.totalSectors)

        let note = String(localized: "scenario.volume.generated",
                          defaultValue: "“\(disk.spec.displayName)”, generated by the gallery: \(disk.spec.fileSystem.type.rawValue.uppercased()) of \(disk.spec.disk.sizeMB) MB in \(disk.clusterBytes / 1_024) KB clusters, ")
            + String(localized: "scenario.volume.aged", defaultValue: "aged over \(disk.dayCount) days. ")
            + String(localized: "scenario.defrag.note",
                     defaultValue: "The files keep exactly the clusters the allocator gave them — that is the volume being defragmented, not an approximation.")

        return assembleDefrag(volume: volume,
                              strategy: strategy,
                              hardware: hardware,
                              label: ScenarioLabel(title: disk.spec.displayName,
                                                   summary: disk.spec.summary
                                                       ?? String(localized: "scenario.defrag.fallbackSummary", defaultValue: "A defragmentation pass on a generated disk"),
                                                   volumeNote: note))
    }

    /// L'outil, muni de ce que le système lui confie : `Layout.ini` pour qui
    /// sait le lire (`BootLayoutConsumer`).
    static func prepared(_ strategy: any DefragStrategy, for disk: GeneratedDisk) -> any DefragStrategy {
        // L'outil de 95 prend l'année du disque : avant 1995 il s'appelle
        // `DEFRAG`, et c'est ce nom que la passe affiche.
        if var dated = strategy as? Windows95Strategy {
            dated.year = disk.spec.timeline.start.year
            return dated
        }
        if var dated = strategy as? WindowsXPStrategy, dated.year == nil {
            let year = disk.spec.timeline.start.year
            dated.year = year
            if year >= 2007 { dated.fragmentCeilingBytes = WindowsXPStrategy.vistaFragmentCeilingBytes }
            return dated
        }
        guard let consumer = strategy as? any BootLayoutConsumer else { return strategy }
        return consumer.informed(by: BootLayout(disk: disk))
    }

    /// Décrit la passe d'un outil sur un volume et un disque donnés.
    ///
    /// Rien n'est planifié ici : la stratégie tournera sur le fil producteur,
    /// sur sa propre copie du volume, et émettra ses opérations à mesure.
    private static func assembleDefrag(volume: DefragVolume,
                                       strategy: any DefragStrategy,
                                       hardware: DriveHardware,
                                       label: ScenarioLabel) -> Scenario {
        let geometry = hardware.geometry
        let seekModel = hardware.seek
        let partition = volume.partition
        precondition(geometry.totalSectors >= partition.totalSectors,
                     "la partition déborde du disque qui la porte")

        // Le plateau tourne déjà : Windows est démarré. La rampe de 0,9 s n'est
        // qu'un fondu pour que la couche de rotation s'installe.
        let setup = PassSetup(geometry: geometry, seekModel: seekModel,
                              spinUpAt: 0, spinUpDuration: 0.9,
                              idle: .desktop(hardware),
                              drive: hardware.interface,
                              tail: tailDuration,
                              year: hardware.year)

        return Scenario(
            kind: .defrag,
            label: label,
            geometry: geometry,
            seekModel: seekModel,
            setup: setup,
            phases: strategy.phases(on: partition.format),
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
