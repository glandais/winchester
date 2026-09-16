import Testing
import Foundation
@testable import DiskCore

/// Un disque rangé : les mêmes fichiers, ailleurs.
@Suite("Disque réarrangé")
struct RearrangedDiskTests {

    @Test("Réarrangé sans rien déplacer, le disque est le même", arguments: ["gamer-1993", "gamer-2003"])
    func identityKeepsEverything(id: String) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(id))
        let same = disk.rearranged(extents: [:])
        #expect(same.bitmap.usedCount == disk.bitmap.usedCount)
        #expect(same.metrics.fileCount == disk.metrics.fileCount)
        #expect(same.metrics.fragmentedFileCount == disk.metrics.fragmentedFileCount)
        #expect(same.metrics.freeRunCount == disk.metrics.freeRunCount)
        #expect(same.metrics.meanExtentsPerFile == disk.metrics.meanExtentsPerFile)
    }

    @Test("Tassé d'un seul tenant, il occupe autant et ne compte plus de fichier en morceaux")
    func packedIsContiguous() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("gamer-1993"))
        var places: [UInt32: [Extent]] = [:]
        var cursor: UInt32 = disk.systemExtents.map(\.end).max() ?? 0
        for record in disk.catalog.directoryWalkOrder() where !record.isResident {
            let length = record.extents.clusterCount
            guard length > 0 else { continue }
            places[record.id] = [Extent(start: cursor, length: length)]
            cursor += length
        }
        let packed = disk.rearranged(extents: places)
        #expect(packed.bitmap.usedCount == disk.bitmap.usedCount)
        #expect(packed.metrics.fragmentedFileCount == 0)
        #expect(packed.metrics.fileCount == disk.metrics.fileCount)
        #expect(packed.catalog.files.count == disk.catalog.files.count)
        // L'original n'a pas bougé.
        #expect(disk.metrics.fragmentedFileCount > 0)
    }
}
