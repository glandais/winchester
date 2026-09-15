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

    public var clusterCount: UInt32 { bitmap.clusterCount }

    /// Carte des catégories, une valeur par cluster — ce que la vue agrège pour
    /// colorier sa grille.
    public func categoryMap() -> [UInt8] {
        catalog.categoryMap(clusterCount: bitmap.clusterCount)
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
                                 mftExtents: 0)

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
                                 mftExtents: allocator.mft.extents.count)
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
