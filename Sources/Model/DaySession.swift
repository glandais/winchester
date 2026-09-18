import Foundation
import DiskCore

/// Une journée de la vie d'un disque.
///
/// L'histoire d'un profil ne décrit que des **écritures**, datées au jour près :
/// tant d'objets compilés, tant de pages en cache, un document réenregistré,
/// un jeu installé. Une journée ne sonne pourtant pas comme cela. On allume la
/// machine, on ouvre ce qu'on va travailler, on attend, et le disque lit au
/// moins autant qu'il écrit — un compilateur relit ses sources, l'éditeur de
/// liens relit ses objets, un jeu recharge ses niveaux.
///
/// Ce planificateur remet cela autour des écritures de la journée : un
/// démarrage, une séance par activité, les lectures qu'elle suppose, les tables
/// vidées par le cache, et les attentes — bridées, parce qu'un téléchargement
/// de 1999 durait la nuit.
enum DaySession {}

// MARK: - Ce que fait l'utilisateur

/// Les activités d'une journée, dans l'ordre où la journée les enchaîne.
enum DayActivity: Int, CaseIterable, Hashable {
    case system
    case compile
    case browse
    case office
    case media
    case download
    case game
    case hoard
    case update

    var label: String {
        switch self {
        case .system:   return "Système"
        case .compile:  return "Compilation"
        case .browse:   return "Navigation"
        case .office:   return "Bureautique"
        case .media:    return "Import de médias"
        case .download: return "Téléchargement"
        case .game:     return "Jeu"
        case .hoard:    return "Archivage"
        case .update:   return "Mise à jour"
        }
    }

    var detail: String {
        switch self {
        case .system:   return "Fichier d'échange, ménage, tables"
        case .compile:  return "Sources relues, objets réécrits, édition de liens"
        case .browse:   return "Cache : des milliers de fichiers minuscules"
        case .office:   return "Documents ouverts, puis réenregistrés à côté"
        case .media:    return "Copie depuis l'appareil, écriture d'un seul tenant"
        case .download: return "Écriture au rythme de la ligne"
        case .game:     return "Niveaux chargés, sauvegardes réécrites"
        case .hoard:    return "Ce qu'on garde, écrit une fois"
        case .update:   return "Fichiers système remplacés un par un"
        }
    }
}

/// Les débits et les attentes d'une machine de l'époque, pour une journée.
struct DayScript: Sendable {

    /// Ce que débite la source d'un média importé : un CD qu'on rippe, une
    /// carte mémoire, un caméscope.
    let mediaBytesPerSecond: Double
    /// La ligne : modem, puis ADSL.
    let networkBytesPerSecond: Double
    /// Ce qu'on relit d'un jeu quand on le lance.
    let gameLoadBytes: Int
    /// Attente maximale laissée dans la passe. Un téléchargement de 1999 prenait
    /// la nuit ; on garde de quoi entendre que le disque attend, pas la nuit.
    let maximumPause: Double
    /// Le temps que l'utilisateur met entre deux gestes.
    let userPause: Double

    static func matching(_ spec: ProfileSpec) -> DayScript {
        switch spec.timeline.start.year {
        case ..<1995:
            return DayScript(mediaBytesPerSecond: 300_000, networkBytesPerSecond: 1_800,
                             gameLoadBytes: 4_000_000, maximumPause: 8, userPause: 1.5)
        case 1995...1997:
            return DayScript(mediaBytesPerSecond: 600_000, networkBytesPerSecond: 3_600,
                             gameLoadBytes: 20_000_000, maximumPause: 8, userPause: 1.2)
        case 1998...2000:
            return DayScript(mediaBytesPerSecond: 1_000_000, networkBytesPerSecond: 7_000,
                             gameLoadBytes: 60_000_000, maximumPause: 8, userPause: 1.0)
        case 2001...2005:
            return DayScript(mediaBytesPerSecond: 2_000_000, networkBytesPerSecond: 128_000,
                             gameLoadBytes: 200_000_000, maximumPause: 8, userPause: 0.8)
        default:
            return DayScript(mediaBytesPerSecond: 10_000_000, networkBytesPerSecond: 1_000_000,
                             gameLoadBytes: 500_000_000, maximumPause: 8, userPause: 0.6)
        }
    }
}

// MARK: - Le plan d'une journée

/// Ce qu'une journée a fait au disque.
struct DayPlan {
    let day: UInt32
    let partition: PartitionGeometry
    let phases: [PhaseDescriptor]
    /// Les activités de la journée, dans l'ordre des phases. Le démarrage
    /// ouvre, l'arrêt ferme.
    var activities: [DayActivity] = []
    var filesWritten = 0
    var filesDeleted = 0
    var filesRead = 0
    var bytesWritten = 0
    var bytesRead = 0
    var metadataFlushes = 0
    var thinkSeconds = 0.0
    /// Ce que la journée a passé à attendre la source ou la ligne.
    var waitSeconds = 0.0
    var bootFiles = 0
}

enum DayPlanner {

    /// Les séances d'une journée, dans l'ordre où elles s'enchaînent.
    ///
    /// Une journée revient sur ses pas : le cache du navigateur expire pendant
    /// qu'on compile, on rejoue après avoir travaillé. Chaque retour est une
    /// **séance** de plus, et non la reprise de la précédente : c'est ce que
    /// montrent les phases, et c'est ainsi que le temps se compte.
    static func sessions(of day: UInt32, in replay: HistoryReplay) -> [DayActivity] {
        var sessions: [DayActivity] = []
        let classifier = Classifier(catalog: replay.catalog, spec: replay.spec)
        for timed in replay.events(of: day) {
            guard let activity = classifier.activity(of: timed.event, in: replay.catalog) else { continue }
            if sessions.last != activity { sessions.append(activity) }
        }
        return sessions
    }

    /// Les activités d'une journée, chacune une fois, dans l'ordre.
    static func activities(of day: UInt32, in replay: HistoryReplay) -> [DayActivity] {
        var seen: [DayActivity] = []
        for activity in sessions(of: day, in: replay) where !seen.contains(activity) {
            seen.append(activity)
        }
        return seen
    }

    /// Les phases d'une journée : le démarrage ouvre, l'arrêt ferme, et une
    /// phase par séance entre les deux.
    static func phases(of sessions: [DayActivity]) -> [PhaseDescriptor] {
        var phases = [PhaseDescriptor(id: "boot", label: "Démarrage", detail: "La machine s'allume")]
        for (index, activity) in sessions.enumerated() {
            phases.append(PhaseDescriptor(id: "act-\(index)-\(activity.rawValue)",
                                          label: activity.label, detail: activity.detail))
        }
        phases.append(PhaseDescriptor(id: "shutdown", label: "Arrêt",
                                      detail: "Tables et cache écrits, la machine s'éteint"))
        return phases
    }

    /// Rejoue une journée dans `sink` : démarrage, séances, arrêt.
    ///
    /// La journée est **jouée au passage** : les événements sont appliqués au
    /// disque par `replay` à mesure qu'ils sont racontés.
    @discardableResult
    static func plan(day: UInt32,
                     replay: HistoryReplay,
                     disk: GeneratedDisk,
                     diskBytesPerSecond: Double,
                     into sink: OperationSink,
                     isCancelled: () -> Bool = { false }) -> DayPlan {
        let partition = GeneratedVolumeBridge.partition(of: disk)
        let era = InstallEra.matching(replay.spec)
        let script = DayScript.matching(replay.spec)
        let planned = sessions(of: day, in: replay)

        let phases = phases(of: planned)

        var plan = DayPlan(day: day, partition: partition, phases: phases)
        plan.activities = planned
        var writer = MachineWriter(partition: partition, era: era, sink: sink,
                                   diskBytesPerSecond: diskBytesPerSecond)
        let classifier = Classifier(catalog: replay.catalog, spec: replay.spec)
        var reader = DayReader(script: script, era: era, seed: replay.spec.seed &+ UInt64(day))

        // MARK: Le démarrage
        let boot = BootPlanner.plan(disk: disk)
        writer.think(boot.post)
        plan.bootFiles = boot.filesRead
        for request in boot.requests {
            guard !isCancelled() else { return plan }
            writer.think(min(request.thinkTime, script.maximumPause))
            let offset = request.lba - partition.dataStartLBA
            let cluster = offset >= 0 ? offset / partition.clusterSectors : nil
            writer.emit(request.isWrite ? .metadata : .scan, lba: request.lba,
                        sectors: request.sectorCount, isWrite: request.isWrite, cluster: cluster)
        }
        plan.bytesRead += boot.bytesRead
        writer.think(script.userPause)

        // MARK: Les séances
        var current: DayActivity?
        var session = -1
        var written = 0
        let total = max(replay.writtenBytes(of: day), 1)

        replay.play(day: day) { timed, step in
            guard !isCancelled() else { return false }
            let record = step.after ?? step.before
            // La même lecture que le pré-découpage en séances, pour que les
            // phases annoncées soient celles qu'on joue.
            guard let activity = classifier.activity(of: timed, step: step, in: replay.catalog)
            else { return true }

            if current != activity {
                // On ferme la séance précédente : le cache vide ce qu'il retient.
                if current != nil {
                    writer.flushMetadata(force: true)
                    writer.think(script.userPause)
                }
                current = activity
                session += 1
                writer.phase = min(1 + session, phases.count - 2)
                reader.open(activity, writer: &writer, catalog: replay.catalog, plan: &plan)
            }

            if let record {
                writer.markDirty(record, directory: replay.catalog.directories[Int(record.directory)])
            }
            if !step.metadataGrew.isEmpty { writer.grow(metadata: step.metadataGrew) }
            if !step.directoryGrew.isEmpty { writer.grow(metadata: step.directoryGrew, as: .directory) }

            switch timed.event {
            case .delete:
                if let record = step.before {
                    writer.free(record.extents)
                    plan.filesDeleted += 1
                }
            default:
                if let record = step.after, !step.written.isEmpty {
                    reader.beforeWriting(record, activity: activity, writer: &writer,
                                         catalog: replay.catalog, plan: &plan)
                    writer.colour(record, extents: step.allocated)
                    let bytes = step.written.clusterCount == record.extents.clusterCount
                        ? Int(record.logicalSize)
                        : Int(step.written.clusterCount) * Int(partition.clusterBytes)
                    writer.write(step.written, bytes: bytes) { chunk in
                        reader.sourceTime(chunk, activity: activity, plan: &plan)
                    }
                    plan.filesWritten += 1
                    plan.bytesWritten += bytes
                    written += bytes
                } else if let record = step.after, step.written.isEmpty, !record.isResident {
                    // Une écriture refusée, ou un fichier qui n'a rien à poser.
                    writer.think(era.think.perFile)
                }
            }
            for move in step.moves {
                writer.free(move.from)
                writer.colour(move.record)
            }
            writer.think(era.think.perFile)
            writer.progress = min(Double(written) / Double(total), 1)
            writer.flushIfEveryFile()
            return true
        }

        // MARK: L'arrêt
        writer.phase = phases.count - 1
        writer.think(script.userPause)
        writer.flushMetadata(force: true)
        writer.settle()

        plan.bytesRead += writer.bytesRead
        plan.metadataFlushes = writer.metadataFlushes
        plan.thinkSeconds = writer.thinkSeconds
        plan.filesRead = reader.filesRead
        plan.waitSeconds = reader.waitSeconds
        return plan
    }
}

// MARK: - Ce qu'une activité lit

/// Les lectures que suppose chaque activité, et ce qu'elle attend de sa source.
///
/// Rien de tout cela n'est dans l'histoire : elle ne décrit que ce qui change
/// sur le disque. Ce sont pourtant ces lectures qui font le bruit d'une journée
/// — un éditeur de liens qui relit trois cents fichiers objets s'entend de
/// loin.
private struct DayReader {

    let script: DayScript
    let era: InstallEra
    private var rng: SeededGenerator
    private(set) var filesRead = 0
    private(set) var waitSeconds = 0.0
    /// Documents déjà ouverts aujourd'hui : on ne les rouvre pas à chaque
    /// enregistrement.
    private var opened: Set<UInt32> = []

    init(script: DayScript, era: InstallEra, seed: UInt64) {
        self.script = script
        self.era = era
        self.rng = SeededGenerator(seed: seed)
    }

    /// Ce que l'activité lit en commençant.
    mutating func open(_ activity: DayActivity, writer: inout MachineWriter,
                       catalog: FileCatalog, plan: inout DayPlan) {
        switch activity {
        case .compile:
            // Le compilateur relit les sources et les en-têtes du projet.
            read(catalog.files.filter { $0.category == .source }, limit: 120,
                 writer: &writer, plan: &plan)
        case .browse:
            // Le navigateur rouvre son index et relit une part de son cache.
            read(catalog.files.filter { $0.category == .cache }, limit: 40,
                 writer: &writer, plan: &plan)
        case .game:
            // Lancer un jeu, c'est charger un niveau.
            var loaded = 0
            for record in catalog.files where record.category == .gameAsset && loaded < script.gameLoadBytes {
                let bytes = min(Int(record.logicalSize), script.gameLoadBytes - loaded)
                writer.read(record.extents, bytes: bytes)
                loaded += bytes
                filesRead += 1
                plan.bytesRead += bytes
            }
        case .update:
            // Le correctif arrive par la ligne avant d'être posé.
            wait(6, writer: &writer)
        default:
            break
        }
        writer.think(script.userPause)
    }

    /// Ce qu'on lit juste avant d'écrire ce fichier-là.
    mutating func beforeWriting(_ record: FileRecord, activity: DayActivity,
                                writer: inout MachineWriter, catalog: FileCatalog,
                                plan: inout DayPlan) {
        switch activity {
        case .office:
            // On ouvre le document avant de l'enregistrer, une fois par jour.
            guard opened.insert(record.id).inserted, !record.extents.isEmpty else { return }
            writer.read(record.extents, bytes: Int(record.logicalSize))
            filesRead += 1
            plan.bytesRead += Int(record.logicalSize)
            writer.think(script.userPause)
        case .compile:
            // L'éditeur de liens relit les objets avant d'écrire l'exécutable.
            guard record.name.hasSuffix(".EXE") else { return }
            read(catalog.files.filter { $0.category == .buildArtifact && $0.name.hasSuffix(".OBJ") },
                 limit: 300, writer: &writer, plan: &plan)
        default:
            break
        }
    }

    /// Ce que coûte, hors disque, le tampon qu'on s'apprête à écrire.
    mutating func sourceTime(_ bytes: Int, activity: DayActivity, plan: inout DayPlan) -> Double {
        let seconds: Double
        switch activity {
        case .media, .hoard:
            seconds = Double(bytes) / script.mediaBytesPerSecond
        case .download, .update:
            seconds = Double(bytes) / script.networkBytesPerSecond
        default:
            // Ce que la machine calcule avant d'avoir quelque chose à écrire.
            return era.think.perMegabyte * Double(bytes) / 1_048_576
        }
        let kept = min(seconds, script.maximumPause)
        waitSeconds += kept
        plan.waitSeconds += kept
        return kept
    }

    private mutating func read(_ candidates: [FileRecord], limit: Int,
                               writer: inout MachineWriter, plan: inout DayPlan) {
        guard !candidates.isEmpty else { return }
        let count = min(limit, candidates.count)
        for index in 0..<count {
            // Un tirage sans ordre : le compilateur suit son makefile, pas le
            // disque.
            let record = candidates[Int(rng.index(below: candidates.count))]
            guard !record.extents.isEmpty else { continue }
            writer.read(record.extents, bytes: Int(record.logicalSize))
            writer.think(era.think.perFile)
            filesRead += 1
            plan.bytesRead += Int(record.logicalSize)
            _ = index
        }
    }

    private mutating func wait(_ seconds: Double, writer: inout MachineWriter) {
        let kept = min(seconds, script.maximumPause)
        waitSeconds += kept
        writer.think(kept)
    }
}

// MARK: - Nommer les écritures

/// À quelle activité appartient un fichier.
///
/// L'histoire ne le dit pas : elle ne porte que des catégories. Le chemin et le
/// nom suffisent pourtant à retrouver le geste — `\Downloads` n'est pas
/// `\Archives`, et `SAVE.DAT` dans le dossier des sauvegardes est du jeu, pas
/// de la bureautique.
///
/// Une classe, et non une valeur : un fichier créé puis effacé dans la même
/// journée a disparu du catalogue quand on classe son effacement. Le
/// classificateur retient donc ce qu'il a vu naître, et les deux lectures d'une
/// même journée — celle qui la découpe en séances, celle qui la joue — tombent
/// sur la même suite.
private final class Classifier {

    private let catalog: FileCatalog
    private let downloads: String
    private let saves: String
    private var known: [UInt32: DayActivity] = [:]

    init(catalog: FileCatalog, spec: ProfileSpec) {
        self.catalog = catalog
        let old = spec.timeline.start.year <= 1996
        downloads = (old ? "\\DOWNLOAD" : "\\Downloads").lowercased()
        saves = (old ? "\\JEUX\\SAVE" : "\\Games\\Saves").lowercased()
    }

    /// L'activité d'un événement **déjà joué** : le fichier effacé n'est plus
    /// au catalogue, mais le rejeu en garde l'état d'avant.
    func activity(of timed: TimedEvent, step: SimulationStep,
                  in catalog: FileCatalog) -> DayActivity? {
        if case .create = timed.event { return activity(of: timed.event, in: catalog) }
        if case .defragment = timed.event { return .system }
        guard let record = step.before ?? step.after else {
            return activity(of: timed.event, in: catalog)
        }
        if let known = known[record.id] { return known }
        let activity = self.activity(category: record.category, path: { catalog.path(of: record) })
        known[record.id] = activity
        return activity
    }

    /// L'activité d'un événement qui n'est pas encore joué.
    func activity(of event: FileEvent, in catalog: FileCatalog) -> DayActivity? {
        switch event {
        case let .create(spec):
            let activity = self.activity(category: spec.category,
                                         path: { catalog.path(ofDirectory: spec.directory) })
            known[spec.id] = activity
            return activity
        case let .delete(id):
            defer { known[id] = nil }
            return activity(of: id, in: catalog)
        case let .append(id, _), let .rewrite(id), let .replaceViaTemporary(id, _),
             let .truncate(id, _):
            return activity(of: id, in: catalog)
        case .defragment:
            return .system
        }
    }

    private func activity(of id: UInt32, in catalog: FileCatalog) -> DayActivity {
        if let known = known[id] { return known }
        guard let record = catalog[id] else { return .system }
        let activity = self.activity(category: record.category,
                                     path: { catalog.path(of: record) })
        known[id] = activity
        return activity
    }

    /// Le chemin n'est calculé que pour les deux catégories qui en ont besoin.
    private func activity(category: FileCategory, path: () -> String) -> DayActivity {
        switch category {
        case .buildArtifact, .source: return .compile
        case .cache:                  return .browse
        case .media:                  return .media
        case .gameAsset:              return .game
        case .systemCore, .application: return .update
        case .swap, .metadata, .temporary, .directory: return .system
        case .document:
            return path().lowercased().hasPrefix(saves) ? .game : .office
        case .archive:
            return path().lowercased().hasPrefix(downloads) ? .download : .hoard
        }
    }
}
