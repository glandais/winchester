import Foundation

/// Le cache des runs libres du pilote NTFS de XP (`NTFS_CACHED_RUNS`,
/// `base/fs/ntfs/bitmpsup.c`) : ce que l'allocateur de XP consulte **avant**
/// la bitmap, et ce qui décide son *best fit*.
///
/// Deux listes du même ensemble de runs, l'une triée par LCN, l'autre par
/// longueur puis par LCN (`NtfsGetCachedLengthInsertionPoint`,
/// `bitmpsup.c:10501-10676`). Le cache n'est pas la bitmap : il n'en tient
/// que ce qu'on y a versé.
///
/// - au montage, les **64 plus longs runs** de chaque page de 4 Ko de la
///   bitmap, soit 32 768 clusters (`NtfsScanEntireBitmap`, `bitmpsup.c:2143`) ;
/// - les **16 plus longs** d'une page que l'allocateur a dû lire, quand le
///   cache ne répondait plus (`NtfsFindFreeBitmapRun`, `NtfsScanBitmapRange`,
///   `NtfsReadAheadCachedBitmap`) ;
/// - les runs libérés, au point de contrôle qui suit leur libération
///   (`NtfsFreeRecentlyDeallocated`, `logsup.c:4500-4533`).
///
/// Une allocation en retire exactement ce qu'elle prend : le reste du run
/// reste en cache (`NtfsAllocateBitmapRun`, `bitmpsup.c:3068-3080`).
///
/// **Borné** : 9 000 runs au plus (`MaximumSize`, `bitmpsup.c:9143`). Plein,
/// il n'accepte un run neuf qu'en chassant un run plus court d'une longueur
/// de 1 à 32 clusters dont il tient plus de 100 exemplaires (`MinCount`,
/// `bitmpsup.c:9144` ; `NTFS_CACHED_RUNS_BIN_COUNT`, `ntfsstru.h:844`) ;
/// sinon, il ignore le run neuf (`bitmpsup.c:10562-10636`).
struct NTFSFreeRunCache: Sendable, Equatable {

    static let maximumSize = 9_000
    static let minCount = 100
    static let binCount = 32

    /// Débuts des runs, triés, et leurs longueurs.
    private(set) var starts: [UInt32] = []
    private(set) var lengths: [UInt32] = []
    /// Les mêmes runs, clé `longueur << 32 | début`, triés.
    private var byLength: [UInt64] = []
    /// Nombre de runs de chaque longueur de 1 à 32 (`BinArray`).
    private var bins = [Int](repeating: 0, count: NTFSFreeRunCache.binCount)

    var count: Int { starts.count }
    var isEmpty: Bool { starts.isEmpty }
    var isFull: Bool { starts.count >= Self.maximumSize }

    /// Le run de plus petit LCN (`NtfsGetNextCachedLcn(…, 0, …)`).
    var first: Extent? { starts.first.map { Extent(start: $0, length: lengths[0]) } }

    var runs: [Extent] { zip(starts, lengths).map { Extent(start: $0, length: $1) } }

    mutating func removeAll() {
        starts.removeAll(keepingCapacity: true)
        lengths.removeAll(keepingCapacity: true)
        byLength.removeAll(keepingCapacity: true)
        bins = [Int](repeating: 0, count: Self.binCount)
    }

    /// Remplit un cache vide de runs qui ne se chevauchent pas, dans l'ordre
    /// des LCN : ceux qui se touchent sont fondus, comme les aurait fondus
    /// `insert` un à un. Réservé au cas où la règle du cache plein ne joue
    /// pas — c'est le montage d'un volume qui a moins de 9 000 runs à y
    /// verser — : l'ordre des ajouts n'y change alors rien, et un seul tri
    /// remplace des milliers d'insertions.
    ///
    /// - Returns: `false`, sans rien changer, si les runs fondus dépassent la
    ///   capacité ; l'appelant les verse alors un à un.
    mutating func load(sortedRuns runs: [Extent]) -> Bool {
        precondition(isEmpty)
        var mergedStarts: [UInt32] = []
        var mergedLengths: [UInt32] = []
        mergedStarts.reserveCapacity(runs.count)
        mergedLengths.reserveCapacity(runs.count)
        for run in runs where run.length > 0 {
            if let last = mergedStarts.last, last &+ mergedLengths[mergedLengths.count - 1] >= run.start {
                let end = max(last &+ mergedLengths[mergedLengths.count - 1], run.end)
                mergedLengths[mergedLengths.count - 1] = end - last
            } else {
                mergedStarts.append(run.start)
                mergedLengths.append(run.length)
            }
        }
        guard mergedStarts.count <= Self.maximumSize else { return false }
        starts = mergedStarts
        lengths = mergedLengths
        byLength = zip(mergedStarts, mergedLengths).map { Self.key($0, $1) }.sorted()
        for length in mergedLengths { bin(length, 1) }
        return true
    }

    // MARK: - Recherche

    /// Premier indice dont le début est strictement au-delà de `lcn`.
    private func upperIndex(_ lcn: UInt32) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= lcn { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Le run qui contient `lcn` (`NtfsLookupCachedLcn`).
    func run(containing lcn: UInt32) -> Extent? {
        let index = upperIndex(lcn) - 1
        guard index >= 0, lcn < starts[index] &+ lengths[index] else { return nil }
        return Extent(start: starts[index], length: lengths[index])
    }

    private static func key(_ start: UInt32, _ length: UInt32) -> UInt64 {
        UInt64(length) << 32 | UInt64(start)
    }

    /// Premier indice de `byLength` dont la clé est au moins `key`.
    private func lengthIndex(atLeast key: UInt64) -> Int {
        var low = 0, high = byLength.count
        while low < high {
            let mid = (low + high) / 2
            if byLength[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// `NtfsLookupCachedLcnByLength` (`bitmpsup.c:9577-9661`), avec
    /// `NtfsPositionCachedLcnByLength` (`13133-13540`) :
    ///
    /// - parmi les runs de **exactement** `length` clusters, le plus proche de
    ///   `hint` — sans indice (`UNUSED_LCN`, qui trie sous tout LCN), le plus
    ///   petit LCN : « maximum left-packing of the disk » ;
    /// - sinon, le premier run de la longueur supérieure la plus proche, donc
    ///   son plus petit LCN, sans regarder l'indice (le commentaire
    ///   « ENHANCEMENT », `13158-13161`) ;
    /// - sinon, si `allowShorter`, le dernier de la liste : le plus long, et à
    ///   longueur égale le plus haut LCN (`FoundIndex = Used - 1`).
    func lookup(length: UInt32, allowShorter: Bool, hint: UInt32?) -> Extent? {
        guard !byLength.isEmpty else { return nil }
        let first = lengthIndex(atLeast: Self.key(0, length))
        if first < byLength.count {
            let firstKey = byLength[first]
            if UInt32(firstKey >> 32) == length, let hint {
                // Les voisins de l'indice parmi les runs de cette longueur.
                let after = lengthIndex(atLeast: Self.key(hint, length))
                let maxMatch = after < byLength.count && UInt32(byLength[after] >> 32) == length ? after : nil
                let minMatch = after > first ? after - 1 : nil
                var chosen = maxMatch ?? minMatch!
                if let maxMatch, let minMatch {
                    let below = UInt32(truncatingIfNeeded: byLength[minMatch])
                    let above = UInt32(truncatingIfNeeded: byLength[maxMatch])
                    let distanceAbove = Int64(above) - Int64(hint)
                    let distanceBelow = Int64(hint) - (Int64(below) + Int64(length))
                    chosen = distanceBelow < distanceAbove ? minMatch : maxMatch
                }
                return Self.extent(byLength[chosen])
            }
            return Self.extent(firstKey)
        }
        return allowShorter ? Self.extent(byLength[byLength.count - 1]) : nil
    }

    /// Le cache tient-il un run d'au moins `length` clusters ?
    func hasRun(atLeast length: UInt32) -> Bool {
        lengthIndex(atLeast: Self.key(0, length)) < byLength.count
    }

    private static func extent(_ key: UInt64) -> Extent {
        Extent(start: UInt32(truncatingIfNeeded: key), length: UInt32(key >> 32))
    }

    // MARK: - Tenue des deux listes

    private mutating func bin(_ length: UInt32, _ delta: Int) {
        if length >= 1, length <= UInt32(Self.binCount) { bins[Int(length) - 1] += delta }
    }

    private mutating func removeLengthKey(_ start: UInt32, _ length: UInt32) {
        let index = lengthIndex(atLeast: Self.key(start, length))
        byLength.remove(at: index)
        bin(length, -1)
    }

    private mutating func insertLengthKey(_ start: UInt32, _ length: UInt32) {
        let key = Self.key(start, length)
        byLength.insert(key, at: lengthIndex(atLeast: key))
        bin(length, 1)
    }

    /// Change la longueur (et le début) de l'entrée `index`.
    private mutating func resize(_ index: Int, start: UInt32, length: UInt32) {
        removeLengthKey(starts[index], lengths[index])
        starts[index] = start
        lengths[index] = length
        insertLengthKey(start, length)
    }

    private mutating func delete(_ index: Int) {
        removeLengthKey(starts[index], lengths[index])
        starts.remove(at: index)
        lengths.remove(at: index)
    }

    /// Une entrée neuve, qui ne touche aucune autre (`NtfsInsertCachedRun`),
    /// sous la règle du cache plein (`NtfsGetCachedLengthInsertionPoint`).
    private mutating func insertNew(_ start: UInt32, _ length: UInt32, at index: Int) {
        if isFull {
            // Chasser un run plus court, d'une longueur dont le cache tient
            // plus de `MinCount` exemplaires — le premier de cette longueur —,
            // ou renoncer au run neuf.
            var victim: UInt32 = 0
            var candidate: UInt32 = 1
            while candidate <= UInt32(Self.binCount), candidate < length {
                if bins[Int(candidate) - 1] > Self.minCount { victim = candidate; break }
                candidate += 1
            }
            guard victim > 0 else { return }
            let key = byLength[lengthIndex(atLeast: Self.key(0, victim))]
            let victimStart = UInt32(truncatingIfNeeded: key)
            let victimIndex = upperIndex(victimStart) - 1
            delete(victimIndex)
            insertNew(start, length, at: victimIndex < index ? index - 1 : index)
            return
        }
        starts.insert(start, at: index)
        lengths.insert(length, at: index)
        insertLengthKey(start, length)
    }

    // MARK: - Ajout et retrait

    /// Verse un run libre (`NtfsInsertCachedLcn`, `bitmpsup.c:11248-11640`) :
    /// fondu dans les runs qu'il chevauche ou qu'il touche, d'un côté comme de
    /// l'autre ; neuf sinon, et soumis alors à la règle du cache plein.
    ///
    /// - Returns: `false` si le cache est plein après l'ajout — ce que
    ///   `NtfsAddCachedRun` rend, et qui arrête `NtfsFreeRecentlyDeallocated`.
    @discardableResult
    mutating func insert(_ run: Extent) -> Bool {
        guard run.length > 0 else { return !isFull }
        var start = run.start
        var end = run.end
        // Le run qui précède, s'il touche ou chevauche.
        var index = upperIndex(start)
        if index > 0, starts[index - 1] &+ lengths[index - 1] >= start {
            index -= 1
            start = starts[index]
            end = max(end, starts[index] &+ lengths[index])
        }
        // Tous ceux qui suivent et touchent.
        var last = index
        while last < starts.count, starts[last] <= end {
            end = max(end, starts[last] &+ lengths[last])
            last += 1
        }
        if last == index {
            insertNew(start, end - start, at: index)
            return !isFull
        }
        if start == starts[index], end - start == lengths[index], last == index + 1 {
            return !isFull   // déjà là
        }
        for victim in stride(from: last - 1, to: index, by: -1) { delete(victim) }
        resize(index, start: start, length: end - start)
        return !isFull
    }

    /// Retire une plage (`NtfsRemoveCachedLcn`, `bitmpsup.c:12283-12530`) :
    /// les runs qu'elle couvre disparaissent, ceux qu'elle entame sont
    /// raccourcis, et celui qu'elle coupe en deux garde sa première partie ;
    /// la seconde est reversée comme un run neuf, sous la règle du cache plein.
    mutating func remove(_ range: Extent) {
        guard range.length > 0, !starts.isEmpty else { return }
        let end = range.end
        var index = max(upperIndex(range.start) - 1, 0)
        while index < starts.count {
            let runStart = starts[index]
            let runEnd = runStart &+ lengths[index]
            if runEnd <= range.start { index += 1; continue }
            if runStart >= end { break }
            if runStart < range.start {
                resize(index, start: runStart, length: range.start - runStart)
                if end < runEnd {
                    insertNew(end, runEnd - end, at: index + 1)
                    return
                }
                index += 1
            } else if runEnd <= end {
                delete(index)
            } else {
                resize(index, start: end, length: runEnd - end)
                return
            }
        }
    }

    /// Retire tout ce qui chevauche `range`.
    mutating func remove(_ range: Range<UInt32>) {
        guard range.lowerBound < range.upperBound else { return }
        remove(Extent(start: range.lowerBound, length: range.upperBound - range.lowerBound))
    }
}
