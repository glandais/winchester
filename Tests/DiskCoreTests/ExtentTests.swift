import Testing
@testable import DiskCore

@Suite("Extent")
struct ExtentTests {

    /// L'empreinte est le point de la structure : huit octets, sinon un
    /// catalogue de 2003 ne tient pas.
    @Test("Un extent tient en huit octets")
    func size() {
        #expect(MemoryLayout<Extent>.size == 8)
        #expect(MemoryLayout<Extent>.stride == 8)
    }

    @Test("Bornes et adjacence")
    func bounds() {
        let extent = Extent(start: 100, length: 10)
        #expect(extent.end == 110)
        #expect(extent.contains(100))
        #expect(extent.contains(109))
        #expect(!extent.contains(110))
        #expect(!extent.contains(99))
        #expect(extent.isAdjacent(to: Extent(start: 110, length: 5)))
        #expect(!extent.isAdjacent(to: Extent(start: 111, length: 5)))
    }

    @Test("L'ajout cluster par cluster prolonge l'extent courant")
    func appendCluster() {
        var extents: [Extent] = []
        for cluster in UInt32(10)...UInt32(14) { extents.appendCluster(cluster) }
        #expect(extents == [Extent(start: 10, length: 5)])

        extents.appendCluster(20)
        extents.appendCluster(21)
        #expect(extents == [Extent(start: 10, length: 5), Extent(start: 20, length: 2)])
        #expect(extents.clusterCount == 7)
    }

    @Test("L'ajout de suites entières coalesce aussi")
    func appendRun() {
        var extents: [Extent] = []
        extents.appendRun(start: 0, length: 4)
        extents.appendRun(start: 4, length: 6)
        extents.appendRun(start: 0, length: 0)      // sans effet
        extents.appendRun(start: 50, length: 2)
        #expect(extents == [Extent(start: 0, length: 10), Extent(start: 50, length: 2)])
    }

    /// La coalescence ne trie pas : l'ordre d'une liste d'extents est l'ordre
    /// logique du fichier. Un fichier dont la suite a été écrite *avant* son
    /// début sur le disque est fragmenté, même si ses extents se touchent.
    @Test("La coalescence respecte l'ordre logique")
    func coalescePreservesOrder() {
        let backwards = [Extent(start: 100, length: 5), Extent(start: 10, length: 5)]
        #expect(backwards.coalesced() == backwards)

        let forwards = [Extent(start: 10, length: 5), Extent(start: 15, length: 5)]
        #expect(forwards.coalesced() == [Extent(start: 10, length: 10)])

        let withEmpty = [Extent(start: 10, length: 5),
                         Extent(start: 15, length: 0),
                         Extent(start: 15, length: 3)]
        #expect(withEmpty.coalesced() == [Extent(start: 10, length: 8)])
    }
}
