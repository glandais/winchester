import Foundation
import DiskCore

/// Les modes de JkDefrag qui ne se contentent pas de combler des trous.
///
/// Le mode 2 ne fait que ranger ce qui est cassé et reboucher derrière lui. Les
/// modes décrits ici **reconstruisent** le volume :
///
/// - `ForcedFill` (`-a 5`) le tasse contre son début, fragment par fragment ;
/// - `OptimizeUp` (`-a 6`) le tasse contre sa fin ;
/// - `OptimizeSort` (`-a 7` à `-a 11`) repose chaque fichier à son rang dans un
///   ordre choisi, et c'est le seul qui **évacue** : ce qui occupe la place du
///   fichier suivant est envoyé plus haut par `Vacate`, quitte à redescendre
///   quand viendra son tour.
///
/// La transposition est littérale, comme celle du mode 2, et pour la même
/// raison : ce sont les défauts qui fixent l'ordre des déplacements, donc le
/// son. Chaque écart est signalé à l'endroit où il se produit.
extension JKDefragStrategy.SortField {

    /// Pour l'écran : « tri par nom ».
    var phrase: String {
        switch self {
        case .name:       return String(localized: "sortField.name", defaultValue: "by name")
        case .size:       return String(localized: "sortField.size", defaultValue: "by size")
        case .lastAccess: return String(localized: "sortField.lastAccess", defaultValue: "by last access")
        case .lastChange: return String(localized: "sortField.lastChange", defaultValue: "by last change")
        case .creation:   return String(localized: "sortField.creation", defaultValue: "by creation date")
        }
    }
}

extension JKDefragStrategy.Pass {

    private var clusterTotal: UInt32 { UInt32(volume.partition.clusterCount) }

    // MARK: - `FindGap`, par le haut

    /// `FindGap` avec `FindHighestGap = YES` (`JkDefragLib.cpp:1688`) : le
    /// **dernier** trou d'au moins `size` clusters qui commence à `from` ou
    /// au-dessus, tronqué à `before`.
    ///
    /// Deux détails de l'original sont gardés. Un trou qui chevauche `from` est
    /// rendu à partir de `from`, puisque le balayage commence là. Et un trou qui
    /// commence au cluster zéro n'est **jamais** rendu : l'original teste
    /// `HighestBeginLcn != 0` pour savoir s'il a trouvé quelque chose.
    mutating func highestGap(from: UInt32, before: UInt32? = nil, size: UInt32) -> Extent? {
        report.highestGapSearches += 1
        let total = clusterTotal
        guard from < total else { return nil }
        let limit = min(before ?? total, total)
        var cursor = limit
        while cursor > from {
            guard let run = volume.bitmap.previousFreeRun(before: cursor) else { return nil }
            cursor = run.start
            for piece in outsideMFT(run).reversed() {
                let start = max(piece.start, from)
                let end = min(piece.end, limit)
                guard start < end else { continue }
                guard end - start >= size else { continue }
                return start == 0 ? nil : Extent(start: start, length: end - start)
            }
        }
        return nil
    }

    // MARK: - Fragments

    /// Le fragment d'un fichier déplaçable qui commence le plus bas à partir de
    /// `from`, avec le VCN où il commence dans son fichier.
    private func lowestFragment(from: UInt32) -> (extent: Extent, position: Int32, vcn: UInt32)? {
        let order = self.order
        guard let found = volume.index.firstExtent(from: from, where: { order.contains(Int32($0)) })
        else { return nil }
        return (found.extent, Int32(found.file), vcn(of: found.extent, in: found.file))
    }

    /// Le fragment d'un fichier déplaçable qui commence le plus haut sous
    /// `before`. Un fragment au cluster zéro n'est jamais retenu : `ForcedFill`
    /// part de `HighestLcn = 0` et exige de faire strictement mieux.
    private func highestFragment(before: UInt32) -> (extent: Extent, position: Int32, vcn: UInt32)? {
        let order = self.order
        guard let found = volume.index.lastExtent(before: before, where: { order.contains(Int32($0)) }),
              found.extent.start > 0 else { return nil }
        return (found.extent, Int32(found.file), vcn(of: found.extent, in: found.file))
    }

    private func vcn(of extent: Extent, in file: Int) -> UInt32 {
        var vcn: UInt32 = 0
        for candidate in volume.files[file].extents {
            if candidate.start == extent.start { return vcn }
            vcn += candidate.length
        }
        return vcn
    }

    // MARK: - `ForcedFill`

    /// `ForcedFill` (`JkDefragLib.cpp:4141`).
    ///
    /// Un trou après l'autre en montant, chacun rempli par **la fin** du
    /// fragment le plus haut du volume. Le fragment n'est pas pris entier : on
    /// en détache ce que le trou peut recevoir, ce qui casse volontiers un
    /// fichier contigu en deux. La passe s'arrête quand le fragment le plus haut
    /// est sous le trou courant.
    ///
    /// `MaxLcn` retient où s'arrêtait ce qui reste du fragment entamé : le
    /// prochain candidat doit commencer sous lui, de sorte qu'un fragment
    /// qu'on vient de poser en bas ne soit pas repris.
    mutating func forcedFill(phase: Int) {
        var gapBegin: UInt32 = 0
        var maxLcn = clusterTotal
        while true {
            guard let gap = gap(from: gapBegin, size: 0, mustFit: true) else { break }
            gapBegin = gap.start
            sink.progress = Double(gapBegin) / Double(clusterTotal)
            report.gapsVisited += 1

            guard let highest = highestFragment(before: maxLcn) else { break }
            if highest.extent.start <= gapBegin { break }

            let clusters = min(gap.end - gapBegin, highest.extent.length)
            // Le résultat n'est pas lu : un déplacement refusé laisse un trou
            // derrière lui, et la passe avance quand même.
            move(highest.position, vcn: highest.vcn + highest.extent.length - clusters,
                 length: clusters, to: gapBegin, phase: phase, pass: 0)
            gapBegin += clusters
            maxLcn = highest.extent.start + highest.extent.length - clusters
        }
    }

    // MARK: - `OptimizeUp`

    /// `OptimizeUp` (`JkDefragLib.cpp:4935`).
    ///
    /// Le miroir d'`OptimizeVolume` : les trous sont pris du fond du volume
    /// vers la fin de la zone des répertoires, et chacun est comblé par le
    /// haut. Mais les fichiers qui le comblent viennent de **dessous**, et c'est
    /// le premier qui tient en partant du début du disque qui est choisi — le
    /// nom `FindHighestItem` ne dit plus ce qu'il fait quand `Direction` vaut
    /// zéro. Le début du volume se vide donc par le bas.
    mutating func optimizeUp(phase: Int) {
        var gapEnd = clusterTotal
        var retry = 0
        while true {
            guard let gap = highestGap(from: zones[1], before: gapEnd, size: 0) else { break }
            var gapBegin = gap.start
            gapEnd = gap.end
            // Le tassement vers le haut avance en descendant.
            sink.progress = 1 - Double(gapEnd) / Double(clusterTotal)
            report.gapsVisited += 1

            // Tout ce qui pourrait venir combler ce trou : les fichiers qui
            // commencent sous sa fin, toutes zones confondues.
            var below: UInt64 = 0
            for item in order.items[..<order.lowerBound(gapEnd)] { below += UInt64(item.clusters) }
            if below == 0 { break }

            var perfectFit = UInt64(gapEnd - gapBegin) <= below

            while gapBegin < gapEnd && retry < 5 {
                var chosen: Int32?
                if perfectFit {
                    chosen = findBestItemBelow(start: gapBegin, end: gapEnd)
                    if chosen == nil {
                        perfectFit = false
                        chosen = findLowestItem(start: gapBegin, end: gapEnd)
                    }
                } else {
                    chosen = findLowestItem(start: gapBegin, end: gapEnd)
                }
                guard let position = chosen else { break }

                let clusters = volume.files[Int(position)].clusterCount
                if move(position, vcn: 0, length: clusters, to: gapEnd - clusters,
                        phase: phase, pass: 0) {
                    gapEnd -= clusters
                    retry = 0
                } else {
                    // `GapBegin = GapEnd` : le même trou sera relu au tour
                    // suivant, avec un essai de moins.
                    gapBegin = gapEnd
                    retry += 1
                }
            }

            if gapBegin < gapEnd {
                report.gapsSkipped += 1
                gapEnd = gapBegin
                retry = 0
            }
        }
    }

    /// `FindHighestItem` avec `Direction = 0` et `Zone = 3`
    /// (`JkDefragLib.cpp:2565`) : en partant du **début** du disque, le premier
    /// fichier qui tient dans le trou. Un fichier au cluster zéro est ignoré.
    mutating func findLowestItem(start: UInt32, end: UInt32) -> Int32? {
        report.highestFits += 1
        let size = end - start
        for item in order.items {
            if item.lcn == 0 { continue }
            if item.lcn > start { return nil }
            if item.clusters <= size { return item.position }
        }
        return nil
    }

    /// `FindBestItem` avec `Direction = 0` et `Zone = 3`
    /// (`JkDefragLib.cpp:2637`), en montant depuis le début du disque.
    ///
    /// Un défaut de l'original change de nature dans ce sens : on arrête de
    /// chercher au premier fichier **au-delà** de la fin du trou
    /// (`ItemLcn > ClusterEnd`), si bien que celui qui commence pile à sa fin
    /// — donc au-dessus de lui — reste candidat. S'il est retenu, il descend de
    /// la taille du trou au lieu de monter.
    mutating func findBestItemBelow(start: UInt32, end: UInt32) -> Int32? {
        report.perfectFitSearches += 1
        let full = end - start
        var remaining = full
        var sum: UInt64 = 0
        var firstIndex: Int?
        var visits = 0
        var index = 0

        while index < order.count {
            let item = order.items[index]
            visits += 1
            if item.lcn == 0 { index += 1; continue }

            if item.lcn > end {
                report.perfectFitPeakVisits = max(report.perfectFitPeakVisits, visits)
                guard let first = firstIndex else { return nil }
                if sum < UInt64(full) { return nil }
                if visits > strategy.perfectFitVisits {
                    report.perfectFitsExhausted += 1
                    return nil
                }
                // `Item = FirstItem ; continue` : on repart de l'élément qui
                // suit le premier retenu.
                index = first + 1
                firstIndex = nil
                remaining = full
                sum = 0
                continue
            }

            index += 1
            if item.clusters < full { sum += UInt64(item.clusters) }
            if item.clusters > remaining { continue }
            if item.clusters == remaining {
                report.perfectFitPeakVisits = max(report.perfectFitPeakVisits, visits)
                report.perfectFitsFound += 1
                return firstIndex.map { order.items[$0].position } ?? item.position
            }
            remaining -= item.clusters
            if firstIndex == nil { firstIndex = index - 1 }
        }
        return nil
    }

    // MARK: - `OptimizeSort`

    /// `OptimizeSort` (`JkDefragLib.cpp:4518`).
    ///
    /// Zone par zone, un curseur part du début de la zone. Pour chaque fichier,
    /// dans l'ordre demandé, `Vacate` fait de la place au curseur, puis le
    /// fichier y est posé — en plusieurs morceaux si ce qui a été libéré ne
    /// suffit pas. Le curseur avance d'autant.
    ///
    /// L'original cherche le fichier suivant en reparcourant tout l'arbre à
    /// chaque fois : le plus petit de ceux qui sont plus grands que le
    /// précédent. Ici l'ordre est calculé une fois. C'est le même tant que
    /// `CompareItems` départage avant d'en arriver au LCN, qui bouge — donc
    /// dès qu'un chemin est unique : sur tout volume réel, et sur ceux de la
    /// galerie, que `EventTimeline.giveUniqueNames` renomme à la manière de
    /// Windows.
    ///
    /// - Parameter phases: la phase de chaque zone.
    mutating func optimizeSort(field: JKDefragStrategy.SortField, phases: [Int]) {
        guard order.count > 0 else { return }
        let minimumVacate = UInt64(clusterTotal / 200)
        let sorted = sortedPositions(by: field)

        for zone in 0..<3 {
            let phase = phases[zone]
            var lcn = UInt64(zones[zone])
            var gapBegin: UInt64 = 0
            var gapEnd: UInt64 = 0

            for position in sorted[zone] where order.contains(position) {
                let clusters = UInt64(order.items[order.index(of: position)!].clusters)
                sink.progress = Double(lcn) / Double(clusterTotal)

                // Déjà à sa place — c'est-à-dire, pour l'original, que son
                // **premier** fragment commence au curseur. Le reste du
                // fichier n'est pas regardé.
                if UInt64(order.items[order.index(of: position)!].lcn) == lcn {
                    lcn += clusters
                    continue
                }

                var done: UInt64 = 0
                var pieces = 0
                while done < clusters && order.contains(position) {
                    // Faire de la place au curseur, puis relire le premier trou
                    // qui s'y trouve : `Vacate` n'a peut-être pas pu tout
                    // déloger.
                    if gapBegin + clusters - done + 16 > gapEnd {
                        vacate(lcn: lcn, clusters: clusters - done + minimumVacate,
                               zone: zone, phase: phase)
                        guard let gap = gap(from: UInt32(lcn), size: 0, mustFit: true) else { return }
                        gapBegin = UInt64(gap.start)
                        gapEnd = UInt64(gap.end)
                    }

                    var count = clusters - done
                    if count > gapEnd - gapBegin {
                        // « Il semble qu'un déplacement partiel ne réussisse que
                        // si le nombre de clusters est un multiple de 8. »
                        count = gapEnd - gapBegin
                        count -= count % 8
                        if count == 0 {
                            lcn = gapEnd
                            continue
                        }
                    }

                    if move(position, vcn: UInt32(done), length: UInt32(count),
                            to: UInt32(gapBegin), phase: phase, pass: 0) {
                        gapBegin += count
                        pieces += 1
                    } else {
                        guard let gap = gap(from: UInt32(gapBegin), size: 0, mustFit: true) else { return }
                        gapBegin = UInt64(gap.start)
                        gapEnd = UInt64(gap.end)
                    }
                    lcn = gapBegin
                    done += count
                }
                if pieces > 1 { report.splitPlacements += 1 }
            }
        }
    }

    /// `Vacate` (`JkDefragLib.cpp:4227`) : libérer `clusters` clusters à
    /// partir de `lcn`, en envoyant plus haut les fragments qui s'y trouvent.
    ///
    /// Les fragments sont pris un à un en montant depuis `lcn`, et chacun part
    /// au-dessus de `MoveTo` — la fin de la zone courante si tout était déjà
    /// rangé, pour ne pas le déplacer deux fois. Faute de place là-haut, le trou
    /// le plus haut du volume au-dessus du fragment.
    ///
    /// La garde anti-ver est celle de l'original, et elle est étrange : `lcn`
    /// ne change pas pendant la boucle, et `MoveTo` descend à chaque
    /// évacuation posée plus bas que lui. On s'arrête dès qu'une évacuation a
    /// atterri **sous** `lcn`, ce qui ne peut arriver que si le seul trou trouvé
    /// était dans la zone qu'on libère.
    mutating func vacate(lcn: UInt64, clusters: UInt64, zone: Int, phase: Int) {
        report.vacateCalls += 1
        let total = UInt64(clusterTotal)
        guard lcn < total else { return }

        var moveTo = lcn + clusters
        switch zone {
        case 0: moveTo = UInt64(zones[1])
        case 1: moveTo = UInt64(zones[2])
        default:
            // La fin du disque, moins tout l'espace libre, plus deux fois la
            // réserve.
            moveTo = total - freeClustersOutsideMFT
                + UInt64(Double(total) * 2.0 * strategy.freeSpacePercent / 100.0)
        }
        if moveTo < lcn + clusters { moveTo = lcn + clusters }

        var moveGapBegin: UInt64 = 0
        var moveGapEnd: UInt64 = 0
        var doneUntil = lcn

        while true {
            guard let bigger = lowestFragment(from: UInt32(doneUntil)) else { return }
            let biggerBegin = UInt64(bigger.extent.start)
            let biggerEnd = UInt64(bigger.extent.end)
            let size = biggerEnd - biggerBegin

            guard let test = gap(from: UInt32(lcn), size: 0, mustFit: true) else { return }
            // Le premier trou s'arrête avant le fragment : quelque chose
            // d'immobile les sépare, le trou ne grandira plus.
            if UInt64(test.end) < biggerBegin { return }
            // Le trou touche le fragment et suffit déjà.
            if UInt64(test.end) == biggerBegin && UInt64(test.length) >= clusters { return }
            if lcn >= moveTo {
                report.wormStops += 1
                return
            }

            if size >= moveGapEnd - moveGapBegin {
                var found: Extent?
                if moveTo < total && moveTo >= biggerEnd {
                    found = gap(from: UInt32(moveTo), size: UInt32(size), mustFit: true)
                }
                if found == nil {
                    found = highestGap(from: UInt32(biggerEnd), size: UInt32(size))
                }
                guard let found else { return }
                moveGapBegin = UInt64(found.start)
                moveGapEnd = UInt64(found.end)
            }

            if move(bigger.position, vcn: bigger.vcn, length: UInt32(size),
                    to: UInt32(moveGapBegin), phase: phase, pass: 1) {
                report.evacuations += 1
                sink.moves.evacuations = report.evacuations
                if moveGapBegin < moveTo { moveTo = moveGapBegin }
                moveGapBegin += size
            } else {
                moveGapEnd = moveGapBegin
            }
            doneUntil = biggerEnd
        }
    }

    /// `CountFreeClusters`, tel que le recompte `CallShowStatus` au début de
    /// chaque zone : la zone MFT n'y figure pas. Un déplacement ne change pas
    /// ce nombre, le compter une fois suffit.
    private var freeClustersOutsideMFT: UInt64 {
        var free = UInt64(volume.bitmap.freeCount)
        if let zone = volume.mftZone, !zone.isEmpty {
            var cursor = zone.lowerBound
            while let run = volume.bitmap.nextFreeRun(from: cursor, before: zone.upperBound) {
                let end = min(run.end, zone.upperBound)
                free -= UInt64(end - run.start)
                cursor = end
                if cursor >= zone.upperBound { break }
            }
        }
        return free
    }

    // MARK: - L'ordre

    /// Les fichiers de chaque zone, dans l'ordre de `CompareItems`.
    private func sortedPositions(by field: JKDefragStrategy.SortField) -> [[Int32]] {
        let clusterBytes = UInt64(volume.partition.clusterBytes)
        var zonesContent: [[SortKey]] = [[], [], []]
        for item in order.items {
            let file = volume.files[Int(item.position)]
            zonesContent[Int(item.zone)].append(SortKey(
                position: item.position,
                path: Array(("C:" + file.path).utf16).map(Self.lowercase),
                bytes: file.bytes ?? UInt64(item.clusters) * clusterBytes,
                // Le catalogue ne date pas les lectures. Une écriture est un
                // accès : c'est la dernière écriture qui en tient lieu, et
                // c'est une borne basse.
                access: file.modifiedDay,
                change: file.modifiedDay,
                creation: file.createdDay,
                lcn: item.lcn))
        }
        return zonesContent.map { keys in
            keys.sorted { SortKey.compare($0, $1, field: field) < 0 }.map(\.position)
        }
    }

    /// `_wcsicmp` dans la locale « C » : seules les lettres ASCII changent de
    /// casse.
    private static func lowercase(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }
}

/// Ce que `CompareItems` lit d'un élément.
private struct SortKey {
    let position: Int32
    let path: [UInt16]
    let bytes: UInt64
    let access: UInt32
    let change: UInt32
    let creation: UInt32
    let lcn: UInt32

    /// `CompareItems` (`JkDefragLib.cpp:4436`).
    ///
    /// Le critère d'abord, puis tous les champs dans l'ordre fixe. Le dernier
    /// accès est trié **du plus récent au plus ancien**, alors que le
    /// commentaire de l'original annonce l'inverse : c'est le code qui fait
    /// foi.
    static func compare(_ a: SortKey, _ b: SortKey, field: JKDefragStrategy.SortField) -> Int {
        func order<T: Comparable>(_ x: T, _ y: T) -> Int { x < y ? -1 : (x > y ? 1 : 0) }

        let primary: Int
        switch field {
        case .name:       primary = pathOrder(a.path, b.path)
        case .size:       primary = order(a.bytes, b.bytes)
        case .lastAccess: primary = order(b.access, a.access)
        case .lastChange: primary = order(a.change, b.change)
        case .creation:   primary = order(a.creation, b.creation)
        }
        if primary != 0 { return primary }

        for result in [pathOrder(a.path, b.path), order(a.bytes, b.bytes), order(a.access, b.access),
                       order(a.change, b.change), order(a.creation, b.creation), order(a.lcn, b.lcn)]
        where result != 0 {
            return result
        }
        return 0
    }

    private static func pathOrder(_ a: [UInt16], _ b: [UInt16]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}
