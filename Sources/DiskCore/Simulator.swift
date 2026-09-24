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
    /// Le fichier avant l'événement, `nil` pour une création.
    public var before: FileRecord?
    /// Le fichier après, `nil` pour un effacement ou une écriture refusée.
    public var after: FileRecord?
    /// Clusters qui reçoivent des données : tout le fichier pour une création,
    /// un réenregistrement ou une réécriture sur place, la fin ajoutée pour un
    /// ajout.
    public var written: [Extent] = []
    /// Clusters que l'allocateur vient de prendre. Une réécriture sur place
    /// écrit sans rien prendre.
    public var allocated: [Extent] = []
    /// Clusters rendus : un effacement, la fin d'une troncature, l'ancienne
    /// place d'un fichier réenregistré.
    public var released: [Extent] = []
    /// Ce qu'une défragmentation de l'histoire a déplacé, fichier par fichier.
    public var moves: [FileMove] = []
    /// Clusters que la table de métadonnées vient de prendre pour grandir.
    public var metadataGrew: [Extent] = []
    /// Clusters que des répertoires viennent de prendre — celui du fichier, ou
    /// celui d'un autre programme qui écrivait en même temps : ils sont
    /// rapportés avec l'événement qui suit leur croissance.
    public var directoryGrew: [Extent] = []
    /// L'écriture a été refusée faute de place.
    public var failed = false

    public init() {}

    /// Le fichier créé, s'il l'a été.
    public var created: FileRecord? { before == nil ? after : nil }
    /// Le fichier effacé, s'il l'a été.
    public var deleted: FileRecord? { after == nil && failed == false ? before : nil }
}

/// Un fichier qu'une défragmentation a changé de place.
public struct FileMove: Sendable {
    public var record: FileRecord
    public var from: [Extent]
    public var to: [Extent] { record.extents }
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

    /// Les programmes d'une même journée écrivent-ils en même temps ?
    ///
    /// Le tourniquet sait les entrelacer, paquet par paquet ; **aucun volume de
    /// la galerie ne s'en sert** (`DiskGenerator.runsProgramsConcurrently`, qui
    /// dit pourquoi). Il n'y a donc pas de valeur par défaut : un appelant qui
    /// veut l'entrelacement le demande, et tout autre prend le chemin de la
    /// production, dans l'ordre où la journée a été écrite.
    public let concurrent: Bool

    /// Événements entre deux vérifications d'annulation et deux rapports
    /// d'avancement. Assez petit pour qu'un utilisateur qui annule n'attende
    /// pas, assez grand pour que le test ne coûte rien.
    private let reportInterval = 512

    private var failedWrites = 0
    private var defragRuns = 0

    /// Écritures refusées depuis le début du rejeu.
    public var failedWriteCount: Int { failedWrites }

    /// La tranche de journée en cours : ce qu'elle reste à jouer, programme par
    /// programme (`load`, `next`).
    /// L'histoire dont la tranche est tirée, gardée entière — un tableau
    /// partagé, pas une copie — et désignée par indices dans les files.
    private var events: [TimedEvent] = []
    private var queues: [Queue] = []
    /// Le prochain programme à qui revient la main.
    private var turn = 0
    /// Programmes qui ont encore quelque chose à écrire dans la tranche.
    private var busyQueues = 0
    /// Une tranche qu'un seul programme écrit — toute tranche sous MS-DOS — se
    /// joue dans l'ordre, sans files : ce qui en reste.
    private var sequential: Range<Int> = 0..<0

    /// Le paquet d'écriture du format, en clusters (`writePacketBytes`).
    private let packetClusters: UInt32

    /// Ce que coûte une entrée de répertoire sur ce volume. `nil` : les
    /// répertoires ne sont que des noms, et ne prennent aucune place — ce que
    /// font les volumes d'essai des tests, qui mesurent autre chose.
    public let directories: DirectoryFormat?
    /// Clusters que des répertoires ont pris depuis le dernier compte rendu :
    /// ils seront rendus avec le prochain, comme des métadonnées.
    private var directoryGrowth: [Extent] = []
    private var reportsDirectoryGrowth = false

    public init(allocator: A, catalog: FileCatalog = FileCatalog(),
                logger: GenerationLogger = SilentLogger(), concurrent: Bool,
                directories: DirectoryFormat? = nil) {
        self.directories = directories
        self.packetClusters = allocator.profile.writePacketClusters
        self.allocator = allocator
        self.catalog = catalog
        self.logger = logger
        self.concurrent = concurrent
    }

    // MARK: - Rejeu

    /// - Parameter onProgress: appelé à intervalles réguliers, jamais à chaque
    ///   événement : une génération en compte des centaines de milliers.
    /// - Throws: `CancellationError` si la tâche a été annulée.
    public mutating func run(_ timeline: EventTimeline,
                             onProgress: ((GenerationProgress) -> Void)? = nil) throws -> SimulationOutcome {
        catalog.reserveCapacity(timeline.count / 2)
        var currentDay: UInt32 = 0
        var completed = 0
        var position = 0
        let events = timeline.events

        while position < events.count {
            position = load(events, from: position)
            while let done = next(reporting: false) {
                if completed % reportInterval == 0 {
                    try Task.checkCancellation()
                    onProgress?(GenerationProgress(completedEvents: completed,
                                                   totalEvents: timeline.count,
                                                   day: currentDay,
                                                   fileCount: catalog.liveCount,
                                                   fill: allocator.bitmap.fill))
                }
                currentDay = done.timed.day
                completed += 1
            }
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

    // MARK: - La journée, programme par programme

    /// Une écriture dont le programme ne connaît pas la taille, en cours : le
    /// fichier tel qu'il est, et ce qu'il lui reste à prendre.
    private struct Stream {
        enum Kind {
            /// Un fichier qui naît.
            case create(FileSpec)
            /// Un fichier qui s'allonge : sa taille visée, et le nombre de
            /// clusters qu'il occupait avant.
            case append(toBytes: ByteCount, clustersBefore: UInt32, wasResident: Bool)
            /// Le temporaire d'un réenregistrement, qui remplacera l'original.
            case replace(newBytes: ByteCount)
        }
        var kind: Kind
        var entry: FileEntry
        var remaining: UInt32
        /// Le fichier avant l'écriture, pour le compte rendu.
        var before: FileRecord?
    }

    /// Ce qu'un programme a encore à écrire dans la tranche, dans son ordre à
    /// lui.
    private struct Queue {
        var events: [Int] = []
        var head = 0
        var stream: Stream?
        var isBusy: Bool { stream != nil || head < events.count }
    }

    /// Une tranche de journée a-t-elle encore des événements à jouer ?
    public var hasPendingEvents: Bool { busyQueues > 0 }

    /// Le prochain événement qu'un programme commencera, sans le jouer. Sans
    /// entrelacement, c'est exactement le prochain à finir.
    public var nextPendingEvent: TimedEvent? {
        guard busyQueues > 0 else { return nil }
        if !sequential.isEmpty { return events[sequential.lowerBound] }
        for offset in 0..<queues.count {
            let queue = queues[(turn + offset) % queues.count]
            if queue.stream == nil, queue.head < queue.events.count {
                return events[queue.events[queue.head]]
            }
        }
        return nil
    }

    /// Événements chargés et pas encore finis.
    public var pendingEventCount: Int {
        sequential.count + queues.reduce(0) { $0 + $1.events.count - $1.head }
    }

    /// Charge la tranche de journée qui commence à `position` : les événements
    /// du même jour jusqu'à la prochaine défragmentation exclue — ou la
    /// défragmentation seule. Une passe de défragmentation ne commence
    /// qu'une fois toutes les écritures finies, et rien ne s'écrit pendant
    /// qu'elle tourne.
    ///
    /// - Returns: la position qui suit la tranche.
    public mutating func load(_ events: [TimedEvent], from position: Int) -> Int {
        precondition(busyQueues == 0, "la tranche précédente n'est pas finie")
        guard position < events.count else { return position }
        let day = events[position].day
        var end = position
        if case .defragment = events[position].event {
            end += 1
        } else {
            while end < events.count, events[end].day == day {
                if case .defragment = events[end].event { break }
                end += 1
            }
        }
        self.events = events

        let program = events[position].program
        if !concurrent || events[position..<end].allSatisfy({ $0.program == program }) {
            sequential = position..<end
            queues = []
            busyQueues = 1
            return end
        }
        if concurrent {
            queues = Array(repeating: Queue(), count: Program.allCases.count)
            for index in position..<end {
                queues[Int(events[index].program.rawValue)].events.append(index)
            }
            queues.removeAll { $0.events.isEmpty }
        } else {
            queues = [Queue(events: Array(position..<end))]
        }
        turn = 0
        busyQueues = queues.count
        return end
    }

    /// Joue jusqu'à ce qu'un événement de la tranche soit fini.
    ///
    /// Les programmes ont la main à tour de rôle, dans l'ordre fixe de
    /// `Program` : un tour, c'est un événement entier, ou **un paquet** d'une
    /// écriture dont le programme ne connaît pas la taille. Deux fichiers écrits
    /// ainsi en même temps prennent donc leurs paquets en alternance au même
    /// curseur, et sortent entrelacés — sans qu'aucun tirage ne s'en mêle : la
    /// même tranche donne toujours le même volume.
    ///
    /// Un programme resté seul finit son écriture d'un coup : personne ne peut
    /// plus s'intercaler, et paquet par paquet ne prendrait pas d'autres
    /// clusters (`Allocator.stream`).
    ///
    /// - Parameter reporting: construire le compte rendu de l'événement fini,
    ///   ce que `run` ne paie pas.
    /// - Returns: l'événement fini, et ce qu'il a changé si on l'a demandé ;
    ///   `nil` quand la tranche est finie.
    public mutating func next(reporting: Bool) -> (timed: TimedEvent, step: SimulationStep?)? {
        reportsDirectoryGrowth = reporting
        if !reporting { directoryGrowth.removeAll() }
        // Un programme seul : chaque événement d'un tenant, écritures par
        // paquets comprises — personne ne peut s'intercaler entre ses
        // paquets, `apply` les écrit d'un bloc (`Allocator.placeStreamed`,
        // `growStreamed`) et le volume est le même.
        if !sequential.isEmpty {
            let timed = events[sequential.lowerBound]
            begin(timed)
            sequential = sequential.dropFirst()
            if sequential.isEmpty { busyQueues = 0 }
            return (timed, perform(timed, reporting: reporting))
        }
        while busyQueues > 0 {
            if busyQueues > 1, let finished = playRounds(reporting: reporting) { return finished }
            let index = turn
            turn = (turn + 1) % queues.count
            guard queues[index].isBusy else { continue }
            let alone = busyQueues == 1
            let finished = play(queue: index, alone: alone, reporting: reporting)
            if !queues[index].isBusy { busyQueues -= 1 }
            if let finished { return finished }
        }
        return nil
    }

    /// Quand **tous** les programmes occupés sont au milieu d'une écriture par
    /// paquets, les tours qui suivent jusqu'à la fin de la première sont
    /// connus d'avance : chacun prend un paquet, à tour de rôle. Si le format
    /// sait dire quels clusters ces paquets prendront sans les demander un à un
    /// (`Allocator.takeInWritingOrder` — FAT, où c'est le curseur qui décide),
    /// ils sont joués d'un bloc : mêmes clusters, aux mêmes fichiers, dans le
    /// même ordre, pour un parcours de bitmap au lieu d'un par cluster.
    ///
    /// - Returns: l'écriture qui finit la première, `nil` si les tours doivent
    ///   être joués un à un.
    private mutating func playRounds(reporting: Bool) -> (timed: TimedEvent, step: SimulationStep?)? {
        guard packetClusters == 1 else { return nil }
        for queue in queues where queue.isBusy && queue.stream == nil { return nil }
        var order: [Int] = []
        for offset in 0..<queues.count {
            let index = (turn + offset) % queues.count
            guard queues[index].isBusy else { continue }
            guard queues[index].stream != nil else { return nil }
            order.append(index)
        }
        let count = order.count
        guard count > 1 else { return nil }

        // Le tour où finit la première écriture : le programme de rang `j`
        // joue les tours j, j + count, j + 2·count…
        var last = Int.max
        var first = 0
        for (rank, index) in order.enumerated() {
            let turnOfEnd = (Int(queues[index].stream!.remaining) - 1) * count + rank
            if turnOfEnd < last { last = turnOfEnd; first = rank }
        }
        let metadataBefore = reporting ? allocator.metadataExtents : []
        guard let taken = allocator.takeInWritingOrder(UInt32(last + 1),
                                                       hints: order.map { queues[$0].stream!.entry.hint })
        else { return nil }

        var streams = order.map { queues[$0].stream.take()! }
        var rank = 0
        for extent in taken {
            for cluster in extent.start..<extent.end {
                streams[rank].entry.extents.appendCluster(cluster)
                streams[rank].remaining -= 1
                rank = rank + 1 == count ? 0 : rank + 1
            }
        }
        for (rank, index) in order.enumerated() where rank != first {
            queues[index].stream = streams[rank]
        }

        let index = order[first]
        turn = (index + 1) % queues.count
        let timed = events[queues[index].events[queues[index].head]]
        queues[index].head += 1
        if !queues[index].isBusy { busyQueues -= 1 }
        return (timed, finish(streams[first], written: true, on: timed.day,
                              metadataBefore: metadataBefore, reporting: reporting))
    }

    /// Le jour du dernier montage du volume.
    private var mountedDay: UInt32?

    /// Un événement commence : le premier de sa journée trouve un volume qui
    /// vient d'être monté — la machine a été éteinte la nuit —, les suivants
    /// un volume dont le journal a fait un point de contrôle depuis
    /// l'événement d'avant (`Allocator.mount`, `Allocator.checkpoint`).
    private mutating func begin(_ timed: TimedEvent) {
        if timed.day != mountedDay {
            mountedDay = timed.day
            allocator.mount()
        } else {
            allocator.checkpoint()
        }
    }

    /// Un tour d'un programme.
    private mutating func play(queue index: Int, alone: Bool,
                               reporting: Bool) -> (timed: TimedEvent, step: SimulationStep?)? {
        // Le flux est sorti de sa file le temps du tour : resté référencé
        // là, ses extents seraient recopiés à chaque paquet.
        var stream: Stream
        if let current = queues[index].stream.take() {
            stream = current
        } else {
            let timed = events[queues[index].events[queues[index].head]]
            begin(timed)
            guard let started = startStream(timed, reporting: reporting) else {
                queues[index].head += 1
                return (timed, perform(timed, reporting: reporting))
            }
            stream = started
        }

        let packet = alone ? stream.remaining : min(stream.remaining, packetClusters)
        let metadataBefore = reporting ? allocator.metadataExtents : []
        let written = allocator.stream(file: &stream.entry, clusters: packet)
        if written { stream.remaining -= packet }
        guard !written || stream.remaining == 0 else {
            queues[index].stream = stream
            return nil
        }

        let timed = events[queues[index].events[queues[index].head]]
        queues[index].head += 1
        return (timed, finish(stream, written: written, on: timed.day,
                              metadataBefore: metadataBefore, reporting: reporting))
    }

    /// Cet événement s'écrit-il par paquets ? Si oui, l'écriture commence :
    /// rien n'est encore pris.
    private mutating func startStream(_ timed: TimedEvent, reporting: Bool) -> Stream? {
        let profile = allocator.profile
        switch timed.event {
        case let .create(spec):
            guard !spec.sizeKnownInAdvance, spec.bytes > 0, !profile.isResident(bytes: spec.bytes) else { return nil }
            catalog.reserve(id: spec.id)
            // Le fichier est créé — son entrée écrite dans son répertoire —
            // avant qu'un octet de données ne le soit.
            addEntry(named: spec.name, to: spec.directory)
            return Stream(kind: .create(spec),
                          entry: FileEntry(id: spec.id, logicalSize: spec.bytes, hint: spec.resolvedHint),
                          remaining: profile.clusters(forBytes: spec.bytes))

        case let .append(id, bytes):
            // Un journal qui grossit est écrit par le programme qui l'alimente,
            // au fil de ce qu'il reçoit : personne ne déclare la taille d'un
            // ajout. Seul le fichier d'échange fait exception — le gestionnaire
            // de mémoire décide d'une taille, et la demande.
            guard let record = catalog[id], case .append = record.pattern,
                  bytes > record.logicalSize, !profile.isResident(bytes: bytes) else { return nil }
            var entry = record.entry
            let before = entry.isResident ? 0 : profile.clusters(forBytes: entry.logicalSize)
            let after = profile.clusters(forBytes: bytes)
            if entry.isResident { entry.extents = [] }
            guard after > before else { return nil }
            return Stream(kind: .append(toBytes: bytes, clustersBefore: before, wasResident: record.isResident),
                          entry: entry, remaining: after - before,
                          before: reporting ? record : nil)

        case let .replaceViaTemporary(id, newBytes):
            // Le temporaire est écrit par l'application qui enregistre — Word
            // sérialise son document composé au fil de l'écriture, un jeu son
            // état : aucune des deux ne connaît la taille avant la fin.
            guard let record = catalog[id], newBytes > 0, !profile.isResident(bytes: newBytes) else { return nil }
            addEntry(named: Self.temporaryName, to: record.directory)
            return Stream(kind: .replace(newBytes: newBytes),
                          entry: FileEntry(id: id, logicalSize: newBytes, hint: record.entry.hint),
                          remaining: profile.clusters(forBytes: newBytes),
                          before: reporting ? record : nil)

        default:
            return nil
        }
    }

    /// Une écriture par paquets est finie — ou a échoué faute de place, et
    /// `Allocator.stream` a rendu le paquet refusé ; le reste est rendu ici.
    private mutating func finish(_ stream: Stream, written: Bool, on day: UInt32,
                                 metadataBefore: [Extent], reporting: Bool) -> SimulationStep? {
        var result = SimulationStep()
        var entry = stream.entry

        switch stream.kind {
        case let .create(spec):
            if written {
                allocator.noteFileCreated(logicalSize: spec.bytes)
                let record = FileRecord(entry: entry, name: spec.name, directory: spec.directory,
                                        category: spec.category, pattern: spec.pattern, createdDay: day)
                catalog.insert(record)
                result.after = record
                result.written = entry.extents
                result.allocated = entry.extents
            } else {
                allocator.free(entry.extents)
                allocator.noteFileCreated(logicalSize: spec.bytes)
                removeEntry(named: spec.name, from: spec.directory)
                failedWrites += 1
                result.failed = true
            }

        case let .append(bytes, clustersBefore, wasResident):
            guard var record = catalog[entry.id] else { return nil }
            if written {
                entry.logicalSize = bytes
                entry.isResident = false
                record.entry = entry
            } else {
                // Rendre ce que les paquets précédents ont ajouté, par la fin.
                allocator.releaseTail(of: &entry, keeping: wasResident ? 0 : clustersBefore)
                failedWrites += 1
                result.failed = true
            }
            record.modifiedDay = day
            catalog[entry.id] = record
            result.before = stream.before
            result.after = record
            if reporting, let old = stream.before {
                result.allocated = record.extents.subtracting(old.extents)
                result.written = result.allocated
            }

        case .replace:
            guard var record = catalog[entry.id] else { return nil }
            removeEntry(named: Self.temporaryName, from: record.directory)
            result.before = stream.before
            // Le temporaire a son enregistrement de métadonnées, qu'il soit
            // écrit ou non, pris après ses données et avant que l'original ne
            // rende les siennes — l'ordre de `placeStreamed`.
            if written {
                allocator.noteFileCreated(logicalSize: entry.logicalSize)
                var previous = record.entry
                allocator.release(file: &previous)
                // Le temporaire a consommé un enregistrement de métadonnées en
                // naissant ; l'original rend le sien en disparaissant.
                allocator.noteFileDeleted()
                record.entry = entry
                record.modifiedDay = day
                catalog[entry.id] = record
                if reporting, let old = stream.before {
                    result.written = entry.extents
                    result.allocated = entry.extents.subtracting(old.extents)
                    result.released = old.extents.subtracting(entry.extents)
                }
            } else {
                allocator.free(entry.extents)
                allocator.noteFileCreated(logicalSize: entry.logicalSize)
                failedWrites += 1
                result.failed = true
            }
            result.after = catalog[entry.id]
        }

        guard reporting else { return nil }
        let metadataAfter = allocator.metadataExtents
        if metadataAfter.clusterCount != metadataBefore.clusterCount {
            result.metadataGrew = metadataAfter.subtracting(metadataBefore)
        }
        result.directoryGrew = directoryGrowth
        directoryGrowth.removeAll()
        return result
    }

    /// Rejoue un événement d'un seul tenant.
    private mutating func perform(_ timed: TimedEvent, reporting: Bool) -> SimulationStep? {
        guard reporting else {
            apply(timed.event, on: timed.day)
            return nil
        }
        return step(timed)
    }

    /// Rejoue un seul événement, et dit ce qu'il a changé sur le disque.
    ///
    /// C'est `apply` vu de l'extérieur : même effet, plus un compte rendu. Il
    /// coûte une copie des extents du fichier et des métadonnées par appel, ce
    /// que `run` ne paie pas — on ne s'en sert que pour ce qu'on veut rejouer à
    /// l'oreille.
    private mutating func step(_ timed: TimedEvent) -> SimulationStep {
        let metadataBefore = allocator.metadataExtents
        let failuresBefore = failedWrites
        var result = SimulationStep()

        switch timed.event {
        case let .create(spec):
            apply(timed.event, on: timed.day)
            result.after = catalog[spec.id]
            let extents = result.after?.extents ?? []
            result.written = extents
            result.allocated = extents

        case let .delete(id):
            result.before = catalog[id]
            apply(timed.event, on: timed.day)
            result.released = result.before?.extents ?? []

        case let .append(id, _), let .truncate(id, _), let .replaceViaTemporary(id, _):
            result.before = catalog[id]
            apply(timed.event, on: timed.day)
            result.after = catalog[id]
            let old = result.before?.extents ?? []
            let new = result.after?.extents ?? []
            switch timed.event {
            case .replaceViaTemporary:
                // Le temporaire est écrit en entier, ailleurs, puis l'original
                // rend sa place.
                if old != new {
                    result.written = new
                    result.allocated = new.subtracting(old)
                    result.released = old.subtracting(new)
                }
            default:
                result.allocated = new.subtracting(old)
                result.written = result.allocated
                result.released = old.subtracting(new)
            }

        case let .rewrite(id):
            result.before = catalog[id]
            apply(timed.event, on: timed.day)
            result.after = result.before
            result.written = result.before?.extents ?? []

        case .defragment:
            var places: [UInt32: [Extent]] = [:]
            for record in catalog.files where !record.extents.isEmpty {
                places[record.id] = record.extents
            }
            let directoriesBefore = catalog.directories.map(\.extents)
            apply(timed.event, on: timed.day)
            for item in catalog.treeWalkOrder() {
                switch item {
                case let .file(record):
                    guard let from = places[record.id], from != record.extents else { continue }
                    result.moves.append(FileMove(record: record, from: from))
                case let .directory(directory):
                    let from = directoriesBefore[Int(directory.id)]
                    guard from != directory.extents else { continue }
                    result.moves.append(FileMove(record: Self.record(of: directory), from: from))
                }
            }
        }

        result.failed = failedWrites > failuresBefore
        let metadataAfter = allocator.metadataExtents
        if metadataAfter.clusterCount != metadataBefore.clusterCount {
            result.metadataGrew = metadataAfter.subtracting(metadataBefore)
        }
        result.directoryGrew = directoryGrowth
        directoryGrowth.removeAll()
        return result
    }

    private mutating func apply(_ event: FileEvent, on day: UInt32) {
        switch event {
        case let .create(spec):
            create(spec, on: day)

        case let .append(id, bytes):
            guard var record = catalog[id] else { return }
            // Un journal qui grossit est écrit par le programme qui l'alimente,
            // au fil de ce qu'il reçoit : personne ne déclare la taille d'un
            // ajout. Seul le fichier d'échange fait exception — le gestionnaire
            // de mémoire décide d'une taille, et la demande.
            if case .append = record.pattern {
                allocator.growStreamed(file: &record.entry, toLogicalSize: bytes)
            } else {
                allocator.grow(file: &record.entry, toLogicalSize: bytes)
            }
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
            removeEntry(named: record.name, from: record.directory)

        case .defragment:
            defragment()
        }
    }

    private mutating func create(_ spec: FileSpec, on day: UInt32) {
        // Les identifiants viennent de la timeline : le catalogue se contente
        // de faire de la place.
        catalog.reserve(id: spec.id)
        addEntry(named: spec.name, to: spec.directory)

        var entry = FileEntry(id: spec.id, logicalSize: spec.bytes, hint: spec.resolvedHint)
        if spec.sizeKnownInAdvance {
            allocator.place(file: &entry)
        } else {
            _ = allocator.placeStreamed(file: &entry)
        }
        guard !entry.extents.isEmpty || entry.isResident || spec.bytes == 0 else {
            removeEntry(named: spec.name, from: spec.directory)
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

        // Le temporaire est écrit par l'application qui enregistre — Word
        // sérialise son document composé au fil de l'écriture, un jeu son
        // état : aucune des deux ne connaît la taille avant la fin.
        addEntry(named: Self.temporaryName, to: record.directory)
        defer { removeEntry(named: Self.temporaryName, from: record.directory) }
        var replacement = FileEntry(id: id, logicalSize: newBytes, hint: old.hint)
        _ = allocator.placeStreamed(file: &replacement)
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

    // MARK: - Répertoires

    /// Le nom du temporaire qu'une application écrit à côté du document
    /// qu'elle enregistre : un nom court, une entrée.
    private static var temporaryName: String { "~WRD0000.TMP" }

    /// Un répertoire vu comme un fichier — ce qu'il est sur FAT —, pour qui
    /// ne manipule que des fichiers : la défragmentation de l'histoire, le
    /// compte rendu de ses déplacements.
    static func record(of directory: DirectoryRecord) -> FileRecord {
        FileRecord(entry: directory.entry, name: directory.name,
                   directory: directory.parent ?? 0, category: .directory)
    }

    /// Écrit l'entrée d'un nom dans un répertoire : le répertoire naît s'il
    /// n'existait pas, et grandit si ses entrées débordent.
    private mutating func addEntry(named name: String, to directory: UInt32) {
        guard let format = directories else { return }
        if !catalog.directories[Int(directory)].exists { materialize(directory, format: format) }
        let bytes = format.entryBytes(forName: name)
        let overflows = catalog.updateDirectory(directory) { record -> Bool in
            record.entryBytes += bytes
            if record.entryBytes > record.peakEntryBytes { record.peakEntryBytes = record.entryBytes }
            return record.peakEntryBytes > record.capacityBytes
        }
        if overflows { fit(directory, format: format) }
    }

    /// Efface une entrée. Sa place est marquée libre et resservira ; le
    /// répertoire ne raccourcit pas.
    private mutating func removeEntry(named name: String, from directory: UInt32) {
        guard let format = directories, catalog.directories[Int(directory)].exists else { return }
        let bytes = format.entryBytes(forName: name)
        catalog.updateDirectory(directory) { $0.entryBytes -= min(bytes, $0.entryBytes) }
    }

    /// Crée un répertoire sur le disque, ses parents d'abord : chacun reçoit
    /// l'entrée de son enfant. Un sous-répertoire FAT naît avec un cluster —
    /// celui qui porte `.` et `..` —, pris au curseur comme n'importe quel
    /// fichier ; la racine d'un FAT32 aussi, au formatage. Sur NTFS, un
    /// répertoire est d'abord un enregistrement de MFT, et son index y tient
    /// tant qu'il est petit.
    private mutating func materialize(_ directory: UInt32, format: DirectoryFormat) {
        let record = catalog.directories[Int(directory)]
        guard !record.exists else { return }
        if let parent = record.parent { addEntry(named: record.name, to: parent) }
        let initial = record.parent == nil ? 0 : format.initialBytes
        // Une racine sans clusters ne déborde jamais — celle d'un FAT16 a ses
        // 512 entrées, et le modèle ne refuse pas la 513ᵉ. Un index NTFS tient
        // dans son enregistrement jusqu'à ce qu'il en sorte.
        let capacity: UInt64 = record.parent == nil && !format.rootTakesClusters ? .max
            : format.kind == .ntfs ? format.residentBytes : 0
        catalog.updateDirectory(directory) {
            $0.exists = true
            $0.entryBytes = initial
            $0.peakEntryBytes = initial
            $0.capacityBytes = capacity
        }
        // La racine d'un NTFS formaté par XP a déjà son tampon d'index, au
        // milieu du volume : `FORMAT` l'y a posé (`format.cxx:1175`). Elle le
        // reprend, et grandira derrière lui. Le cluster est pris depuis le
        // formatage ; il est rapporté ici, à la création de la racine, pour
        // que qui rejoue le journal sache à qui il est.
        if record.parent == nil, case .ntfs = format.kind, let root = allocator.formattedRootIndex {
            let bytes = UInt64(root.length) * UInt64(allocator.profile.clusterBytes)
            catalog.updateDirectory(directory) {
                $0.entry.extents = [root]
                $0.entry.logicalSize = bytes
                $0.capacityBytes = bytes
            }
            if reportsDirectoryGrowth { directoryGrowth.append(root) }
        }
        if case .ntfs = format.kind { allocator.noteFileCreated(logicalSize: 0) }
        fit(directory, format: format)
    }

    /// Donne à un répertoire les clusters que ses entrées demandent, au bout
    /// de ceux qu'il a déjà — là où l'allocateur en est rendu, donc loin
    /// d'eux.
    private mutating func fit(_ directory: UInt32, format: DirectoryFormat) {
        let record = catalog.directories[Int(directory)]
        if record.parent == nil, !format.rootTakesClusters { return }
        var wanted = format.clusters(forEntryBytes: record.peakEntryBytes)
        if case .fat = format.kind { wanted = max(wanted, 1) }
        let owned = record.entry.clusterCount
        guard wanted > owned else { return }
        var entry = record.entry
        // Un répertoire qui ne trouve plus de place ne grandit pas : c'est la
        // création suivante qui échouera en vrai. Le modèle garde le fichier,
        // et le répertoire trop court.
        guard allocator.extend(file: &entry, byClusters: wanted - owned) else { return }
        entry.logicalSize = UInt64(wanted) * UInt64(allocator.profile.clusterBytes)
        if reportsDirectoryGrowth {
            directoryGrowth.append(contentsOf: entry.extents.subtracting(record.entry.extents))
        }
        let capacity = entry.logicalSize
        catalog.updateDirectory(directory) {
            $0.entry = entry
            $0.capacityBytes = capacity
        }
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
        let walk = catalog.treeWalkOrder()

        var pinned: [Extent] = []
        var movable: [FileRecord] = []
        movable.reserveCapacity(walk.count)
        /// Les répertoires suivent le même chemin que les fichiers, marqués
        /// par leur catégorie : `DEFRAG.EXE` les déplaçait comme le reste, et
        /// les posait avant ce qu'ils contiennent.
        for item in walk {
            switch item {
            case let .directory(directory):
                if !directory.extents.isEmpty { movable.append(Self.record(of: directory)) }
            case let .file(record):
                if record.entry.hint == .reservedContiguous || record.category == .swap {
                    pinned.append(contentsOf: record.extents)
                } else if !record.isResident && !record.extents.isEmpty {
                    movable.append(record)
                }
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
            let isDirectory = record.category == .directory
            let needed = isDirectory
                ? record.entry.clusterCount
                : allocator.profile.clusters(forBytes: record.logicalSize)
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
            if isDirectory {
                catalog.updateDirectory(record.id) { $0.entry.extents = placed }
            } else {
                record.entry.extents = placed
                catalog[record.id] = record
            }
        }

        logger.log("défragmentation : \(movable.count) fichiers tassés, "
                   + "\(pinned.count) extents immobiles")
    }
}
