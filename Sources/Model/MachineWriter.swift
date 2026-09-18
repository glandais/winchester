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
    mutating func write(_ extents: [Extent], bytes: Int, cluster kind: DiskOperation.Kind = .writeExtent,
                        sourceTime: (Int) -> Double = { _ in 0 }) {
        transfer(extents, bytes: bytes, isWrite: true, kind: kind,
                 perRequestSectors: era.writeRequestSectors, cost: sourceTime)
    }

    /// Lit le contenu d'un fichier, ou ce qu'on en touche.
    mutating func read(_ extents: [Extent], bytes: Int, cost: (Int) -> Double = { _ in 0 }) {
        transfer(extents, bytes: bytes, isWrite: false, kind: .readExtent,
                 perRequestSectors: Self.maxRequestSectors, cost: cost)
    }

    private mutating func transfer(_ extents: [Extent], bytes: Int, isWrite: Bool,
                                   kind: DiskOperation.Kind, perRequestSectors: Int,
                                   cost: (Int) -> Double) {
        guard bytes > 0 else { return }
        var remaining = partition.clusters(forBytes: bytes)
        let perRequest = UInt32(max(perRequestSectors / partition.clusterSectors, 1))
        for extent in extents {
            var offset: UInt32 = 0
            while offset < extent.length && remaining > 0 {
                let clusters = min(extent.length - offset, perRequest, UInt32(remaining))
                let sectors = Int(clusters) * partition.clusterSectors
                let chunk = min(sectors * DriveGeometry.bytesPerSector, bytes)
                think(cost(chunk))
                let cluster = Int(extent.start + offset)
                emit(kind, lba: partition.lba(ofCluster: cluster), sectors: sectors,
                     isWrite: isWrite, cluster: cluster)
                if isWrite { bytesWritten += chunk } else { bytesRead += chunk }
                offset += clusters
                remaining -= Int(clusters)
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
        let rank = ranks[record.id] ?? {
            let rank = 16 + ranks.count
            ranks[record.id] = rank
            return rank
        }()
        let clusters = record.extents.isEmpty ? [0] : record.extents.map { Int($0.start) }
        for cluster in clusters {
            for access in partition.commitAccesses(forCluster: cluster, fileIndex: rank,
                                                   entrySector: partition.entrySector(inDirectory: directory),
                                                   validation: nil) {
                dirty[access.lba] = max(dirty[access.lba] ?? 0, access.sectors)
            }
        }
    }

    /// Vide les tables si l'époque le veut, ou si on le force.
    mutating func flushMetadata(force: Bool = false) {
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

    var hasDirtyMetadata: Bool { !dirty.isEmpty }

    /// Vide les tables à chaque fichier si l'époque n'a pas de cache d'écriture.
    mutating func flushIfEveryFile() {
        flushMetadata(force: era.flush == .everyFile)
    }

    // MARK: - Sortie

    mutating func emit(_ kind: DiskOperation.Kind, lba: Int, sectors: Int,
                       isWrite: Bool, cluster: Int?) {
        let start = sink.mutationMark
        for mutation in pendingMutations { sink.record(mutation) }
        let count = Int32(pendingMutations.count)
        pendingMutations.removeAll(keepingCapacity: true)

        sink.progress = progress
        sink.moves = moves
        sink.emit(DiskOperation(kind: kind, phase: phase, lba: lba, sectors: sectors,
                                isWrite: isWrite, issueTime: 0, cluster: cluster,
                                mutationStart: start, mutationCount: count,
                                thinkTime: pendingThink))
        thinkSeconds += pendingThink
        clock += pendingThink
            + Double(sectors * DriveGeometry.bytesPerSector) / diskBytesPerSecond
            + 0.012
        pendingThink = 0
    }

    /// Une écriture d'un secteur, quand il reste des couleurs à poser mais plus
    /// rien à écrire.
    mutating func settle() {
        guard hasPendingMutations else { return }
        emit(.metadata, lba: partition.startLBA, sectors: 1, isWrite: true, cluster: nil)
    }
}
