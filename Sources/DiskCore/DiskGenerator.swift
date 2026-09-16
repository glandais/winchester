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
    public func shaded(count cellCount: Int, free: UInt8 = .max) -> (categories: [UInt8], fill: [UInt8]) {
        precondition(cellCount > 0)
        let categoryCount = FileCategory.allCases.count
        var tally = [UInt32](repeating: 0, count: cellCount * categoryCount)
        let clustersPerCell = max(Double(bitmap.clusterCount) / Double(cellCount), 1)

        func count(_ extents: [Extent], as category: Int) {
            for extent in extents where !extent.isEmpty {
                let first = Int(Double(extent.start) / clustersPerCell)
                let last = Int(Double(extent.end - 1) / clustersPerCell)
                guard first < cellCount else { continue }
                for cell in first...min(last, cellCount - 1) {
                    // Part de l'extent qui tombe dans cette cellule.
                    let cellStart = Double(cell) * clustersPerCell
                    let overlap = min(Double(extent.end), cellStart + clustersPerCell)
                        - max(Double(extent.start), cellStart)
                    tally[cell * categoryCount + category] += UInt32(max(overlap, 1))
                }
            }
        }

        // La MFT et ses voisins ne sont décrits par aucun fichier du
        // catalogue : sans cette ligne, la carte les montrait libres alors que
        // la bitmap les tient occupés. Ils prennent la couleur des
        // métadonnées, celle des tables FAT.
        count(systemExtents, as: Int(FileCategory.metadata.rawValue))
        for record in catalog.files where !record.isResident {
            count(record.extents, as: Int(record.category.rawValue))
        }

        var result = [UInt8](repeating: free, count: cellCount)
        var fill = [UInt8](repeating: 0, count: cellCount)
        for cell in 0..<cellCount {
            var best = -1
            var bestCount: UInt32 = 0
            var occupied: UInt32 = 0
            for category in 0..<categoryCount {
                let value = tally[cell * categoryCount + category]
                occupied += value
                if value > bestCount { bestCount = value; best = category }
            }
            if best >= 0 { result[cell] = UInt8(best) }
            // Le décompte majore d'un cluster les extents qui n'effleurent la
            // cellule que d'une fraction ; la borne à 255 évite qu'un bloc
            // débordé se retrouve « plus que plein ».
            let ratio = Double(occupied) / clustersPerCell
            fill[cell] = UInt8(min(max(ratio, 0), 1) * 255)
        }
        return (result, fill)
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

        let clusterCount = spec.clusterCount

        switch spec.fileSystem.type {
        case .fat16, .vfat, .fat32:
            let profile = spec.resolvedFileSystem()
            let scan: FATAllocator.Scan = spec.fileSystem.type == .fat16
                ? .fromVolumeStart
                : .fromLastAllocated
            var simulator = Simulator(allocator: FATAllocator(profile: profile,
                                                              clusterCount: clusterCount,
                                                              scan: scan),
                                      catalog: compiled.catalog,
                                      logger: logger)
            let outcome = try simulator.run(compiled.timeline, onProgress: onProgress)
            return GeneratedDisk(spec: spec,
                                 catalog: outcome.catalog,
                                 bitmap: simulator.allocator.bitmap,
                                 metrics: outcome.metrics,
                                 clusterBytes: profile.clusterBytes,
                                 failedWrites: outcome.failedWrites,
                                 dayCount: outcome.dayCount,
                                 mftClusters: 0,
                                 mftExtents: 0,
                                 mftZone: nil,
                                 systemExtents: [])

        case .ntfs:
            let profile = NTFSProfile(clusterKB: spec.fileSystem.clusterKB ?? 4)
            // `$MFTMirr` est au milieu du volume jusqu'à Windows 2000, ramené
            // près du début ensuite : un aller-retour de moins par écriture de
            // métadonnées, et ça s'entend.
            let mirror: NTFSAllocator.MirrorPlacement =
                spec.timeline.start.year >= 2001 ? .nearStart : .volumeMiddle
            var simulator = Simulator(allocator: NTFSAllocator(profile: profile,
                                                               clusterCount: clusterCount,
                                                               mirrorPlacement: mirror),
                                      catalog: compiled.catalog,
                                      logger: logger)
            let outcome = try simulator.run(compiled.timeline, onProgress: onProgress)
            let allocator = simulator.allocator
            return GeneratedDisk(spec: spec,
                                 catalog: outcome.catalog,
                                 bitmap: allocator.bitmap,
                                 metrics: outcome.metrics,
                                 clusterBytes: profile.clusterBytes,
                                 failedWrites: outcome.failedWrites,
                                 dayCount: outcome.dayCount,
                                 mftClusters: allocator.mft.clusterCount,
                                 mftExtents: allocator.mft.extents.count,
                                 mftZone: allocator.mftZone,
                                 systemExtents: allocator.systemExtents)
        }
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
