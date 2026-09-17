import Foundation

/// Un disque généré : tout ce qu'il faut pour l'afficher, le mesurer et le
/// donner à défragmenter.
public struct GeneratedDisk: Sendable {

    public var spec: ProfileSpec
    public var catalog: FileCatalog
    public var bitmap: ClusterBitmap
    public var metrics: AllocationMetrics
    public var clusterBytes: UInt32
    public var failedWrites: Int
    public var dayCount: UInt32
    /// MFT : taille et morcellement. Nul hors NTFS.
    public var mftClusters: UInt32
    public var mftExtents: Int
    /// Plage que NTFS tient à l'écart pour la croissance de la MFT, `nil` hors
    /// NTFS. Elle est libre dans la bitmap sans être disponible : qui la lit
    /// doit la traiter comme occupée.
    public var mftZone: Range<UInt32>?
    /// Ce que le système de fichiers occupe hors de tout fichier du catalogue :
    /// sur NTFS, `$Boot`, la MFT et `$MFTMirr`. Vide hors NTFS, où les tables
    /// vivent avant la zone de données.
    ///
    /// Occupé dans la bitmap, absent du catalogue : un défragmenteur qui ne
    /// regarderait que les fichiers y verrait des trous, et écrirait sur la
    /// MFT.
    public var systemExtents: [Extent] = []

    public var clusterCount: UInt32 { bitmap.clusterCount }

    /// Carte des catégories, une valeur par cluster.
    ///
    /// À n'appeler que sur les petits volumes : un disque de 320 Go en clusters
    /// de 4 Ko compte quatre-vingt-quatre millions de clusters, et cette carte
    /// ferait quatre-vingt-quatre mégaoctets. Pour l'affichage, `cells` agrège
    /// sans jamais la matérialiser.
    public func categoryMap() -> [UInt8] {
        var map = catalog.categoryMap(clusterCount: bitmap.clusterCount)
        for extent in systemExtents {
            let end = min(extent.end, bitmap.clusterCount)
            guard extent.start < end else { continue }
            for cluster in extent.start..<end { map[Int(cluster)] = FileCategory.metadata.rawValue }
        }
        return map
    }

    /// Carte agrégée en `cellCount` blocs, prête pour la grille de l'interface.
    ///
    /// Chaque bloc prend la catégorie la plus représentée parmi ses clusters
    /// **occupés** : un bloc qui contient ne serait-ce qu'un fichier n'a pas
    /// l'air vide, comme sur la carte du défragmenteur d'origine. L'agrégation
    /// se fait en parcourant les extents du catalogue, jamais en construisant
    /// la carte complète — c'est ce qui permet d'afficher un volume de 320 Go
    /// sans allouer quatre-vingt-quatre mégaoctets.
    public func cells(count cellCount: Int, free: UInt8 = .max) -> [UInt8] {
        shaded(count: cellCount, free: free).categories
    }

    /// La même agrégation, mais qui rend aussi **le taux d'occupation** de
    /// chaque bloc.
    ///
    /// C'est ce que le plein écran demande : à 17 000 blocs sur un volume de
    /// 320 Go, un bloc vaut encore des milliers de clusters, et la seule
    /// catégorie dominante ferait passer pour plein un bloc rempli au quart.
    /// Le décompte est déjà là — il ne manquait que son total — donc le taux
    /// ne coûte rien de plus qu'une division par bloc.
    ///
    /// - Returns: la catégorie dominante de chaque bloc, et sa part de clusters
    ///   occupés ramenée à 0…255. Un octet plutôt qu'un `Double` : on en garde
    ///   un par bloc, et l'œil ne distingue pas le deux-centcinquantième.
    ///   Le troisième tableau dit si la catégorie dominante est surtout portée
    ///   par des fichiers d'un seul tenant.
    public func shaded(count cellCount: Int,
                       free: UInt8 = .max) -> (categories: [UInt8], fill: [UInt8], contiguous: [Bool]) {
        ClusterShading.shaded(catalog: catalog, systemExtents: systemExtents,
                              clusterCount: bitmap.clusterCount, cellCount: cellCount, free: free)
    }
}

/// L'agrégation d'un volume en blocs d'affichage.
///
/// Le disque généré n'est pas seul à la demander : le défilement de la vie d'un
/// disque en veut une par journée, sans construire de disque. D'où la
/// séparation — mêmes décomptes, deux appelants.
public enum ClusterShading {

    /// - Returns: la catégorie dominante de chaque bloc, sa part de clusters
    ///   occupés ramenée à 0…255, et si cette catégorie est surtout portée par
    ///   des fichiers d'un seul tenant.
    public static func shaded(catalog: FileCatalog, systemExtents: [Extent],
                              clusterCount: UInt32, cellCount: Int,
                              free: UInt8 = .max) -> (categories: [UInt8], fill: [UInt8], contiguous: [Bool]) {
        precondition(cellCount > 0)
        let categoryCount = FileCategory.allCases.count
        var tally = [UInt32](repeating: 0, count: cellCount * categoryCount)
        // Les clusters de chaque catégorie qui appartiennent à un fichier d'un
        // seul tenant, sous-ensemble du décompte ci-dessus.
        var contiguousTally = [UInt32](repeating: 0, count: cellCount * categoryCount)
        let partition = CellPartition(clusterCount: Int(clusterCount), cellCount: cellCount)

        func count(_ extents: [Extent], as category: Int, contiguous: Bool = false) {
            for extent in extents where !extent.isEmpty {
                let start = Int(extent.start)
                let end = Int(extent.end)
                guard start < partition.clusterCount else { continue }
                let first = partition.cell(ofCluster: start)
                let last = partition.cell(ofCluster: end - 1)
                for cell in first...last {
                    // Part de l'extent qui tombe dans cette cellule.
                    let clusters = partition.clusters(ofCell: cell)
                    let overlap = min(clusters.upperBound, end) - max(clusters.lowerBound, start)
                    guard overlap > 0 else { continue }
                    let share = UInt32(overlap)
                    tally[cell * categoryCount + category] += share
                    if contiguous { contiguousTally[cell * categoryCount + category] += share }
                }
            }
        }

        // La MFT et ses voisins ne sont décrits par aucun fichier du
        // catalogue : sans cette ligne, la carte les montrait libres alors que
        // la bitmap les tient occupés. Ils prennent la couleur des
        // métadonnées, celle des tables FAT.
        count(systemExtents, as: Int(FileCategory.metadata.rawValue))
        for record in catalog.files where !record.isResident {
            count(record.extents, as: Int(record.category.rawValue),
                  contiguous: record.extents.coalesced().count <= 1)
        }

        var result = [UInt8](repeating: free, count: cellCount)
        var fill = [UInt8](repeating: 0, count: cellCount)
        var contiguous = [Bool](repeating: false, count: cellCount)
        for cell in 0..<cellCount {
            var best = -1
            var bestCount: UInt32 = 0
            var occupied: UInt32 = 0
            for category in 0..<categoryCount {
                let value = tally[cell * categoryCount + category]
                occupied += value
                if value > bestCount { bestCount = value; best = category }
            }
            if best >= 0 {
                result[cell] = UInt8(best)
                contiguous[cell] = contiguousTally[cell * categoryCount + best] * 2 > bestCount
            }
            // Le décompte est exact, mais deux extents peuvent se recouvrir
            // (la MFT et un fichier qui la décrit) : la borne évite un bloc
            // « plus que plein ». Un bloc au-delà du volume ne porte rien.
            let capacity = partition.clusters(ofCell: cell).count
            let ratio = capacity > 0 ? Double(occupied) / Double(capacity) : 0
            fill[cell] = UInt8(min(max(ratio, 0), 1) * 255)
        }
        return (result, fill, contiguous)
    }
}

/// Fabrique un disque à partir d'une description déclarative.
///
/// C'est le point d'entrée de tout le lot : une spécification entre, un volume
/// vieilli sort. Entre les deux, une histoire est écrite puis rejouée à travers
/// l'allocateur du format demandé, et la fragmentation tombe toute seule.
public enum DiskGenerator {

    /// - Parameter onProgress: rapport d'avancement, appelé à intervalles
    ///   réguliers depuis le fil qui exécute la génération.
    /// - Throws: `CancellationError` si la tâche est annulée.
    public static func generate(_ spec: ProfileSpec,
                                manifests: [AppManifest] = AppLibrary.all,
                                logger: GenerationLogger = SilentLogger(),
                                onProgress: ((GenerationProgress) -> Void)? = nil) throws -> GeneratedDisk {
        let compiled = ScenarioCompiler.compile(spec, manifests: manifests)
        logger.log("\(spec.id) : \(compiled.timeline.count) événements sur \(spec.timeline.dayCount) jours")

        switch spec.fileSystem.type {
        case .fat16, .vfat, .fat32:
            var simulator = Simulator(allocator: fatAllocator(for: spec),
                                      catalog: compiled.catalog,
                                      logger: logger)
            let outcome = try simulator.run(compiled.timeline, onProgress: onProgress)
            return disk(spec: spec, allocator: simulator.allocator, catalog: outcome.catalog,
                        metrics: outcome.metrics, failedWrites: outcome.failedWrites,
                        dayCount: outcome.dayCount)

        case .ntfs:
            var simulator = Simulator(allocator: ntfsAllocator(for: spec),
                                      catalog: compiled.catalog,
                                      logger: logger)
            let outcome = try simulator.run(compiled.timeline, onProgress: onProgress)
            return disk(spec: spec, allocator: simulator.allocator, catalog: outcome.catalog,
                        metrics: outcome.metrics, failedWrites: outcome.failedWrites,
                        dayCount: outcome.dayCount)
        }
    }

    // MARK: - Installation

    /// Le disque au soir de l'installation, et comment il y est arrivé.
    ///
    /// La même histoire que `generate`, arrêtée à la fin du jour 0 et rejouée
    /// pas à pas : chaque création et chaque effacement est consigné avec les
    /// clusters que l'allocateur a donnés ou repris. C'est le même compilateur,
    /// les mêmes tirages et le même allocateur — le disque qui en sort est donc
    /// exactement celui dont la galerie montre la version vieillie.
    public static func install(_ spec: ProfileSpec,
                               manifests: [AppManifest] = AppLibrary.all) throws -> InstalledDisk {
        let replay = HistoryReplay(spec, manifests: manifests)

        var stepOfFile: [UInt32: Int] = [:]
        for (index, step) in replay.installSteps.enumerated() {
            for id in step.temporaryIDs { stepOfFile[id] = index }
            for id in step.fileIDs { stepOfFile[id] = index }
        }

        var journal: [InstallEntry] = []
        var currentStep = -1
        var played = 0

        func enter(_ id: UInt32) {
            guard let step = stepOfFile[id], step > currentStep else { return }
            // Une étape sans fichier — un fichier d'échange que ce format pose
            // plus tard — n'en garde pas moins sa place dans la suite.
            for skipped in (currentStep + 1)...step { journal.append(.begin(step: skipped)) }
            currentStep = step
        }

        // Une passe de défragmentation datée du premier jour n'appartient pas
        // à l'installation : elle ne commence qu'une fois Windows posé. On
        // s'arrête donc avant elle, en regardant l'événement avant de le jouer.
        while let next = replay.peek, next.day == 0 {
            if case .defragment = next.event { break }
            if played & 0x1FF == 0 { try Task.checkCancellation() }
            switch next.event {
            case let .create(file): enter(file.id)
            case let .delete(id):   enter(id)
            default: break
            }
            var step = SimulationStep()
            replay.play(day: 0) { _, result in
                step = result
                return false
            }
            played += 1
            if !step.metadataGrew.isEmpty { journal.append(.metadataGrew(step.metadataGrew)) }
            if let created = step.created { journal.append(.created(created)) }
            if let deleted = step.deleted { journal.append(.deleted(deleted)) }
        }
        if currentStep + 1 < replay.installSteps.count {
            for skipped in (currentStep + 1)..<replay.installSteps.count {
                journal.append(.begin(step: skipped))
            }
        }

        var disk = replay.snapshot()
        disk.dayCount = 1
        return InstalledDisk(disk: disk,
                             steps: replay.installSteps,
                             journal: journal,
                             initialSystemExtents: replay.initialSystemExtents)
    }

    // MARK: - Allocateurs

    static func fatAllocator(for spec: ProfileSpec) -> FATAllocator {
        let scan: FATAllocator.Scan = spec.fileSystem.type == .fat16
            ? .fromVolumeStart
            : .fromLastAllocated
        return FATAllocator(profile: spec.resolvedFileSystem(),
                            clusterCount: spec.clusterCount,
                            scan: scan)
    }

    static func ntfsAllocator(for spec: ProfileSpec) -> NTFSAllocator {
        // `$MFTMirr` est au milieu du volume jusqu'à Windows 2000, ramené
        // près du début ensuite : un aller-retour de moins par écriture de
        // métadonnées, et ça s'entend.
        let mirror: NTFSAllocator.MirrorPlacement =
            spec.timeline.start.year >= 2001 ? .nearStart : .volumeMiddle
        return NTFSAllocator(profile: NTFSProfile(clusterKB: spec.fileSystem.clusterKB ?? 4),
                             clusterCount: spec.clusterCount,
                             mirrorPlacement: mirror)
    }

    /// Le disque que décrit un simulateur en cours de rejeu.
    static func disk<A: GeneratorAllocator>(spec: ProfileSpec, simulator: Simulator<A>,
                                            failedWrites: Int, dayCount: UInt32) -> GeneratedDisk {
        let allocator = simulator.allocator
        let metrics = AllocationMetrics.evaluate(files: simulator.catalog.files.map(\.entry),
                                                 bitmap: allocator.bitmap,
                                                 profile: allocator.profile)
        return disk(spec: spec, allocator: allocator, catalog: simulator.catalog, metrics: metrics,
                    failedWrites: failedWrites, dayCount: dayCount)
    }

    private static func disk<A: GeneratorAllocator>(spec: ProfileSpec, allocator: A,
                                                    catalog: FileCatalog, metrics: AllocationMetrics,
                                                    failedWrites: Int, dayCount: UInt32) -> GeneratedDisk {
        GeneratedDisk(spec: spec,
                      catalog: catalog,
                      bitmap: allocator.bitmap,
                      metrics: metrics,
                      clusterBytes: allocator.profile.clusterBytes,
                      failedWrites: failedWrites,
                      dayCount: dayCount,
                      mftClusters: allocator.generatedMFT.clusters,
                      mftExtents: allocator.generatedMFT.extents,
                      mftZone: allocator.generatedMFT.zone,
                      systemExtents: allocator.generatedMFT.system)
    }

    /// Version asynchrone, annulable, qui publie son avancement.
    ///
    /// Le travail part sur un fil détaché : générer un volume de 2007 prend
    /// plus d'une image d'affichage, et le fil principal a autre chose à faire.
    public static func generate(_ spec: ProfileSpec,
                                manifests: [AppManifest] = AppLibrary.all,
                                logger: GenerationLogger = SilentLogger(),
                                progress: @Sendable @escaping (GenerationProgress) -> Void = { _ in })
        async throws -> GeneratedDisk {
        try await Task.detached(priority: .userInitiated) {
            try generate(spec, manifests: manifests, logger: logger) { progress($0) }
        }.value
    }
}

/// Ce que le générateur lit d'un allocateur pour décrire le disque qu'il a
/// produit.
protocol GeneratorAllocator: Allocator {
    var generatedMFT: (clusters: UInt32, extents: Int, zone: Range<UInt32>?, system: [Extent]) { get }
}

extension FATAllocator: GeneratorAllocator {
    var generatedMFT: (clusters: UInt32, extents: Int, zone: Range<UInt32>?, system: [Extent]) {
        (0, 0, nil, [])
    }
}

extension NTFSAllocator: GeneratorAllocator {
    var generatedMFT: (clusters: UInt32, extents: Int, zone: Range<UInt32>?, system: [Extent]) {
        (mft.clusterCount, mft.extents.count, mftZone, systemExtents)
    }
}
