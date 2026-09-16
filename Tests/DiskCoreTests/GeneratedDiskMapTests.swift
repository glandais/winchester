import Testing
import Foundation
@testable import DiskCore

/// Ce que la galerie montre d'un disque généré.
///
/// Sur NTFS, `$Boot`, la MFT et `$MFTMirr` occupent la bitmap sans qu'aucun
/// fichier du catalogue ne les décrive. Une carte qui ne lirait que le
/// catalogue les peindrait libres.
@Suite("Carte d'un disque généré")
struct GeneratedDiskMapTests {

    /// Un disque sans un seul fichier, dont seule la MFT occupe la place.
    private static func disk(clusterCount: UInt32, systemExtents: [Extent]) throws -> GeneratedDisk {
        var bitmap = ClusterBitmap(clusterCount: clusterCount)
        for extent in systemExtents { bitmap.allocate(extent) }
        let profile = NTFSProfile(clusterKB: 4)
        return GeneratedDisk(spec: try ScenarioLibrary.load("gamer-2003"),
                             catalog: FileCatalog(),
                             bitmap: bitmap,
                             metrics: AllocationMetrics.evaluate(files: [], bitmap: bitmap, profile: profile),
                             clusterBytes: profile.clusterBytes,
                             failedWrites: 0,
                             dayCount: 0,
                             mftClusters: systemExtents.reduce(0) { $0 + $1.length },
                             mftExtents: systemExtents.count,
                             mftZone: 0..<0,
                             systemExtents: systemExtents)
    }

    @Test("La MFT se voit sur la carte, en métadonnées")
    func mftIsShown() throws {
        let mft = [Extent(start: 0, length: 1), Extent(start: 1, length: 99), Extent(start: 500, length: 4)]
        let disk = try Self.disk(clusterCount: 1_000, systemExtents: mft)
        let metadata = FileCategory.metadata.rawValue

        let (categories, fill) = disk.shaded(count: 10)
        #expect(categories[0] == metadata)
        #expect(fill[0] == 255, "les cent premiers clusters sont tous à la MFT")
        #expect(categories[5] == metadata)
        #expect(categories[3] == .max, "un bloc sans MFT reste libre")

        let map = disk.categoryMap()
        #expect(map.filter { $0 == metadata }.count == 104)
    }
}
