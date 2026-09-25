import Foundation
import DiskCore

/// Ce qu'une machine fait subir au disque quand elle écrit des fichiers.
///
/// Une installation pose des logiciels, une journée d'usage compile, enregistre
/// et efface ; ce qui se passe **entre** le fichier et le disque est le même
/// dans les deux cas :
///
/// - les données partent par tampons, dont la taille est celle du cache de
///   l'époque ;
/// - chaque fichier touché salit des secteurs de tables, écrits aussitôt sous
///   MS-DOS et par salves triées derrière un cache ensuite ;
/// - le temps passé hors du disque — lire la source, décompresser, calculer,
///   attendre l'utilisateur — s'accumule et part avec la requête suivante ;
/// - la carte des clusters se colore au moment où l'écriture se produit.
///
/// D'où cette pièce commune, que les deux planificateurs partagent.
struct MachineWriter {

    /// Même découpage que le démarrage : fin devant un extent.
    static let maxRequestSectors = 128

    let partition: PartitionGeometry
    let era: InstallEra
    let sink: OperationSink
    /// Débit du disque, pour estimer l'heure à laquelle le cache vide ses
    /// tables. Le planificateur ne connaît pas la mécanique ; il n'a besoin que
    /// d'un ordre de grandeur.
    let diskBytesPerSecond: Double
    /// Pages de `$LogFile` écrites jusqu'ici : le journal est circulaire, et
    /// chaque vidage écrit la suivante.
    private var journalPages = 0

    /// Phase dans laquelle tombent les opérations émises.
    var phase = 0
    /// Ce que l'écran montre de l'avancement, et ce qui est compté.
    var progress = 0.0
    var moves = MoveCount()

    /// Secteurs de métadonnées modifiés et pas encore écrits.
    private var dirty: [Int: Int] = [:]
    private var pendingMutations: [MapMutation] = []
    private(set) var pendingThink = 0.0
    /// Heure estimée de la passe, et du dernier vidage des tables.
    private(set) var clock = 0.0
    private var lastFlush = 0.0
    /// Rang de création d'un fichier, qui désigne son enregistrement dans la
    /// MFT. Les seize premiers sont ceux du système de fichiers lui-même.
    private var ranks: [UInt32: Int] = [:]
    /// Sous XP, le *lazy writer* et la file d'`atapi` (`LazyWriter`).
    private var lazy = LazyWriter()
    /// L'heure estimée de la fin de la dernière requête du premier plan.
    private var foregroundEnd = 0.0
    var queue = AtapiQueue()
    /// Le cache de NT tel que XP le code : ses tables partent par le *lazy
    /// writer*, en arrière-plan. Vista et 7 gardent le vidage du modèle.
    var usesLazyWriter: Bool { era.name == "Windows XP" && partition.format == .ntfs }

    // Ce qui se compte.
    private(set) var thinkSeconds = 0.0
    private(set) var metadataFlushes = 0
    private(set) var metadataSectors = 0
    private(set) var bytesWritten = 0
    private(set) var bytesRead = 0

    init(partition: PartitionGeometry, era: InstallEra, sink: OperationSink,
         diskBytesPerSecond: Double) {
        self.partition = partition
        self.era = era
        self.sink = sink
        self.diskBytesPerSecond = max(diskBytesPerSecond, 100_000)
    }

    // MARK: - Le temps passé ailleurs

    /// Ajoute du temps hors disque devant la prochaine requête.
    mutating func think(_ seconds: Double) {
        pendingThink += max(seconds, 0)
    }

    // MARK: - Les données

    /// Écrit le contenu d'un fichier, ou la part de ses extents qui vient d'être
    /// allouée.
    ///
    /// - Parameter sourceTime: ce que coûte, hors disque, la préparation de
    ///   chaque tampon : lire la source, décompresser, calculer.
    ///
    /// - Parameters:
    ///   - file: le fichier, et le rang de la première page écrite. Sous XP,
    ///     une écriture de programme passe par le cache : elle ne fait que
    ///     salir des pages, que le *lazy writer* écrira (`LazyWriter`). Sans
    ///     fichier, l'écriture part tout de suite, comme avant XP.
    mutating func write(_ extents: [Extent], bytes: Int, cluster kind: DiskOperation.Kind = .writeExtent,
                        file: (id: UInt32, firstPage: Int)? = nil,
                        sourceTime: (Int) -> Double = { _ in 0 }) {
        guard usesLazyWriter, let file, kind == .writeExtent else {
            transfer(extents, bytes: bytes, isWrite: true, kind: kind,
                     perRequestSectors: era.writeRequestSectors, cost: sourceTime)
            return
        }
        var remaining = PartitionGeometry.readSectors(forBytes: bytes, granularity: era.granularity)
        var page = file.firstPage
        let pageSectors = LazyWriter.pageSectors
        for extent in extents {
            let length = Int(extent.length) * partition.clusterSectors
            var offset = 0
            while offset < length && remaining > 0 {
                let sectors = min(length - offset, era.writeRequestSectors, remaining)
                think(sourceTime(min(sectors * DriveGeometry.bytesPerSector, bytes)))
                let lba = partition.lba(ofCluster: Int(extent.start)) + offset
                var piece = 0
                while piece < sectors {
                    lazy.dirty(.data(file.id), rank: page, lba: lba + piece, at: clock + pendingThink)
                    page += 1
                    piece += pageSectors
                }
                bytesWritten += min(sectors * DriveGeometry.bytesPerSector, bytes)
                offset += sectors
                remaining -= sectors
                runLazyWriter(at: clock + pendingThink)
            }
            if remaining == 0 { break }
        }
    }

    /// Un fichier effacé : ses pages sales sont purgées sans être écrites
    /// (`CcUninitializeCacheMap` à une taille nulle, `ntfs/cleanup.c:1576,
    /// 1930, 2515`).
    mutating func discard(file: UInt32) {
        guard usesLazyWriter else { return }
        lazy.discard(.data(file))
    }

    /// Lit le contenu d'un fichier, ou ce qu'on en touche.
    ///
    /// Sous XP, la lecture passe par le cache, avec sa lecture anticipée
    /// (`CcReadAhead`) : ce qui est déjà lu d'avance ne va pas au disque, et
    /// ce que le cache lit d'avance part en arrière-plan. `fileSize` borne
    /// cette lecture d'avance.
    mutating func read(_ extents: [Extent], bytes: Int, fileSize: Int? = nil,
                       cost: (Int) -> Double = { _ in 0 }) {
        guard usesLazyWriter else {
            transfer(extents, bytes: bytes, isWrite: false, kind: .readExtent,
                     perRequestSectors: Self.maxRequestSectors, cost: cost)
            return
        }
        var cache = CcReadAhead()
        let size = max(fileSize ?? bytes, bytes)
        let total = PartitionGeometry.readSectors(forBytes: bytes, granularity: era.granularity)
            * DriveGeometry.bytesPerSector
        var offset = 0
        let chunk = Self.maxRequestSectors * DriveGeometry.bytesPerSector
        while offset < total {
            let length = min(chunk, total - offset)
            think(cost(min(length, bytes - min(offset, bytes))))
            let (demand, ahead) = cache.read(offset: offset, length: length, fileSize: size)
            if let demand {
                for piece in CcReadAhead.pieces(of: extents, bytes: demand, partition: partition)
                where !inCache(lba: piece.lba, sectors: piece.sectors) {
                    emit(.readExtent, lba: piece.lba, sectors: piece.sectors, isWrite: false,
                         cluster: (piece.lba - partition.dataStartLBA) / partition.clusterSectors)
                }
            }
            if let ahead {
                for piece in CcReadAhead.pieces(of: extents, bytes: ahead, partition: partition)
                where !inCache(lba: piece.lba, sectors: piece.sectors) {
                    emitAhead(piece)
                }
            }
            bytesRead += min(length, max(bytes - offset, 0))
            offset += length
        }
    }

    /// Une lecture anticipée du cache : en arrière-plan, dès que le disque
    /// est libre.
    private mutating func emitAhead(_ piece: MetadataAccess) {
        sink.emit(DiskOperation(kind: .readExtent, phase: phase, lba: piece.lba, sectors: piece.sectors,
                                isWrite: false, issueTime: 0,
                                cluster: (piece.lba - partition.dataStartLBA) / partition.clusterSectors,
                                mutationStart: sink.mutationMark, mutationCount: 0,
                                flow: .background))
    }

    /// Sous XP, ce qu'une lecture trouve sale dans le cache n'est pas relu.
    func inCache(lba: Int, sectors: Int) -> Bool {
        guard usesLazyWriter else { return false }
        let page = LazyWriter.pageSectors
        return stride(from: lba / page * page, to: lba + sectors, by: page).allSatisfy { lazy.holds(lba: $0) }
    }

    private mutating func transfer(_ extents: [Extent], bytes: Int, isWrite: Bool,
                                   kind: DiskOperation.Kind, perRequestSectors: Int,
                                   cost: (Int) -> Double) {
        guard bytes > 0 else { return }
        // Des pages ou des secteurs, pas des clusters (`InstallEra.granularity`).
        var remaining = PartitionGeometry.readSectors(forBytes: bytes, granularity: era.granularity)
        for extent in extents {
            let length = Int(extent.length) * partition.clusterSectors
            var offset = 0
            while offset < length && remaining > 0 {
                let sectors = min(length - offset, perRequestSectors, remaining)
                let chunk = min(sectors * DriveGeometry.bytesPerSector, bytes)
                think(cost(chunk))
                let cluster = Int(extent.start) + offset / partition.clusterSectors
                let lba = partition.lba(ofCluster: Int(extent.start)) + offset
                if isWrite || !inCache(lba: lba, sectors: sectors) {
                    emit(kind, lba: lba, sectors: sectors, isWrite: isWrite, cluster: cluster)
                }
                if isWrite { bytesWritten += chunk } else { bytesRead += chunk }
                offset += sectors
                remaining -= sectors
            }
            if remaining == 0 { break }
        }
    }

    // MARK: - La carte

    /// La place que prend un fichier, telle que la carte doit la montrer.
    mutating func colour(_ record: FileRecord, extents: [Extent]? = nil) {
        let category = ClusterCategory(record.category)
        let contiguous = record.extents.coalesced().count <= 1
        for extent in extents ?? record.extents where !extent.isEmpty {
            pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                category: category, contiguous: contiguous))
        }
    }

    /// Les clusters que le fichier vient de rendre.
    mutating func free(_ extents: [Extent]) {
        for extent in extents where !extent.isEmpty {
            pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                category: .free))
        }
    }

    /// Ce que la table de métadonnées — ou un répertoire — vient de prendre
    /// pour elle.
    mutating func grow(metadata extents: [Extent], as category: ClusterCategory = .reserved) {
        for extent in extents where !extent.isEmpty {
            pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                category: category))
            // Les nouveaux enregistrements sont initialisés à leur place.
            emit(.metadata, lba: partition.lba(ofCluster: Int(extent.start)),
                 sectors: min(Int(extent.length) * partition.clusterSectors, 16),
                 isWrite: true, cluster: Int(extent.start))
        }
    }

    var hasPendingMutations: Bool { !pendingMutations.isEmpty }

    // MARK: - Les tables

    /// Le fichier vient d'être créé, déplacé ou effacé : ses entrées de table
    /// sont sales.
    ///
    /// - Parameter directory: son répertoire, pour que l'entrée soit écrite là
    ///   où il est.
    mutating func markDirty(_ record: FileRecord, directory: DirectoryRecord? = nil) {
        // Sous XP, le numéro que le générateur a donné ; ailleurs, le rang
        // de création dans la session.
        let rank = record.mftRecord.map(Int.init) ?? ranks[record.id] ?? {
            let rank = 16 + ranks.count
            ranks[record.id] = rank
            return rank
        }()
        let accesses = partition.commitAccesses(for: record.extents, fileIndex: rank,
                                                entrySector: partition.entrySector(inDirectory: directory),
                                                validation: nil)
        guard usesLazyWriter else {
            for access in accesses { dirty[access.lba] = max(dirty[access.lba] ?? 0, access.sectors) }
            return
        }
        Self.dirtyNTFS(accesses, partition: partition, into: &lazy, at: clock + pendingThink)
    }

    /// Sous XP, ce qu'une validation salit, par flux : la page de 4 Ko de la
    /// MFT qui porte l'enregistrement — le premier accès —, puis les pages
    /// de `$Bitmap` (`PartitionGeometry.commitAccesses`).
    static func dirtyNTFS(_ accesses: [MetadataAccess], partition: PartitionGeometry,
                          into lazy: inout LazyWriter, at time: Double) {
        let page = LazyWriter.pageSectors
        for (index, access) in accesses.enumerated() {
            if index == 0 {
                let lba = access.lba / page * page
                lazy.dirty(.mft, rank: lba, lba: lba, at: time)
            } else {
                let base = partition.bitmapLBA
                let first = (access.lba - base) / page
                let last = (access.lba + access.sectors - 1 - base) / page
                for rank in first...last {
                    lazy.dirty(.bitmap, rank: rank, lba: base + rank * page, at: time)
                }
            }
        }
    }

    /// Sous XP, les passages du *lazy writer* échus à l'instant `time` — ou
    /// tout, à l'arrêt —, avec une page de journal devant les tables de
    /// chacun (l'ordre de grandeur du modèle d'avant : une par vidage), en
    /// arrière-plan.
    private mutating func runLazyWriter(at time: Double, shutdown: Bool = false) {
        let scans = shutdown ? [LazyWriter.Scan(time: time, streams: lazy.flushAll())]
            : lazy.due(at: time)
        for scan in scans where !scan.streams.isEmpty {
            var log: [LazyWriter.Write] = []
            if era.journaled, scan.streams.contains(where: { $0.first?.stream.isMetadata ?? false }) {
                let page = partition.logPage(journalPages)
                journalPages += 1
                log = [LazyWriter.Write(lba: page.lba, sectors: page.sectors, stream: .other(0))]
            }
            // Le passage tombe tant de secondes après la dernière requête du
            // premier plan ; l'arrêt, lui, l'attend.
            let delay = shutdown ? 0 : max(scan.time - foregroundEnd, 0)
            for write in LazyWriter.served(scan.streams, log: log, queue: &queue) {
                emitBackground(write, delay: delay, waited: shutdown)
                if write.stream.isMetadata { metadataSectors += write.sectors }
            }
            if scan.streams.contains(where: { $0.first?.stream.isMetadata ?? false }) {
                metadataFlushes += 1
            }
        }
    }

    /// L'arrêt, ou un redémarrage : tout ce que le cache tient part.
    mutating func shutdown() {
        guard usesLazyWriter else { flushMetadata(force: true); return }
        runLazyWriter(at: clock, shutdown: true)
    }

    /// Vide les tables si l'époque le veut, ou si on le force.
    ///
    /// Sous XP, rien ne force le *lazy writer* entre deux séances : seuls ses
    /// passages échus partent (`shutdown` à l'arrêt).
    mutating func flushMetadata(force: Bool = false) {
        if usesLazyWriter { runLazyWriter(at: clock + pendingThink); return }
        guard !dirty.isEmpty else { return }
        if !force, case let .every(seconds) = era.flush, clock - lastFlush < seconds { return }

        // Le cache écrit dans l'ordre du disque, et fusionne ce qui se touche.
        var runs: [(lba: Int, sectors: Int)] = []
        for lba in dirty.keys.sorted() {
            let sectors = dirty[lba] ?? 1
            if let last = runs.last, lba <= last.lba + last.sectors {
                runs[runs.count - 1].sectors = max(last.sectors, lba + sectors - last.lba)
            } else {
                runs.append((lba, sectors))
            }
        }
        dirty.removeAll(keepingCapacity: true)

        // Écriture anticipée : la page de journal part avant les tables
        // qu'elle décrit, une par vidage — c'est le *lazy writer* qui groupe.
        if era.journaled {
            let page = partition.logPage(journalPages)
            journalPages += 1
            emit(.metadata, lba: page.lba, sectors: page.sectors, isWrite: true, cluster: nil)
            metadataSectors += page.sectors
        }
        for run in runs {
            emit(.metadata, lba: run.lba, sectors: run.sectors, isWrite: true, cluster: nil)
            metadataSectors += run.sectors
        }
        metadataFlushes += 1
        lastFlush = clock
    }

    var hasDirtyMetadata: Bool { !dirty.isEmpty || !lazy.isClean }

    /// Vide les tables à chaque fichier si l'époque n'a pas de cache d'écriture.
    mutating func flushIfEveryFile() {
        flushMetadata(force: era.flush == .everyFile)
    }

    // MARK: - Sortie

    /// - Parameters:
    ///   - flow: qui attend la requête (`RequestFlow`). Au premier plan et à
    ///     une barrière, le calcul en attente part avec elle ; en arrière-plan,
    ///     `backgroundThink` est ce que l'hôte calcule pendant qu'elle se sert,
    ///     et le calcul en attente reste pour la suivante.
    mutating func emit(_ kind: DiskOperation.Kind, lba: Int, sectors: Int,
                       isWrite: Bool, cluster: Int?,
                       flow: RequestFlow = .foreground, delay: Double = 0,
                       hostWork: Double = 0) {
        // Ce que le lazy writer a écrit pendant le calcul qui précède.
        if usesLazyWriter, !flow.isBackground { runLazyWriter(at: clock + pendingThink) }
        let start = sink.mutationMark
        for mutation in pendingMutations { sink.record(mutation) }
        let count = Int32(pendingMutations.count)
        pendingMutations.removeAll(keepingCapacity: true)

        let think = flow.isBackground ? delay : pendingThink
        sink.progress = progress
        sink.moves = moves
        sink.emit(DiskOperation(kind: kind, phase: phase, lba: lba, sectors: sectors,
                                isWrite: isWrite, issueTime: 0, cluster: cluster,
                                mutationStart: start, mutationCount: count,
                                thinkTime: think, flow: flow, hostWork: hostWork))
        guard !flow.isBackground else {
            // Le fil de l'hôte n'attend pas : seul son calcul avance l'heure.
            thinkSeconds += hostWork
            clock += hostWork
            return
        }
        thinkSeconds += think
        clock += think
            + Double(sectors * DriveGeometry.bytesPerSector) / diskBytesPerSecond
            + 0.012
        foregroundEnd = clock
        pendingThink = 0
    }

    /// Une écriture du *lazy writer* : en arrière-plan, sans calcul, et sans
    /// les mutations de la carte, qui attendent l'opération du premier plan.
    ///
    /// Les couleurs en attente partent avec elle : sous XP, les données
    /// n'arrivent au disque que par le *lazy writer*.
    private mutating func emitBackground(_ write: LazyWriter.Write, delay: Double, waited: Bool) {
        let start = sink.mutationMark
        for mutation in pendingMutations { sink.record(mutation) }
        let count = Int32(pendingMutations.count)
        pendingMutations.removeAll(keepingCapacity: true)
        let data = !write.stream.isMetadata
        let offset = write.lba - partition.dataStartLBA
        sink.progress = progress
        sink.moves = moves
        sink.emit(DiskOperation(kind: data ? .writeExtent : .metadata, phase: phase,
                                lba: write.lba, sectors: write.sectors,
                                isWrite: true, issueTime: 0,
                                cluster: data && offset >= 0 ? offset / partition.clusterSectors : nil,
                                mutationStart: start, mutationCount: count,
                                thinkTime: delay, flow: waited ? .foreground : .background))
    }

    /// Une écriture d'un secteur, quand il reste des couleurs à poser mais plus
    /// rien à écrire.
    mutating func settle() {
        guard hasPendingMutations else { return }
        emit(.metadata, lba: partition.startLBA, sectors: 1, isWrite: true, cluster: nil)
    }
}
