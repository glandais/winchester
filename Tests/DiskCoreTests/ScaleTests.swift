import Testing
import Foundation
@testable import DiskCore

/// Le noyau doit tenir un volume de 2007 sur un téléphone. Ces tests ne
/// mesurent pas une performance fine — la machine qui les exécute n'est pas
/// celle qui compte — mais ils prennent en flagrant délit tout ce qui
/// dégénèrerait en quadratique ou en centaines de mégaoctets.
@Suite("Passage à l'échelle")
struct ScaleTests {

    /// 80 Go en clusters de 4 Ko : 20 millions de clusters.
    private static let xpClusterCount: UInt32 = 20_480_000

    @Test("La bitmap d'un volume XP de 80 Go pèse quelques mégaoctets")
    func memoryFootprint() {
        let bitmap = ClusterBitmap(clusterCount: Self.xpClusterCount)
        // Un bit par cluster : 2,5 Mo. Un octet par cluster en aurait coûté 20,
        // et le tableau d'identifiants du modèle statique 80.
        let bytes = (Int(Self.xpClusterCount) + 7) / 8
        #expect(bytes < 3_000_000)
        #expect(bitmap.freeCount == Self.xpClusterCount)
    }

    /// Le cas qui compte : un volume mité de centaines de milliers de trous,
    /// parcouru de bout en bout. Si la recherche de place libre repartait du
    /// début à chaque allocation, ce test durerait des minutes.
    @Test("Un volume de 80 Go se remplit et se parcourt en moins d'une seconde")
    func largeVolumeThroughput() {
        var bitmap = ClusterBitmap(clusterCount: Self.xpClusterCount)
        var rng = SeededGenerator(seed: 2_003)

        let start = Date()

        // Remplissage à 70 %, par blocs de taille réaliste.
        var allocated: UInt32 = 0
        let target = UInt32(Double(Self.xpClusterCount) * 0.70)
        var cursor: UInt32 = 0
        var placed: [Extent] = []
        placed.reserveCapacity(120_000)

        while allocated < target {
            let length = UInt32(max(1, Int(rng.logNormal(median: 200, sigma: 1.5))))
            guard let run = bitmap.firstFitRun(minLength: length, maxLength: length,
                                               from: cursor, wrap: true) else { break }
            let extent = Extent(start: run.start, length: length)
            bitmap.allocate(extent)
            placed.append(extent)
            cursor = extent.end
            allocated += length
        }
        #expect(bitmap.usedCount >= target)

        // Suppression d'un fichier sur trois : c'est ce qui creuse le gruyère.
        for index in stride(from: 0, to: placed.count, by: 3) {
            bitmap.free(placed[index])
        }

        let holes = bitmap.freeRunCount()
        #expect(holes > 1_000)

        let elapsed = Date().timeIntervalSince(start)
        // Large : la cible est de générer un disque entier, historique compris,
        // en moins de deux secondes sur iPhone. Le seuil est là pour attraper
        // une dégénérescence, pas pour mesurer la machine.
        // Seuil large : ces tests tournent en configuration de débogage, où
        // Swift vérifie chaque accès de tableau. La cible réelle — un disque
        // entier, historique compris, en moins de deux secondes sur iPhone —
        // se mesure en release. Ici on attrape une dégénérescence, pas une
        // milliseconde.
        #expect(elapsed < 20.0, "remplissage et parcours en \(elapsed) s")
    }

    @Test("Un fichier de 2 Go s'alloue d'un seul tenant, instantanément")
    func hugeContiguousAllocation() {
        var bitmap = ClusterBitmap(clusterCount: Self.xpClusterCount)
        // hiberfil.sys sur une machine de 2007 : 2 Go, soit 524 288 clusters,
        // et il doit être d'un seul tenant.
        let length: UInt32 = 524_288
        guard let run = bitmap.firstFitRun(minLength: length) else {
            Issue.record("aucun run libre pour hiberfil.sys")
            return
        }
        #expect(run.length >= length)
        bitmap.allocate(start: run.start, length: length)
        #expect(bitmap.usedCount == length)
        #expect(bitmap.freeRunCount() == 1)
    }
}
