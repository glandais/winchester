import Testing
import Foundation
@testable import DiskCore

/// Toucher un bloc de la carte dit ce qu'il contient.
@Suite("Contenu d'un bloc")
struct CellContentsTests {

    @Test("Les plages des blocs couvrent le volume sans trou ni recouvrement",
          arguments: [1, 7, 1_248, 16_808])
    func rangesTileTheVolume(cellCount: Int) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("gamer-1993"))
        var next: UInt32 = 0
        for cell in 0..<cellCount {
            let range = disk.clusterRange(ofCell: cell, cellCount: cellCount)
            #expect(range.lowerBound == next)
            next = range.upperBound
        }
        #expect(next == disk.bitmap.clusterCount)
    }

    @Test("Fichiers et système d'un bloc redonnent l'occupation du volume",
          arguments: ["gamer-1993", "gamer-2003"])
    func occupancyAddsUp(id: String) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(id))
        let cellCount = 64
        var used: UInt64 = 0
        var files = 0
        for cell in 0..<cellCount {
            let contents = disk.contents(ofCell: cell, cellCount: cellCount, limit: .max)
            #expect(contents.occupants.count == contents.fileCount)
            #expect(contents.usedClusters <= UInt32(contents.clusters.count))
            let listed = contents.occupants.reduce(UInt32(0)) { $0 + $1.clustersInCell }
            #expect(listed + contents.systemClusters == contents.usedClusters)
            used += UInt64(contents.usedClusters)
            files += contents.fileCount
        }
        #expect(used == UInt64(disk.bitmap.usedCount))
        #expect(files >= disk.catalog.files.filter { !$0.isResident && !$0.extents.isEmpty }.count)
    }

    @Test("Les fichiers listés sont les plus présents du bloc")
    func occupantsAreSorted() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("gamer-1993"))
        let contents = disk.contents(ofCell: 3, cellCount: 16, limit: 3)
        #expect(contents.occupants.count <= 3)
        let sizes = contents.occupants.map(\.clustersInCell)
        #expect(sizes == sizes.sorted(by: >))
    }
}
