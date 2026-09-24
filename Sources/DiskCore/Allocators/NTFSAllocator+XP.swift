import Foundation

/// L'allocateur du pilote NTFS de XP SP1, suivi à la lettre
/// (`base/fs/ntfs/bitmpsup.c`, `NtfsAllocateClusters` et ce qu'elle appelle ;
/// `LEDGER-XP.md`, chantier 49). Il ne sert qu'aux volumes formatés par XP
/// (`Formatting.xp`) ; NT 4, Vista et 7 gardent le modèle d'avant, que ce
/// code ne permet pas de vérifier.
///
/// Ce qu'il fait, dans l'ordre où `NtfsAllocateClusters` le fait
/// (`bitmpsup.c:684-1480`), pour chaque trou à remplir :
///
/// 1. si le fichier a déjà des clusters, le run du **cache** qui commence
///    juste derrière son dernier (`NtfsLookupCachedLcn(PrecedingLcn + 1)`) ;
/// 2. sinon, le **plus petit run du cache au moins aussi long que la
///    demande**, et à longueur égale le plus proche de ce dernier cluster —
///    le plus petit LCN pour un fichier neuf (`NtfsLookupCachedLcnByLength`,
///    « maximum left-packing ») ; faute de run assez long, le **plus long**,
///    et le reste recommence au trou suivant (`AllowShorter`, `9652-9661`) :
///    un fichier se découpe du plus grand morceau au plus petit, et seulement
///    si aucun run ne suffit (`ntfs-alloc-21`) ;
/// 3. un run du cache qui chevauche la zone MFT en fait retirer la zone, et
///    la recherche reprend (`1085-1100`) ;
/// 4. le cache n'a plus rien : la **bitmap**, lue page par page depuis
///    `LastBitmapHint` — le premier trou venu, « pretty dumb »
///    (`NtfsFindFreeBitmapRun`, `3450-4035`) —, la zone en dernier, et la
///    zone qui cède alors (`NtfsReduceMftZone`).
///
/// Pas de curseur pour un fichier neuf, pas de préférence pour l'espace
/// jamais servi, pas d'horizon ni de fenêtre : ce que le modèle d'avant
/// réglait par quatre bornes sans source, XP le décide par le contenu de son
/// cache (`NTFSFreeRunCache`).
///
/// **Ce que le modèle traduit**, faute d'horloge plus fine que l'événement :
///
/// - **le montage** : le premier événement de chaque journée monte le volume
///   — la machine a été éteinte la nuit. Le cache est rebâti de la bitmap
///   (`NtfsScanEntireBitmap`, appelé par `NtfsInitializeClusterAllocation`
///   au montage, `fsctrl.c:2475`, `bitmpsup.c:655`) ;
/// - **le point de contrôle** : les clusters libérés quittent la bitmap tout
///   de suite, mais restent masqués (`NtfsAddRecentlyDeallocated`) jusqu'au
///   point de contrôle, qui les verse au cache
///   (`NtfsFreeRecentlyDeallocated`, `logsup.c:4500-4533`). XP en fait un
///   toutes les cinq secondes (`logsup.c:902-906`) ; le modèle, **un entre
///   deux événements** de l'histoire, qui sont des gestes de l'utilisateur ou
///   d'un programme : ce qu'un événement libère, le suivant peut le prendre,
///   et lui seul ne le peut pas.
extension NTFSAllocator {

    /// Une page de la bitmap : 4 Ko, un bit par cluster (`PAGE_SIZE × 8`).
    /// `NtfsScanEntireBitmap` et `NtfsFindFreeBitmapRun` la lisent par pages.
    static let bitmapPageClusters: UInt32 = 4_096 * 8

    /// Runs versés au cache par page lue au montage (`RtlFindClearRuns(…, 64,
    /// TRUE)`, `bitmpsup.c:2143`) et par page lue en cours d'allocation
    /// (`16`, `bitmpsup.c:3662, 3789, 4125, 4926`).
    static let runsPerMountedPage = 64
    static let runsPerReadPage = 16

    /// Runs au plus par appel d'allocation (`MAXIMUM_RUNS_AT_ONCE`,
    /// `ntfsdata.h:393`) ; l'appelant boucle tant que la demande n'est pas
    /// satisfaite (`allocsup.c:1475-1600`).
    static let maximumRunsAtOnce = 128

    // MARK: - Montage et point de contrôle

    /// Monte le volume : un démontage propre a rendu tous les clusters
    /// retenus, et le cache est rebâti de la bitmap
    /// (`NtfsInitializeClusterAllocation`, `bitmpsup.c:590-680`) ; le point
    /// de départ du dernier recours est le premier run du cache.
    mutating func xpMount() {
        pending.removeAll(keepingCapacity: true)
        pendingClusters = 0
        scanEntireBitmap()
        lastBitmapHint = cache.first?.start ?? 0
        cache.remove(mftZone)
    }

    /// Point de contrôle : les runs libérés depuis le précédent entrent dans
    /// le cache, dans l'ordre des LCN ; plein, le cache n'en prend plus
    /// (`logsup.c:4513-4533`).
    mutating func xpCheckpoint() {
        guard !pending.isEmpty else { return }
        pending.sort { $0.start < $1.start }
        for run in pending where !cache.insert(run) { break }
        pending.removeAll(keepingCapacity: true)
        pendingClusters = 0
    }

    /// `NtfsScanEntireBitmap` : les 64 plus longs runs de chaque page.
    mutating func scanEntireBitmap() {
        cache.removeAll()
        var runs: [Extent] = []
        var page: UInt32 = 0
        let total = bitmap.clusterCount
        while page < total {
            let end = page &+ min(Self.bitmapPageClusters, total - page)
            runs.append(contentsOf: longestVisibleRuns(in: page..<end, limit: Self.runsPerMountedPage)
                .sorted { $0.start < $1.start })
            page = end
        }
        if !cache.load(sortedRuns: runs) {
            // Plus de runs que le cache n'en tient : la règle du cache plein
            // joue, et l'ordre compte — page après page, les plus longs
            // d'abord (`NtfsAddCachedRunMult`).
            cache.removeAll()
            var page: UInt32 = 0
            while page < total {
                let end = page &+ min(Self.bitmapPageClusters, total - page)
                for run in longestVisibleRuns(in: page..<end, limit: Self.runsPerMountedPage) {
                    cache.insert(run)
                }
                page = end
            }
        }
    }

    // MARK: - La bitmap telle que XP la lit

    /// Les runs libres de `range`, moins les clusters retenus jusqu'au point
    /// de contrôle, que XP masque dans chaque page lue
    /// (`NtfsAddRecentlyDeallocated`, `bitmpsup.c:4220`).
    func forEachVisibleRun(in range: Range<UInt32>, _ body: (Extent) -> Bool) {
        guard range.lowerBound < range.upperBound else { return }
        let masks = pending.isEmpty ? [] : pending.filter {
            $0.start < range.upperBound && $0.end > range.lowerBound
        }.sorted { $0.start < $1.start }
        var position = range.lowerBound
        while position < range.upperBound,
              let start = bitmap.nextFreeCluster(from: position, before: range.upperBound) {
            let length = bitmap.freeRunLength(at: start, limit: range.upperBound - start)
            let run = Extent(start: start, length: length)
            position = run.end
            if masks.isEmpty {
                if !body(run) { return }
                continue
            }
            var cursor = run.start
            for mask in masks where mask.end > cursor && mask.start < run.end {
                if mask.start > cursor, !body(Extent(start: cursor, length: mask.start - cursor)) { return }
                cursor = max(cursor, mask.end)
            }
            if cursor < run.end, !body(Extent(start: cursor, length: run.end - cursor)) { return }
        }
    }

    /// `RtlFindClearRuns(…, limit, TRUE)` : les plus longs runs de la plage,
    /// du plus long au plus court, à longueur égale par LCN croissant.
    func longestVisibleRuns(in range: Range<UInt32>, limit: Int) -> [Extent] {
        var runs: [Extent] = []
        forEachVisibleRun(in: range) { runs.append($0); return true }
        guard runs.count > 1 else { return runs }
        runs.sort { $0.length != $1.length ? $0.length > $1.length : $0.start < $1.start }
        return runs.count > limit ? Array(runs.prefix(limit)) : runs
    }

    private func pageRange(of lcn: UInt32) -> Range<UInt32> {
        let base = lcn / Self.bitmapPageClusters * Self.bitmapPageClusters
        return base..<(base &+ min(Self.bitmapPageClusters, bitmap.clusterCount - base))
    }

    /// Verse au cache des runs qu'une page vient de montrer
    /// (`NtfsAddCachedRunMult`).
    private mutating func addToCache(_ runs: [Extent]) {
        for run in runs { cache.insert(run) }
    }

    /// `RtlFindClearBits(…, count, hint)` sur une page : le premier endroit
    /// d'au moins `count` clusters libres à partir de `hint`, puis depuis le
    /// début de la page.
    private func findClearRun(_ count: UInt32, in page: Range<UInt32>, from hint: UInt32) -> UInt32? {
        var found: UInt32?
        forEachVisibleRun(in: max(hint, page.lowerBound)..<page.upperBound) { run in
            if run.length >= count { found = run.start; return false }
            return true
        }
        if found == nil, hint > page.lowerBound {
            forEachVisibleRun(in: page.lowerBound..<min(hint, page.upperBound)) { run in
                let length = run.end == hint
                    ? run.length + visibleRunLength(at: hint, limit: count, within: page.upperBound)
                    : run.length
                if length >= count { found = run.start; return false }
                return true
            }
        }
        return found
    }

    /// Longueur du run libre visible qui commence à `lcn`, au plus `limit`.
    private func visibleRunLength(at lcn: UInt32, limit: UInt32, within end: UInt32) -> UInt32 {
        guard lcn < end else { return 0 }
        var length: UInt32 = 0
        forEachVisibleRun(in: lcn..<min(end, lcn &+ limit)) { run in
            if run.start == lcn { length = run.length }
            return false
        }
        return length
    }

    /// `NtfsFindFreeBitmapRun` (`bitmpsup.c:3450-4035`) : la page de
    /// l'indice d'abord — une place de `count` clusters, ou pour
    /// `anyLength` celle qui commence à l'indice même, ou à défaut le plus
    /// long run de la page —, puis le reste du volume page après page, la zone
    /// MFT en dernier.
    ///
    /// - Returns: le run trouvé, et s'il vient de la zone.
    mutating func xpFindFreeBitmapRun(_ count: UInt32, hint: UInt32, anyLength: Bool,
                                      ignoreZone: Bool) -> (run: Extent?, fromZone: Bool) {
        let total = bitmap.clusterCount
        let zone = mftZone
        var lcn = hint
        if lcn < total {
            let page = pageRange(of: lcn)
            var slice = page
            if !ignoreZone, page.lowerBound < zone.upperBound, lcn > zone.upperBound {
                slice = zone.upperBound..<page.upperBound
            }
            var start: UInt32?
            if anyLength {
                var first: UInt32?
                forEachVisibleRun(in: lcn..<slice.upperBound) { first = $0.start; return false }
                if first == nil, lcn > slice.lowerBound {
                    forEachVisibleRun(in: slice.lowerBound..<lcn) { first = $0.start; return false }
                }
                start = first == lcn ? lcn : (first == nil ? nil : findClearRun(count, in: slice, from: lcn))
            } else {
                start = findClearRun(count, in: slice, from: lcn)
            }
            if let start {
                var length = count
                var cachePage = slice
                if anyLength, start == hint {
                    // Le run qui commence à l'indice, suivi de page en page.
                    length = min(visibleRunLength(at: start, limit: count, within: total), count)
                    cachePage = pageRange(of: start &+ max(length, 1) &- 1)
                }
                addToCache(longestVisibleRuns(in: cachePage, limit: Self.runsPerReadPage))
                xpCounters.bitmapReads += 1
                return (Extent(start: start, length: length), false)
            }
            var runs = longestVisibleRuns(in: slice, limit: Self.runsPerReadPage)
            if let longest = runs.first {
                var found = longest
                if longest.length > count {
                    found = Extent(start: longest.start, length: count)
                    runs[0] = Extent(start: longest.start + count, length: longest.length - count)
                } else {
                    runs.removeFirst()
                }
                addToCache(runs)
                xpCounters.bitmapReads += 1
                return (found, false)
            }
            lcn = page.upperBound
            if ignoreZone {
                if let run = scanBitmapRange(lcn..<total, count) ?? scanBitmapRange(0..<lcn, count) {
                    return (run, zone.contains(run.start))
                }
                return (nil, false)
            }
        }
        let order: [Range<UInt32>]
        if lcn < zone.lowerBound {
            order = [lcn..<zone.lowerBound, zone.upperBound..<total, 0..<lcn]
        } else if lcn > zone.upperBound {
            order = [lcn..<total, 0..<zone.lowerBound, zone.upperBound..<lcn]
        } else {
            order = [zone.upperBound..<total, 0..<zone.lowerBound]
        }
        for range in order where range.lowerBound < range.upperBound {
            if let run = scanBitmapRange(range, count) { return (run, false) }
        }
        if let run = scanBitmapRange(zone, count) { return (run, true) }
        return (nil, false)
    }

    /// `NtfsScanBitmapRange` (`bitmpsup.c:4038-4150`) : la première page de
    /// la plage qui a un cluster libre ; son plus long run, et les autres au
    /// cache.
    private mutating func scanBitmapRange(_ range: Range<UInt32>, _ count: UInt32) -> Extent? {
        guard range.lowerBound < range.upperBound else { return nil }
        var first: UInt32?
        forEachVisibleRun(in: range) { first = $0.start; return false }
        guard let first else { return nil }
        let page = pageRange(of: first)
        let slice = max(page.lowerBound, range.lowerBound)..<min(page.upperBound, range.upperBound)
        var runs = longestVisibleRuns(in: slice, limit: Self.runsPerReadPage)
        guard let longest = runs.first else { return nil }
        if longest.length > count {
            runs[0] = Extent(start: longest.start + count, length: longest.length - count)
        } else {
            runs.removeFirst()
        }
        addToCache(runs)
        xpCounters.bitmapReads += 1
        return longest
    }

    /// `NtfsReadAheadCachedBitmap` (`bitmpsup.c:4851-4975`) : derrière la
    /// dernière allocation, le run qui commence là et les seize plus longs de
    /// sa page.
    private mutating func readAhead(at lcn: UInt32) {
        guard lcn < bitmap.clusterCount, cache.run(containing: lcn) == nil else { return }
        let page = pageRange(of: lcn)
        let length = visibleRunLength(at: lcn, limit: page.upperBound - lcn, within: page.upperBound)
        if length > 0 { cache.insert(Extent(start: lcn, length: length)) }
        addToCache(longestVisibleRuns(in: page, limit: Self.runsPerReadPage))
    }

    // MARK: - Allocation

    /// Prend des clusters trouvés : la bitmap, et le cache qui les oublie.
    mutating func xpTake(_ extent: Extent) {
        bitmap.allocate(extent)
        cache.remove(extent)
        unpend(extent)
        highWater = max(highWater, extent.end)
    }

    /// Des clusters retenus qu'on reprend quand même — un déplacement après
    /// son vidage, ou `$MFT` qui grandit : ils ne sont plus à rendre.
    mutating func unpend(_ extent: Extent) {
        guard pendingClusters > 0,
              pending.contains(where: { $0.start < extent.end && extent.start < $0.end }) else { return }
        var kept: [Extent] = []
        for run in pending {
            guard run.start < extent.end, extent.start < run.end else { kept.append(run); continue }
            if run.start < extent.start { kept.append(Extent(start: run.start, length: extent.start - run.start)) }
            if run.end > extent.end { kept.append(Extent(start: extent.end, length: run.end - extent.end)) }
        }
        pending = kept
        pendingClusters = kept.reduce(0) { $0 + $1.length }
    }

    /// Des clusters rendus : libres dans la bitmap, retenus jusqu'au point de
    /// contrôle.
    mutating func xpRelease(_ extents: [Extent]) {
        for extent in extents where extent.length > 0 {
            bitmap.free(extent)
            pending.append(extent)
            pendingClusters += extent.length
        }
    }

    /// `NtfsAllocateClusters` pour un fichier de données.
    ///
    /// - Parameters:
    ///   - core: ce qu'il faut (`ClusterCount`) ;
    ///   - desired: ce qu'on voudrait (`DesiredClusterCount`), au moins
    ///     `core` : le surplus n'est pris que tant que le cache répond
    ///     (`bitmpsup.c:1165-1178`) ;
    ///   - preceding: le dernier cluster du fichier, `nil` pour un fichier
    ///     neuf (`UNUSED_LCN`) ;
    ///   - paging: `pagefile.sys` (`FCB_STATE_PAGING_FILE`,
    ///     `bitmpsup.c:1110-1133`).
    /// - Returns: les extents pris, dans l'ordre, ou `nil` si le volume
    ///   n'avait pas la place : rien n'est alors pris, comme une transaction
    ///   annulée.
    mutating func xpAllocateClusters(core: UInt32, desired: UInt32, preceding: UInt32?,
                                     paging: Bool) -> [Extent]? {
        precondition(desired >= core)
        guard core <= bitmap.freeCount else { return nil }
        // `STATUS_LOG_FILE_FULL` (`bitmpsup.c:950-953`) : ce qui manque est
        // retenu jusqu'au point de contrôle ; le pilote le force, et
        // recommence.
        if bitmap.freeCount - pendingClusters < core { xpCheckpoint() }

        var taken: [Extent] = []
        var remaining = desired
        var filled: UInt32 = 0
        var precedingLcn = preceding
        var runCount = 0
        var fromBitmap = false
        var largestBitmap: UInt32 = 0
        var last: Extent?

        while remaining > 0 {
            var found: Extent?
            var hint: UInt32?
            if let p = precedingLcn, p &+ 1 < bitmap.clusterCount {
                if let run = cache.run(containing: p + 1) {
                    found = Extent(start: p + 1, length: run.end - (p + 1))
                    xpCounters.prolongations += 1
                } else {
                    hint = p + 1
                }
            }
            if found == nil {
                while let run = cache.lookup(length: remaining, allowShorter: true, hint: hint) {
                    if run.start < mftZone.upperBound, run.end > mftZone.lowerBound {
                        cache.remove(mftZone)
                        continue
                    }
                    found = run
                    break
                }
            }
            if paging, let candidate = found, candidate.length < remaining / 2 {
                if largestBitmap == 0 || largestBitmap >= remaining { found = nil }
            }
            if found == nil {
                // Ce qu'il fallait est là : le surplus ne vaut pas une lecture
                // de la bitmap (`bitmpsup.c:1165-1178`).
                if filled >= core { break }
                let bitmapHint: UInt32
                let anyLength: Bool
                if let p = precedingLcn {
                    bitmapHint = p &+ 1
                    anyLength = true
                } else {
                    bitmapHint = mftZone.contains(lastBitmapHint) ? mftZone.upperBound : lastBitmapHint
                    anyLength = false
                }
                var (run, fromZone) = xpFindFreeBitmapRun(remaining, hint: bitmapHint,
                                                          anyLength: anyLength, ignoreZone: false)
                if largestBitmap == 0 { largestBitmap = run?.length ?? 0 }
                fromBitmap = true
                if fromZone, xpReduceZone() {
                    run = xpFindFreeBitmapRun(remaining, hint: mftZone.upperBound,
                                              anyLength: false, ignoreZone: false).run
                }
                guard let run, run.length > 0 else {
                    // `STATUS_DISK_FULL` : la transaction est annulée.
                    xpUndo(taken)
                    return nil
                }
                found = run
            } else {
                xpCounters.cacheHits += 1
            }

            let extent = Extent(start: found!.start, length: min(found!.length, remaining))
            xpTake(extent)
            if precedingLcn == nil { lastBitmapHint = extent.start }
            taken.appendRun(start: extent.start, length: extent.length)
            precedingLcn = extent.end - 1
            remaining -= extent.length
            filled += extent.length
            runCount += 1
            last = extent

            if runCount == Self.maximumRunsAtOnce {
                // Fin d'un appel : le reste de ce qu'il faut est demandé par
                // un nouvel appel ; le surplus, non.
                if let last, runCount > 1 || fromBitmap { readAhead(at: last.end) }
                guard filled < core else { return taken }
                runCount = 0
                fromBitmap = false
                largestBitmap = 0
                remaining = core - filled
            }
        }
        if let last, runCount > 1 || fromBitmap { readAhead(at: last.end) }
        return taken
    }

    /// Une transaction annulée : les clusters pris retournent à la bitmap et
    /// au cache, d'où ils venaient.
    private mutating func xpUndo(_ taken: [Extent]) {
        for extent in taken {
            bitmap.free(extent)
            cache.insert(extent)
        }
    }

    /// La zone cède, quand la bitmap n'a plus rien hors d'elle.
    ///
    /// - Returns: `true` si elle a rendu de la place.
    mutating func xpReduceZone() -> Bool {
        xpCounters.zoneReductions += 1
        return yieldMFTZone()
    }
}

/// Ce que l'allocateur de XP a fait pendant une génération : de quoi dire,
/// dans le journal du chantier, d'où viennent ses runs.
public struct NTFSXPCounters: Sendable, Equatable {
    /// Trous remplis par le cache : prolongements, et recherches par longueur.
    public var prolongations = 0
    public var cacheHits = 0
    /// Pages de bitmap lues faute de réponse du cache.
    public var bitmapReads = 0
    public var zoneReductions = 0
    public init() {}
}
