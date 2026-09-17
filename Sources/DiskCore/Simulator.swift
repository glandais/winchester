import Foundation

/// Avancement d'une génération, publiable vers une interface.
public struct GenerationProgress: Sendable {
    public var completedEvents: Int
    public var totalEvents: Int
    /// Jour courant du scénario.
    public var day: UInt32
    public var fileCount: Int
    public var fill: Double

    public var fraction: Double {
        totalEvents > 0 ? Double(completedEvents) / Double(totalEvents) : 1
    }
}

/// Journal de génération, injecté par l'appelant.
///
/// Un protocole plutôt que des `print` : le noyau tourne hors du fil principal,
/// sur un téléphone, et ce qu'il a à dire n'a rien à faire dans la console d'un
/// build de production.
public protocol GenerationLogger: Sendable {
    func log(_ message: String)
}

/// Le journal par défaut : celui qui ne dit rien.
public struct SilentLogger: GenerationLogger {
    public init() {}
    public func log(_ message: String) {}
}

/// Ce que la génération produit.
public struct SimulationOutcome: Sendable {
    public var catalog: FileCatalog
    public var metrics: AllocationMetrics
    /// Écritures refusées faute de place. Une valeur non nulle n'est pas un
    /// bug : c'est un disque plein, et c'est une situation que les scénarios de
    /// 2003 cherchent explicitement à atteindre.
    public var failedWrites: Int
    public var defragRuns: Int
    public var dayCount: UInt32
}

/// Ce qu'un événement a changé sur le disque, pour qui le rejoue pas à pas.
public struct SimulationStep: Sendable {
    /// Le fichier tel qu'il vient d'être posé, extents compris.
    public var created: FileRecord?
    /// Le fichier tel qu'il était avant d'être effacé.
    public var deleted: FileRecord?
    /// Clusters que la table de métadonnées vient de prendre pour grandir.
    public var metadataGrew: [Extent] = []
    /// L'écriture a été refusée faute de place.
    public var failed = false

    public init() {}
}

/// Rejoue une timeline en mutant une bitmap et un catalogue.
///
/// Le simulateur ne décide de rien : il applique. Toute la fragmentation qui en
/// sort vient de l'ordre des événements et de la stratégie de l'allocateur,
/// jamais d'un réglage posé ici.
public struct Simulator<A: Allocator> {

    public private(set) var allocator: A
    public private(set) var catalog: FileCatalog
    public let logger: GenerationLogger

    /// Événements entre deux vérifications d'annulation et deux rapports
    /// d'avancement. Assez petit pour qu'un utilisateur qui annule n'attende
    /// pas, assez grand pour que le test ne coûte rien.
    private let reportInterval = 512

    private var failedWrites = 0
    private var defragRuns = 0

    public init(allocator: A, catalog: FileCatalog = FileCatalog(), logger: GenerationLogger = SilentLogger()) {
        self.allocator = allocator
        self.catalog = catalog
        self.logger = logger
    }

    // MARK: - Rejeu

    /// - Parameter onProgress: appelé à intervalles réguliers, jamais à chaque
    ///   événement : une génération en compte des centaines de milliers.
    /// - Throws: `CancellationError` si la tâche a été annulée.
    public mutating func run(_ timeline: EventTimeline,
                             onProgress: ((GenerationProgress) -> Void)? = nil) throws -> SimulationOutcome {
        catalog.reserveCapacity(timeline.count / 2)
        var currentDay: UInt32 = 0

        for (index, timed) in timeline.events.enumerated() {
            if index % reportInterval == 0 {
                try Task.checkCancellation()
                onProgress?(GenerationProgress(completedEvents: index,
                                               totalEvents: timeline.count,
                                               day: currentDay,
                                               fileCount: catalog.liveCount,
                                               fill: allocator.bitmap.fill))
            }
            currentDay = timed.day
            apply(timed.event, on: timed.day)
        }

        onProgress?(GenerationProgress(completedEvents: timeline.count,
                                       totalEvents: timeline.count,
                                       day: currentDay,
                                       fileCount: catalog.liveCount,
                                       fill: allocator.bitmap.fill))

        let metrics = AllocationMetrics.evaluate(files: catalog.files.map(\.entry),
                                                 bitmap: allocator.bitmap,
                                                 profile: allocator.profile)
        logger.log("volume terminé : \(metrics.fileCount) fichiers, \(metrics.freeRunCount) trous, "
                   + "remplissage \(Int(metrics.fill * 100)) %")

        return SimulationOutcome(catalog: catalog,
                                 metrics: metrics,
                                 failedWrites: failedWrites,
                                 defragRuns: defragRuns,
                                 dayCount: timeline.dayCount)
    }

    /// Rejoue un seul événement, et dit ce qu'il a changé sur le disque.
    ///
    /// C'est `apply` vu de l'extérieur : même effet, plus un compte rendu. Il
    /// coûte une copie des extents de métadonnées par appel, ce que `run` ne
    /// paie pas — on ne s'en sert que pour les quelques milliers d'événements
    /// d'une installation qu'on veut rejouer à l'oreille.
    public mutating func step(_ timed: TimedEvent) -> SimulationStep {
        let metadataBefore = allocator.metadataExtents
        let failuresBefore = failedWrites
        var result = SimulationStep()

        switch timed.event {
        case let .create(spec):
            apply(timed.event, on: timed.day)
            result.created = catalog[spec.id]
        case let .delete(id):
            result.deleted = catalog[id]
            apply(timed.event, on: timed.day)
        default:
            apply(timed.event, on: timed.day)
        }

        result.failed = failedWrites > failuresBefore
        let metadataAfter = allocator.metadataExtents
        if metadataAfter.clusterCount != metadataBefore.clusterCount {
            result.metadataGrew = metadataAfter.subtracting(metadataBefore)
        }
        return result
    }

    private mutating func apply(_ event: FileEvent, on day: UInt32) {
        switch event {
        case let .create(spec):
            create(spec, on: day)

        case let .append(id, bytes):
            guard var record = catalog[id] else { return }
            allocator.grow(file: &record.entry, toLogicalSize: bytes)
            if record.entry.logicalSize < bytes { failedWrites += 1 }
            record.modifiedDay = day
            catalog[id] = record

        case .rewrite:
            // Réécriture sur place : les octets changent, pas la chaîne de
            // clusters. Rien à allouer, rien à libérer — et c'est bien le
            // résultat attendu, tout ne fragmente pas.
            break

        case let .replaceViaTemporary(id, newBytes):
            replaceViaTemporary(id: id, newBytes: newBytes, on: day)

        case let .truncate(id, bytes):
            guard var record = catalog[id] else { return }
            allocator.shrink(file: &record.entry, toLogicalSize: bytes)
            record.modifiedDay = day
            catalog[id] = record

        case let .delete(id):
            guard var record = catalog.remove(id) else { return }
            allocator.release(file: &record.entry)
            allocator.noteFileDeleted()

        case .defragment:
            defragment()
        }
    }

    private mutating func create(_ spec: FileSpec, on day: UInt32) {
        // Les identifiants viennent de la timeline : le catalogue se contente
        // de faire de la place.
        catalog.reserve(id: spec.id)

        var entry = FileEntry(id: spec.id, logicalSize: spec.bytes, hint: spec.resolvedHint)
        allocator.place(file: &entry)
        guard !entry.extents.isEmpty || entry.isResident || spec.bytes == 0 else {
            failedWrites += 1
            return
        }
        catalog.insert(FileRecord(entry: entry,
                                  name: spec.name,
                                  directory: spec.directory,
                                  category: spec.category,
                                  pattern: spec.pattern,
                                  createdDay: day))
    }

    /// Le motif de Word : le temporaire est écrit **pendant que l'original
    /// existe encore**, et ce n'est qu'ensuite que l'ancien est libéré. L'ordre
    /// est tout : écrire d'abord, libérer ensuite, c'est ce qui fait que le
    /// document ne retombe jamais à sa place et laisse un trou derrière lui à
    /// chaque enregistrement.
    private mutating func replaceViaTemporary(id: UInt32, newBytes: ByteCount, on day: UInt32) {
        guard var record = catalog[id] else { return }
        let old = record.entry

        var replacement = FileEntry(id: id, logicalSize: newBytes, hint: old.hint)
        allocator.place(file: &replacement)
        guard !replacement.extents.isEmpty || replacement.isResident else {
            failedWrites += 1
            return
        }

        var previous = old
        allocator.release(file: &previous)
        // Le temporaire a consommé un enregistrement de métadonnées en
        // naissant ; l'original rend le sien en disparaissant. Sans ce
        // décompte, un document enregistré deux cents fois gonflerait la MFT de
        // deux cents entrées fantômes.
        allocator.noteFileDeleted()

        record.entry = replacement
        record.modifiedDay = day
        catalog[id] = record
    }

    // MARK: - Défragmentation

    /// Passe complète : chaque fichier est rendu contigu et tassé vers le début
    /// du volume, dans l'ordre du parcours de l'arborescence — le seul ordre
    /// dont disposait un défragmenteur d'époque.
    ///
    /// Le fichier d'échange ne bouge pas : le système l'a ouvert, et tout est
    /// tassé autour de lui.
    private mutating func defragment() {
        defragRuns += 1
        let walk = catalog.directoryWalkOrder()

        var pinned: [Extent] = []
        var movable: [FileRecord] = []
        movable.reserveCapacity(walk.count)

        for record in walk {
            if record.entry.hint == .reservedContiguous || record.category == .swap {
                pinned.append(contentsOf: record.extents)
            } else if !record.isResident && !record.extents.isEmpty {
                movable.append(record)
            }
        }

        // Tout ce qui est déplaçable est libéré d'un bloc, puis reposé en
        // partant du début. Un vrai défragmenteur procède fichier par fichier,
        // avec des évacuations en cascade ; le résultat final est le même, et
        // c'est lui qu'on modélise ici. Le détail des mouvements appartient au
        // planificateur de la passe, qui est un autre sujet.
        for record in movable {
            var entry = record.entry
            allocator.release(file: &entry)
        }

        var cursor: UInt32 = 0
        for var record in movable {
            let needed = allocator.profile.clusters(forBytes: record.logicalSize)
            var placed: [Extent] = []
            var remaining = needed

            while remaining > 0, cursor < allocator.bitmap.clusterCount {
                guard let run = allocator.bitmap.nextFreeRun(from: cursor, limit: remaining) else { break }
                let take = min(run.length, remaining)
                let extent = Extent(start: run.start, length: take)
                guard allocator.claim(extent) else { break }
                placed.appendRun(start: extent.start, length: extent.length)
                remaining -= take
                cursor = extent.end
            }

            guard remaining == 0 else {
                // Ne devrait pas arriver : la place vient d'être libérée.
                allocator.free(placed)
                failedWrites += 1
                continue
            }
            record.entry.extents = placed
            catalog[record.id] = record
        }

        logger.log("défragmentation : \(movable.count) fichiers tassés, "
                   + "\(pinned.count) extents immobiles")
    }
}
