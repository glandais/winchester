import Testing
@testable import DiskCore

/// Fichier de test : le strict minimum pour éprouver les invariants avant que
/// `FileCatalog` n'existe. Taille logique **et** clusters alloués, parce que
/// c'est précisément leur écart qui portera le slack.
private struct ScratchFile {
    let id: Int
    let logicalSize: Int
    var extents: [Extent]
}

/// Bac à sable d'allocation : une bitmap, un allocateur first-fit ou best-fit
/// au choix, et un tableau témoin qui note pour chaque cluster le fichier qui
/// le détient. Le témoin est la référence contre laquelle la bitmap est
/// vérifiée — il est trop coûteux en mémoire pour le moteur réel, mais c'est
/// exactement ce qu'il faut pour prendre une double allocation en flagrant
/// délit.
private struct Sandbox {

    enum Strategy { case firstFit, nextFit, bestFit }

    var bitmap: ClusterBitmap
    var witness: [Int32]
    var files: [Int: ScratchFile] = [:]
    let clusterBytes: Int
    let strategy: Strategy
    private var cursor: UInt32 = 0
    private var nextID = 1

    init(clusterCount: UInt32, clusterBytes: Int = 4_096, strategy: Strategy) {
        self.bitmap = ClusterBitmap(clusterCount: clusterCount)
        self.witness = [Int32](repeating: -1, count: Int(clusterCount))
        self.clusterBytes = clusterBytes
        self.strategy = strategy
    }

    static func clustersNeeded(logicalSize: Int, clusterBytes: Int) -> UInt32 {
        UInt32((logicalSize + clusterBytes - 1) / clusterBytes)
    }

    private mutating func claim(_ count: UInt32, for id: Int) -> [Extent] {
        guard count > 0, count <= bitmap.freeCount else { return [] }
        var extents: [Extent] = []
        var remaining = count

        while remaining > 0 {
            let run: Extent?
            switch strategy {
            case .firstFit: run = bitmap.firstFitRun(minLength: 1, maxLength: remaining, from: 0)
            case .nextFit:  run = bitmap.firstFitRun(minLength: 1, maxLength: remaining, from: cursor, wrap: true)
            case .bestFit:  run = bitmap.bestFitRun(minLength: remaining) ?? bitmap.largestFreeRun()
            }
            guard let run, !run.isEmpty else { break }

            let take = min(run.length, remaining)
            bitmap.allocate(start: run.start, length: take)
            for cluster in run.start..<(run.start + take) { witness[Int(cluster)] = Int32(id) }
            extents.appendRun(start: run.start, length: take)
            cursor = run.start + take
            remaining -= take
        }
        return extents
    }

    mutating func create(logicalSize: Int) -> Int? {
        let need = Self.clustersNeeded(logicalSize: logicalSize, clusterBytes: clusterBytes)
        guard need <= bitmap.freeCount else { return nil }
        let id = nextID
        let extents = claim(need, for: id)
        guard extents.clusterCount == need else { return nil }
        nextID += 1
        files[id] = ScratchFile(id: id, logicalSize: logicalSize, extents: extents)
        return id
    }

    mutating func grow(_ id: Int, by bytes: Int) {
        guard var file = files[id] else { return }
        let before = file.extents.clusterCount
        let after = Self.clustersNeeded(logicalSize: file.logicalSize + bytes, clusterBytes: clusterBytes)
        guard after > before, after - before <= bitmap.freeCount else { return }
        let added = claim(after - before, for: id)
        guard added.clusterCount == after - before else { return }
        file.extents.append(contentsOf: added)
        file.extents = file.extents.coalesced()
        files[id] = ScratchFile(id: id, logicalSize: file.logicalSize + bytes, extents: file.extents)
    }

    mutating func delete(_ id: Int) {
        guard let file = files.removeValue(forKey: id) else { return }
        for extent in file.extents {
            for cluster in extent.start..<extent.end { witness[Int(cluster)] = -1 }
        }
        bitmap.free(file.extents)
    }

    /// Identifiants des fichiers vivants, dans l'ordre croissant : itérer les
    /// clés d'un dictionnaire ne serait pas reproductible d'une exécution à
    /// l'autre, et le test perdrait sa valeur.
    var liveIDs: [Int] { files.keys.sorted() }
}

@Suite("Invariants d'allocation")
struct InvariantTests {

    private static let seedCount = 200

    /// Joue une séquence déterministe de créations, extensions et suppressions,
    /// puis passe les invariants au crible. La séquence est volontairement
    /// hostile : beaucoup de petits fichiers éphémères entremêlés de quelques
    /// gros, c'est-à-dire ce qui fabrique un gruyère.
    private func exercise(seed: UInt64, strategy: Sandbox.Strategy,
                          clusterCount: UInt32 = 4_096) -> Sandbox {
        var rng = SeededGenerator(seed: seed)
        var sandbox = Sandbox(clusterCount: clusterCount, strategy: strategy)

        for _ in 0..<600 {
            switch rng.below(10) {
            case 0...4:
                let size = Int(rng.logNormal(median: 12_000, sigma: 1.4).rounded())
                _ = sandbox.create(logicalSize: max(size, 1))
            case 5:
                let size = Int(rng.logNormal(median: 900_000, sigma: 0.8).rounded())
                _ = sandbox.create(logicalSize: max(size, 1))
            case 6...7:
                let live = sandbox.liveIDs
                guard !live.isEmpty else { continue }
                let id = live[rng.index(below: live.count)]
                sandbox.grow(id, by: Int(rng.logNormal(median: 8_000, sigma: 1.0).rounded()))
            default:
                let live = sandbox.liveIDs
                guard !live.isEmpty else { continue }
                sandbox.delete(live[rng.index(below: live.count)])
            }
        }
        return sandbox
    }

    private static let strategies: [Sandbox.Strategy] = [.firstFit, .nextFit, .bestFit]

    /// Invariant 1 — aucun cluster n'appartient à deux fichiers, et la bitmap
    /// dit exactement ce que dit le témoin.
    @Test("Aucun cluster alloué deux fois", arguments: 0..<InvariantTests.seedCount)
    func noDoubleAllocation(seed: Int) {
        for strategy in Self.strategies {
            let sandbox = exercise(seed: UInt64(seed), strategy: strategy)

            var owner = [Int32](repeating: -1, count: Int(sandbox.bitmap.clusterCount))
            for id in sandbox.liveIDs {
                for extent in sandbox.files[id]!.extents {
                    for cluster in extent.start..<extent.end {
                        #expect(owner[Int(cluster)] == -1,
                                "cluster \(cluster) réclamé par \(owner[Int(cluster)]) et \(id)")
                        owner[Int(cluster)] = Int32(id)
                    }
                }
            }
            for cluster in 0..<Int(sandbox.bitmap.clusterCount) {
                #expect(sandbox.bitmap.isAllocated(UInt32(cluster)) == (owner[cluster] >= 0))
                #expect(owner[cluster] == sandbox.witness[cluster])
            }
            #expect(sandbox.bitmap.usedCount == UInt32(owner.count { $0 >= 0 }))
        }
    }

    /// Invariant 2 — la place occupée est exactement celle qu'exige la taille
    /// logique, arrondie au cluster supérieur. C'est aussi la définition du
    /// slack : tout ce qui sépare les deux est perdu.
    @Test("Les extents couvrent exactement la taille arrondie au cluster",
          arguments: 0..<InvariantTests.seedCount)
    func extentsMatchLogicalSize(seed: Int) {
        for strategy in Self.strategies {
            let sandbox = exercise(seed: UInt64(seed), strategy: strategy)
            for id in sandbox.liveIDs {
                let file = sandbox.files[id]!
                let expected = Sandbox.clustersNeeded(logicalSize: file.logicalSize,
                                                      clusterBytes: sandbox.clusterBytes)
                #expect(file.extents.clusterCount == expected)

                let allocated = Int(expected) * sandbox.clusterBytes
                #expect(allocated >= file.logicalSize)
                #expect(allocated - file.logicalSize < sandbox.clusterBytes)

                // Les extents d'un fichier ne se recouvrent pas entre eux.
                let sorted = file.extents.sorted { $0.start < $1.start }
                for i in 1..<max(sorted.count, 1) where sorted.count > 1 {
                    #expect(sorted[i - 1].end <= sorted[i].start)
                }
            }
        }
    }

    /// Invariant 3 — libérer rend exactement ce qui avait été pris.
    @Test("La libération rend exactement la place occupée",
          arguments: 0..<InvariantTests.seedCount)
    func freeRestoresExactly(seed: Int) {
        for strategy in Self.strategies {
            var sandbox = exercise(seed: UInt64(seed), strategy: strategy)
            var rng = SeededGenerator(seed: UInt64(seed) &* 31 &+ 7)

            let live = sandbox.liveIDs
            guard !live.isEmpty else { continue }
            for _ in 0..<min(live.count, 40) {
                let ids = sandbox.liveIDs
                guard !ids.isEmpty else { break }
                let id = ids[rng.index(below: ids.count)]
                let occupied = sandbox.files[id]!.extents.clusterCount
                let before = sandbox.bitmap.freeCount
                sandbox.delete(id)
                #expect(sandbox.bitmap.freeCount == before + occupied)
            }

            // Tout libérer ramène le volume à neuf, sans dérive du compteur.
            for id in sandbox.liveIDs { sandbox.delete(id) }
            #expect(sandbox.bitmap.freeCount == sandbox.bitmap.clusterCount)
            #expect(sandbox.bitmap.usedCount == 0)
            #expect(sandbox.bitmap.freeRunCount() == 1)
            #expect(sandbox.bitmap.largestFreeRun()
                    == Extent(start: 0, length: sandbox.bitmap.clusterCount))
        }
    }

    /// Invariant 6 — rien n'est jamais alloué hors des bornes du volume, y
    /// compris dans le bourrage du dernier mot de la bitmap.
    @Test("Aucune allocation hors des bornes du volume",
          arguments: 0..<InvariantTests.seedCount)
    func allocationsStayInBounds(seed: Int) {
        // Une taille qui n'est pas un multiple de 64 : c'est le cas où un
        // débordement passerait inaperçu.
        let clusterCount: UInt32 = 4_093
        for strategy in Self.strategies {
            let sandbox = exercise(seed: UInt64(seed), strategy: strategy,
                                   clusterCount: clusterCount)
            for id in sandbox.liveIDs {
                for extent in sandbox.files[id]!.extents {
                    #expect(extent.start < clusterCount)
                    #expect(UInt64(extent.start) + UInt64(extent.length) <= UInt64(clusterCount))
                    #expect(extent.length > 0)
                }
            }
            #expect(sandbox.bitmap.usedCount <= clusterCount)
            #expect(sandbox.bitmap.freeCount <= clusterCount)
            if let largest = sandbox.bitmap.largestFreeRun() {
                #expect(UInt64(largest.start) + UInt64(largest.length) <= UInt64(clusterCount))
            }
        }
    }

    /// La somme des trous et de la place occupée fait le volume : c'est le
    /// corollaire des invariants 1 et 3, et il tient quelle que soit la
    /// stratégie.
    @Test("Place libre et place occupée se complètent",
          arguments: 0..<InvariantTests.seedCount)
    func freeAndUsedAddUp(seed: Int) {
        for strategy in Self.strategies {
            let sandbox = exercise(seed: UInt64(seed), strategy: strategy)
            var freeTotal: UInt32 = 0
            sandbox.bitmap.forEachFreeRun { run in
                freeTotal += run.length
                return true
            }
            #expect(freeTotal == sandbox.bitmap.freeCount)
            #expect(sandbox.bitmap.freeCount + sandbox.bitmap.usedCount
                    == sandbox.bitmap.clusterCount)
        }
    }
}
