import Testing
import Foundation
@testable import DiskCore

/// L'allocateur NTFS du chantier 49 (`LEDGER-XP.md`) : XP suivi à la lettre,
/// NT 4, Vista et 7 gardés tels qu'ils étaient, B#8 pour tous.
@Suite("Allocation NTFS de XP")
struct NTFSXPAllocationTests {

    /// B#8 (`AUDIT_REALISME.md`) : quand Vista ou 7 réservent une tranche
    /// neuve derrière le vierge, le milieu du volume, entre l'ancienne zone et
    /// la nouvelle, reste de l'espace de données. Les plages de données
    /// excluent la zone **courante**, pas tout ce qui la précède.
    @Test("Après une zone renouvelée, le milieu du volume reste aux données (B#8)")
    func renewedZoneKeepsTheMiddle() {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 1_000_000,
                                 formatting: .vista)
        let mftStart = ntfs.mft.extents[0].start
        #expect(mftStart == 125_000)
        // Les données de devant, puis un gros fichier derrière la zone.
        let result1 = ntfs.allocate(clusterCount: mftStart - ntfs.bootExtent.end, hint: .normal)
        #expect(result1.count == 1)
        let middle = ntfs.allocate(clusterCount: 300_000, hint: .normal)
        #expect(middle.count == 1 && middle[0].start > ntfs.mftZone.upperBound)

        // La MFT remplit ses 200 Mo : une tranche neuve est réservée derrière
        // le vierge, loin derrière le gros fichier.
        let zone = ntfs.mftZone
        while ntfs.mftZone.lowerBound == zone.lowerBound { ntfs.noteFileCreated(logicalSize: 4_096) }
        #expect(ntfs.mftZone.lowerBound > middle[0].end)

        // Tout ce qui suit la tranche neuve se remplit.
        let tail = ntfs.bitmap.clusterCount - ntfs.mftZone.upperBound
        #expect(!ntfs.allocate(clusterCount: tail, hint: .normal).isEmpty)

        // Le gros fichier disparaît : sa place, au milieu, est la première
        // reprise. Avant B#8, elle n'appartenait plus à aucune plage, et la
        // tranche neuve cédait sa queue.
        let renewed = ntfs.mftZone
        ntfs.free(middle)
        let placed = ntfs.allocate(clusterCount: 1_000, hint: .normal)
        #expect(placed.count == 1)
        #expect(placed.first.map { $0.start >= middle[0].start && $0.end <= renewed.lowerBound } == true,
                "posé en \(placed)")
        #expect(ntfs.mftZone == renewed)
    }

    /// Un volume de XP de 800 Mo, plein hors de sa zone MFT : il ne reste que
    /// les trous qu'on y perce.
    private static func fullXPVolume() -> (NTFSAllocator, Extent) {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 200_000,
                                 formatting: .xp)
        var zoneFree: UInt32 = 0
        ntfs.bitmap.forEachFreeRun { run in
            let start = max(run.start, ntfs.mftZone.lowerBound)
            let end = min(run.end, ntfs.mftZone.upperBound)
            if start < end { zoneFree += end - start }
            return true
        }
        let fill = ntfs.allocate(clusterCount: ntfs.bitmap.freeCount - zoneFree, hint: .normal)
        let largest = fill.max { $0.length < $1.length }!
        #expect(largest.length > 2_000)
        #expect(!ntfs.mftZoneBreached)
        return (ntfs, largest)
    }

    /// `NtfsLookupCachedLcnByLength` : le plus petit run assez long, et à
    /// longueur égale le plus petit LCN (« maximum left-packing »), sans
    /// tolérance ni préférence pour le vierge (`ntfs-alloc-01`, `02`, `03`).
    @Test("Un fichier neuf prend le plus petit trou qui lui suffit, le plus à gauche")
    func bestFitLeftPacked() {
        var (ntfs, room) = Self.fullXPVolume()
        let a = Extent(start: room.start + 100, length: 64)
        let b = Extent(start: room.start + 300, length: 16)
        let c = Extent(start: room.start + 500, length: 16)
        ntfs.free([c, a, b])
        ntfs.checkpoint()
        let result2 = ntfs.allocate(clusterCount: 16, hint: .normal)
        #expect(result2 == [b])
        let result3 = ntfs.allocate(clusterCount: 10, hint: .normal)
        #expect(result3 == [Extent(start: c.start, length: 10)])
        let result4 = ntfs.allocate(clusterCount: 40, hint: .normal)
        #expect(result4 == [Extent(start: a.start, length: 40)])
        // `.system` n'a pas de curseur sous XP : même règle.
        let result5 = ntfs.allocate(clusterCount: 6, hint: .system)
        #expect(result5 == [Extent(start: c.start + 10, length: 6)])
    }

    /// Sur un volume neuf, un trou libéré de 40 clusters reprend un fichier de
    /// 16 : c'est le plus petit run qui suffit. Le modèle d'avant lui
    /// préférait l'espace vierge (un trou n'était repris qu'à deux fois le
    /// besoin au plus).
    @Test("Pas de préférence pour l'espace vierge")
    func noVirginPreference() {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 2_000_000,
                                 formatting: .xp)
        let first = ntfs.allocate(clusterCount: 40, hint: .normal)
        _ = ntfs.allocate(clusterCount: 40, hint: .normal)
        ntfs.free(first)
        // Avant le point de contrôle, le trou est masqué.
        let early = ntfs.allocate(clusterCount: 16, hint: .normal)
        #expect(early.first.map { $0.start >= first[0].end } == true)
        ntfs.checkpoint()
        let result6 = ntfs.allocate(clusterCount: 16, hint: .normal)
        #expect(result6 == [Extent(start: first[0].start, length: 16)])
    }

    /// `AllowShorter` : aucun run ne suffit, le plus long est pris, et le reste
    /// va au plus petit run qui lui suffit (`ntfs-alloc-21`).
    @Test("Faute de trou assez grand, un fichier se découpe du plus grand au plus petit")
    func splitLargestFirst() {
        var (ntfs, room) = Self.fullXPVolume()
        let small = Extent(start: room.start + 100, length: 10)
        let large = Extent(start: room.start + 300, length: 30)
        let middle = Extent(start: room.start + 600, length: 20)
        ntfs.free([small, large, middle])
        ntfs.checkpoint()
        let result7 = ntfs.allocate(clusterCount: 45, hint: .normal)
        #expect(result7
                == [large, Extent(start: middle.start, length: 15)])
    }

    /// L'extension d'un fichier prend le run du cache qui commence juste
    /// derrière lui ; sinon, le plus petit run qui suffit, où qu'il soit
    /// (`ntfs-alloc-04`) — pas le vierge qui suit le fichier voisin.
    @Test("Agrandir un fichier : derrière lui s'il y a place, sinon le trou le plus juste")
    func extensionFollowsTheCache() {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 2_000_000,
                                 formatting: .xp)
        var file = FileEntry(id: 1, logicalSize: 0)
        let result8 = ntfs.extend(file: &file, byClusters: 8)
        #expect(result8)
        // Juste derrière lui : le reste du même run.
        let result9 = ntfs.extend(file: &file, byClusters: 8)
        #expect(result9)
        #expect(file.extents.count == 1 && file.extents[0].length == 16)
        // Un voisin s'installe derrière, un trou de 8 s'ouvre plus loin.
        let neighbour = ntfs.allocate(clusterCount: 100, hint: .normal)
        let spacer = ntfs.allocate(clusterCount: 8, hint: .normal)
        _ = ntfs.allocate(clusterCount: 100, hint: .normal)
        ntfs.free(spacer)
        ntfs.checkpoint()
        #expect(neighbour.first?.start == file.extents[0].end)
        let result10 = ntfs.extend(file: &file, byClusters: 8)
        #expect(result10)
        #expect(file.extents.last == spacer[0])
    }

    /// Un défragmenteur qui vise des clusters tout juste libérés ne les voit
    /// pas refusés : `STATUS_DELETE_PENDING`, le journal vidé, les clusters
    /// rendus, puis le déplacement réussit (`ntfs-alloc-15`).
    @Test("Un déplacement vers des clusters retenus les rend tous")
    func claimFlushesPendingClusters() {
        var ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 2_000_000,
                                 formatting: .xp)
        let a = ntfs.allocate(clusterCount: 40, hint: .normal)
        let b = ntfs.allocate(clusterCount: 40, hint: .normal)
        _ = ntfs.allocate(clusterCount: 40, hint: .normal)
        ntfs.free(a)
        ntfs.free(b)
        let result11 = ntfs.claim(Extent(start: a[0].start, length: 10))
        #expect(result11)
        // Tout ce qui était retenu est rendu au cache, `b` compris : `a` et
        // `b` n'y font plus qu'un run, le plus juste pour 40 clusters.
        let result12 = ntfs.allocate(clusterCount: 40, hint: .normal)
        #expect(result12 == [Extent(start: a[0].start + 10, length: 40)])
    }
}

/// Le cache des runs libres de XP (`NTFS_CACHED_RUNS`), tel que
/// `bitmpsup.c` le tient.
@Suite("Cache des runs libres de XP")
struct NTFSFreeRunCacheTests {

    /// `NtfsInsertCachedLcn` fond un run dans ceux qu'il touche, des deux
    /// côtés ; `NtfsRemoveCachedLcn` coupe en deux celui qu'il entame au
    /// milieu.
    @Test("Les runs qui se touchent se fondent, et un retrait coupe en deux")
    func mergeAndSplit() {
        var cache = NTFSFreeRunCache()
        cache.insert(Extent(start: 100, length: 10))
        cache.insert(Extent(start: 120, length: 10))
        cache.insert(Extent(start: 110, length: 10))
        #expect(cache.runs == [Extent(start: 100, length: 30)])
        cache.remove(Extent(start: 105, length: 5))
        #expect(cache.runs == [Extent(start: 100, length: 5), Extent(start: 110, length: 20)])
        cache.remove(Extent(start: 90, length: 100))
        #expect(cache.isEmpty)
    }

    /// `NtfsLookupCachedLcnByLength` : le plus petit run assez long ; à
    /// longueur égale, le plus proche de l'indice, et sans indice le plus petit
    /// LCN ; d'une longueur supérieure, le plus petit LCN sans regarder
    /// l'indice ; et faute de mieux, le plus long.
    @Test("La recherche par longueur est celle de XP")
    func lookupByLength() {
        var cache = NTFSFreeRunCache()
        for (start, length) in [(1_000, 8), (5_000, 8), (9_000, 8), (2_000, 20), (7_000, 20), (3_000, 50)] as [(UInt32, UInt32)] {
            cache.insert(Extent(start: start, length: length))
        }
        #expect(cache.lookup(length: 8, allowShorter: false, hint: nil)?.start == 1_000)
        #expect(cache.lookup(length: 8, allowShorter: false, hint: 8_000)?.start == 9_000)
        #expect(cache.lookup(length: 8, allowShorter: false, hint: 4_000)?.start == 5_000)
        // Aucun run de 10 : la longueur supérieure, par son plus petit LCN.
        #expect(cache.lookup(length: 10, allowShorter: false, hint: 7_000)?.start == 2_000)
        #expect(cache.lookup(length: 60, allowShorter: false, hint: nil) == nil)
        #expect(cache.lookup(length: 60, allowShorter: true, hint: nil) == Extent(start: 3_000, length: 50))
    }

    /// Plein à 9 000 runs, le cache ne prend un run neuf qu'en chassant un run
    /// plus court d'une longueur qu'il tient à plus de cent exemplaires
    /// (`NtfsGetCachedLengthInsertionPoint`).
    @Test("Plein, le cache chasse un petit run ou refuse")
    func fullCache() {
        var cache = NTFSFreeRunCache()
        var runs: [Extent] = []
        for index in 0..<UInt32(NTFSFreeRunCache.maximumSize) {
            // Des runs de 40 clusters, sauf 101 d'un cluster.
            runs.append(Extent(start: index * 100, length: index < 101 ? 1 : 40))
        }
        let loaded = cache.load(sortedRuns: runs)
        #expect(loaded)
        #expect(cache.isFull)
        // Un run de 30 : il chasse un run d'un cluster, le premier.
        cache.insert(Extent(start: 2_000_000, length: 30))
        #expect(cache.count == NTFSFreeRunCache.maximumSize)
        #expect(cache.run(containing: 2_000_000) != nil)
        #expect(cache.run(containing: 0) == nil)
        // Il n'en reste que cent : le suivant est refusé.
        cache.insert(Extent(start: 3_000_000, length: 30))
        #expect(cache.run(containing: 3_000_000) == nil)
    }
}
