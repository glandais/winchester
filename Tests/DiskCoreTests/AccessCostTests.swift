import Testing
@testable import DiskCore

@Suite("Coût d'accès")
struct AccessCostTests {

    private static let cost = AccessCost(
        geometry: .win95Drive,
        seekModel: .win95Model,
        addressing: ClusterAddressing(dataStartLBA: 600, sectorsPerCluster: 8)
    )

    /// L'effet ZBR n'est pas postulé, il tombe de la table des zones : la piste
    /// extérieure porte 256 secteurs contre 172 au moyeu. C'est lui qui justifie
    /// qu'un défragmenteur remonte les fichiers de démarrage en tête de volume.
    @Test("Le débit décroît du bord vers le moyeu")
    func zonedThroughput() {
        let outer = Self.cost.throughput(atCylinder: 0)
        let inner = Self.cost.throughput(atCylinder: 1_999)
        #expect(outer > inner)
        #expect(outer / inner > 1.4)
        #expect(outer / inner < 1.6)
        // 256 secteurs × 512 o par tour de 13,3 ms : autour de 9,8 Mo/s.
        #expect(outer > 9_000_000)
        #expect(outer < 10_500_000)
    }

    @Test("La latence rotationnelle est un demi-tour")
    func rotationalLatency() {
        #expect(abs(Self.cost.averageRotationalLatency - 60.0 / 4_500 / 2) < 1e-9)
    }

    @Test("Une lecture vide ne coûte rien")
    func emptyRead() {
        #expect(Self.cost.readTime(extents: []) == 0)
    }

    /// Le cœur du modèle : à taille égale, un fichier éclaté coûte plus cher
    /// qu'un fichier contigu, et l'écart vient des demi-tours payés à chaque
    /// fragment bien plus que des seeks eux-mêmes.
    @Test("La fragmentation coûte du temps de lecture")
    func fragmentationCosts() {
        let contiguous = [Extent(start: 1_000, length: 256)]
        var scattered: [Extent] = []
        for i in UInt32(0)..<32 {
            scattered.append(Extent(start: 1_000 + i * 900, length: 8))
        }
        #expect(scattered.clusterCount == contiguous.clusterCount)

        let fast = Self.cost.readTime(extents: contiguous)
        let slow = Self.cost.readTime(extents: scattered)
        // Le transfert est le même de part et d'autre : tout l'écart vient des
        // 32 demi-tours et des 32 seeks. Un mégaoctet contigu se lit en 0,14 s,
        // le même en 32 morceaux en 0,45 s.
        #expect(slow > fast * 3)
    }

    @Test("Le temps de référence contigu sert d'étalon")
    func contiguousBaseline() {
        let scattered = (UInt32(0)..<16).map { Extent(start: 500 + $0 * 700, length: 16) }
        let actual = Self.cost.readTime(extents: scattered)
        let ideal = Self.cost.contiguousReadTime(extents: scattered)
        #expect(ideal < actual)
        // L'étalon porte bien la même quantité de données.
        #expect(scattered.clusterCount == 256)
    }

    /// Deux fragments voisins coûtent presque autant que deux fragments
    /// éloignés : c'est contre-intuitif mais c'est le modèle mécanique qui le
    /// dit, la latence rotationnelle dominant le seek court.
    @Test("La latence domine le seek sur les fragments proches")
    func rotationDominatesShortSeeks() {
        let near = [Extent(start: 1_000, length: 4), Extent(start: 1_010, length: 4)]
        let far  = [Extent(start: 1_000, length: 4), Extent(start: 40_000, length: 4)]
        let nearTime = Self.cost.readTime(extents: near)
        let farTime = Self.cost.readTime(extents: far)
        #expect(farTime > nearTime)
        #expect(farTime < nearTime * 3)
    }

    @Test("Le transfert suit la taille demandée")
    func transferScales() {
        let one = Self.cost.transferTime(startLBA: 10_000, sectors: 64)
        let four = Self.cost.transferTime(startLBA: 10_000, sectors: 256)
        // Un peu plus que le quadruple : 256 secteurs débordent de la piste, et
        // chaque commutation de tête coûte 2 ms sur ce disque.
        #expect(four > one * 4)
        #expect(four < one * 5.5)
        #expect(Self.cost.transferTime(startLBA: 10_000, sectors: 0) == 0)
    }

    @Test("La distance de seek se mesure en cylindres")
    func seekDistance() {
        #expect(Self.cost.seekDistance(from: 100, to: 100) == 0)
        let far = Self.cost.seekDistance(from: 0, to: 40_000)
        #expect(far > 0)
        #expect(far < DriveGeometry.win95Drive.cylinders)
    }

    @Test("L'adressage des clusters est celui de la partition")
    func addressing() {
        let addressing = ClusterAddressing(dataStartLBA: 600, sectorsPerCluster: 8)
        #expect(addressing.lba(ofCluster: 0) == 600)
        #expect(addressing.lba(ofCluster: 10) == 680)
        #expect(addressing.clusterBytes == 4_096)
        #expect(addressing.sectors(forClusters: 3) == 24)
    }
}
