import Testing
@testable import DiskCore

@Suite("ClusterBitmap")
struct ClusterBitmapTests {

    @Test("Un volume neuf est entièrement libre")
    func emptyVolume() {
        let bitmap = ClusterBitmap(clusterCount: 1_000)
        #expect(bitmap.freeCount == 1_000)
        #expect(bitmap.usedCount == 0)
        #expect(bitmap.fill == 0)
        #expect(bitmap.largestFreeRun() == Extent(start: 0, length: 1_000))
        #expect(bitmap.freeRunCount() == 1)
    }

    /// Le bourrage du dernier mot est la source d'erreur la plus probable de
    /// toute la structure : un volume dont la taille n'est pas un multiple de
    /// 64 ne doit jamais rendre un cluster qui n'existe pas.
    @Test("Le bourrage du dernier mot n'est jamais rendu comme libre",
          arguments: [1, 63, 64, 65, 127, 128, 129, 4_095, 10_501] as [UInt32])
    func paddingIsNeverFree(clusterCount: UInt32) {
        let bitmap = ClusterBitmap(clusterCount: clusterCount)
        #expect(bitmap.freeCount == clusterCount)
        #expect(bitmap.largestFreeRun() == Extent(start: 0, length: clusterCount))
        #expect(bitmap.nextFreeCluster(from: clusterCount - 1) == clusterCount - 1)
        #expect(bitmap.freeRunLength(at: 0) == clusterCount)
        #expect(bitmap.firstFitRun(minLength: clusterCount) != nil)
        #expect(bitmap.firstFitRun(minLength: clusterCount + 1) == nil)
    }

    @Test("Allocation et libération d'une plage à cheval sur plusieurs mots")
    func allocateAcrossWords() {
        var bitmap = ClusterBitmap(clusterCount: 300)
        #expect(bitmap.allocate(start: 60, length: 80) == 80)
        #expect(bitmap.freeCount == 220)
        #expect(bitmap.isAllocated(60))
        #expect(bitmap.isAllocated(139))
        #expect(bitmap.isFree(59))
        #expect(bitmap.isFree(140))
        #expect(bitmap.freeRunLength(at: 0) == 60)
        #expect(bitmap.freeRunLength(at: 140) == 160)
        #expect(bitmap.freeRunCount() == 2)

        #expect(bitmap.free(start: 60, length: 80) == 80)
        #expect(bitmap.freeCount == 300)
        #expect(bitmap.freeRunCount() == 1)
    }

    /// Réallouer un cluster déjà pris ne doit pas être compté deux fois, sinon
    /// le compteur de place libre dérive en silence et le volume se croit plein
    /// bien avant de l'être.
    @Test("Une allocation redondante ne change pas le compte")
    func idempotentAllocation() {
        var bitmap = ClusterBitmap(clusterCount: 100)
        #expect(bitmap.allocate(start: 10, length: 10) == 10)
        #expect(bitmap.allocate(start: 15, length: 10) == 5)
        #expect(bitmap.usedCount == 15)
        #expect(bitmap.free(start: 0, length: 100) == 15)
        #expect(bitmap.usedCount == 0)
    }

    @Test("First-fit rebouche le premier trou venu")
    func firstFit() {
        var bitmap = ClusterBitmap(clusterCount: 200)
        bitmap.allocate(start: 0, length: 200)
        bitmap.free(start: 10, length: 4)     // petit trou, tôt
        bitmap.free(start: 100, length: 40)   // grand trou, tard

        #expect(bitmap.firstFitRun(minLength: 3) == Extent(start: 10, length: 4))
        #expect(bitmap.firstFitRun(minLength: 4) == Extent(start: 10, length: 4))
        #expect(bitmap.firstFitRun(minLength: 5) == Extent(start: 100, length: 40))
        #expect(bitmap.firstFitRun(minLength: 41) == nil)
    }

    /// Le retour au début après la fin du volume : c'est le hint `next-free` de
    /// FSINFO, et la raison pour laquelle un FAT32 fragmente par vagues.
    @Test("First-fit avec retour au début")
    func firstFitWrap() {
        var bitmap = ClusterBitmap(clusterCount: 200)
        bitmap.allocate(start: 0, length: 200)
        bitmap.free(start: 5, length: 10)

        #expect(bitmap.firstFitRun(minLength: 4, from: 100, wrap: false) == nil)
        #expect(bitmap.firstFitRun(minLength: 4, from: 100, wrap: true) == Extent(start: 5, length: 10))
        // Le hint peut dépasser la fin du volume : il repart alors de zéro.
        #expect(bitmap.firstFitRun(minLength: 4, from: 500, wrap: true) == Extent(start: 5, length: 10))
        #expect(bitmap.firstFitRun(minLength: 4, from: 500, wrap: false) == nil)
    }

    @Test("Best-fit choisit le plus petit trou suffisant")
    func bestFit() {
        var bitmap = ClusterBitmap(clusterCount: 400)
        bitmap.allocate(start: 0, length: 400)
        bitmap.free(start: 10, length: 50)    // grand
        bitmap.free(start: 100, length: 12)   // juste ce qu'il faut
        bitmap.free(start: 200, length: 30)   // moyen
        bitmap.free(start: 300, length: 5)    // trop petit

        #expect(bitmap.bestFitRun(minLength: 12) == Extent(start: 100, length: 12))
        #expect(bitmap.bestFitRun(minLength: 13) == Extent(start: 200, length: 30))
        #expect(bitmap.bestFitRun(minLength: 31) == Extent(start: 10, length: 50))
        #expect(bitmap.bestFitRun(minLength: 51) == nil)

        // Avec un plafond de mesure, un trou plus grand que le plafond est rendu
        // à cette taille-là : l'appelant a dit qu'au-delà ils ne l'intéressaient
        // plus.
        #expect(bitmap.bestFitRun(minLength: 12, measureLimit: 20)?.length == 12)
        #expect(bitmap.bestFitRun(minLength: 31, measureLimit: 35)?.length == 35)

        // À égalité de taille, le trou le plus proche du début gagne.
        bitmap.free(start: 350, length: 12)
        #expect(bitmap.bestFitRun(minLength: 12) == Extent(start: 100, length: 12))
    }

    /// La plage de recherche est ce qui tient l'allocateur NTFS hors de la zone
    /// MFT : un trou qui déborde de la plage n'est utilisable que pour sa part
    /// interne.
    @Test("Best-fit restreint à une plage tronque les trous débordants")
    func bestFitInRange() {
        var bitmap = ClusterBitmap(clusterCount: 400)
        bitmap.allocate(start: 0, length: 400)
        bitmap.free(start: 90, length: 60)   // à cheval sur la borne 100

        // Vu depuis la plage haute, le trou commence à sa borne et ne vaut que
        // les 50 clusters qui y tombent.
        #expect(bitmap.bestFitRun(minLength: 10, in: 100..<400) == Extent(start: 100, length: 50))
        #expect(bitmap.bestFitRun(minLength: 51, in: 100..<400) == nil)
        // Vu depuis la plage basse, il est tronqué de l'autre côté.
        #expect(bitmap.bestFitRun(minLength: 10, in: 0..<100) == Extent(start: 90, length: 10))
        #expect(bitmap.bestFitRun(minLength: 11, in: 0..<100) == nil)
    }

    @Test("Le plus grand bloc libre et le nombre de trous")
    func freeSpaceShape() {
        var bitmap = ClusterBitmap(clusterCount: 1_000)
        bitmap.allocate(start: 0, length: 1_000)
        bitmap.free(start: 100, length: 7)
        bitmap.free(start: 300, length: 250)
        bitmap.free(start: 900, length: 3)

        #expect(bitmap.freeRunCount() == 3)
        #expect(bitmap.largestFreeRun() == Extent(start: 300, length: 250))
        #expect(bitmap.freeCount == 260)
    }

    @Test("Le parcours des trous s'interrompt à la demande")
    func earlyExit() {
        var bitmap = ClusterBitmap(clusterCount: 500)
        bitmap.allocate(start: 0, length: 500)
        for start in stride(from: UInt32(10), to: UInt32(400), by: 20) {
            bitmap.free(start: start, length: 3)
        }
        var seen: [Extent] = []
        bitmap.forEachFreeRun { run in
            seen.append(run)
            return seen.count < 4
        }
        #expect(seen.count == 4)
        #expect(seen[0] == Extent(start: 10, length: 3))
        #expect(seen[3] == Extent(start: 70, length: 3))
    }

    /// L'index des trous ne doit jamais rien changer à la réponse : le
    /// prochain cluster libre est celui qu'un balayage naïf trouverait.
    ///
    /// Le volume dépasse 262 144 clusters — 4 096 mots — pour que les deux
    /// niveaux de résumé servent, et les plages vont du cluster isolé à la
    /// moitié du volume, pour que des mots, puis des blocs de mots entiers,
    /// deviennent pleins et se libèrent.
    @Test("L'index des trous rend la même réponse qu'un balayage",
          arguments: [300_001, 1_000_000] as [UInt32])
    func indexMatchesLinearScan(clusterCount: UInt32) {
        var rng = SeededGenerator(seed: UInt64(clusterCount))
        var bitmap = ClusterBitmap(clusterCount: clusterCount)
        var reference = [Bool](repeating: false, count: Int(clusterCount))

        func naiveNextFree(from start: Int, before stop: Int) -> UInt32? {
            var cluster = start
            while cluster < stop {
                if !reference[cluster] { return UInt32(cluster) }
                cluster += 1
            }
            return nil
        }

        for round in 0..<400 {
            let maxLength = [1, 70, 5_000, 300_000][round % 4]
            let length = rng.uniform(1...min(maxLength, Int(clusterCount)))
            let start = rng.uniform(0...(Int(clusterCount) - length))
            // Plus d'allocations que de libérations : le volume se remplit, et
            // les longues traversées de mots pleins apparaissent.
            let allocate = rng.uniform(0...9) < 7
            if allocate {
                bitmap.allocate(start: UInt32(start), length: UInt32(length))
            } else {
                bitmap.free(start: UInt32(start), length: UInt32(length))
            }
            for cluster in start..<(start + length) { reference[cluster] = allocate }

            for _ in 0..<8 {
                let from = rng.uniform(0...(Int(clusterCount) - 1))
                let before = rng.uniform(0...3) == 0
                    ? rng.uniform(from...Int(clusterCount))
                    : Int(clusterCount)
                let expected = naiveNextFree(from: from, before: before)
                let found = before == Int(clusterCount)
                    ? bitmap.nextFreeCluster(from: UInt32(from))
                    : bitmap.nextFreeCluster(from: UInt32(from), before: UInt32(before))
                #expect(found == expected, "tour \(round), depuis \(from) avant \(before)")
            }
        }
        #expect(bitmap.freeCount == UInt32(reference.lazy.filter { !$0 }.count))
    }
}
