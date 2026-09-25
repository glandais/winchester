import Foundation
import DiskCore

/// Une passe NTFS écrite pour ce projet, et qui ne reproduit aucun outil : ne
/// déplacer que ce qui coûte peu et rapporte beaucoup.
///
/// Elle part de la forme des huit volumes NTFS de la galerie. Ce n'est plus la
/// place qui manque mais la taille : tasser le volume à la façon de
/// `FrontierCompactionStrategy` y déplace tout son contenu, des centaines de
/// gigaoctets et des heures de passe (le README en donne les chiffres). Et la
/// fragmentation y est très inégale :
///
/// - quelques milliers de fichiers cassés portent des dizaines de milliers de
///   morceaux, dont les petits ne pèsent presque rien dans le volume ;
/// - chacun de ces petits morceaux coûte pourtant une lecture, donc un demi-
///   tour de plateau au moins. C'est leur nombre, et non leur poids, qui fait
///   la durée d'une passe.
///
/// D'où trois gestes, rejoués par tours :
///
/// 1. **recoller les petits morceaux.** Une suite de morceaux de moins de
///    `smallPiece`, dans l'ordre du fichier, est recopiée d'un seul tenant —
///    contre le gros morceau qui la précède ou qui la suit si le trou voisin
///    l'accepte, sinon dans le trou le plus proche. Les gros morceaux restent
///    où ils sont ;
/// 2. **coller un morceau à son voisin** — même gros, jusqu'à
///    `attachLimit` — quand le trou qui borde ce voisin l'accepte ;
/// 3. **consolider l'espace libre.** Un petit fichier coincé entre deux trous
///    part ailleurs, et les deux trous n'en font qu'un ; un petit fichier au
///    bord d'un seul trou part dans un trou exactement à sa taille, ou dans un
///    trou plus petit que celui qu'il borde. L'espace libre passe des petits
///    trous aux grands, et le tour suivant y trouve de quoi recoller.
///
/// Deux choses tiennent au format :
///
/// - **les points de contrôle.** Le recollage économe écrit lui-même ses
///   tables et tient les clusters qu'il quitte jusqu'à les avoir écrites —
///   un choix de l'outil, qui vaut aussi sous XP, dont le pilote les rendrait
///   tout de suite à qui passe par `FSCTL_MOVE_FILE` ; c'est la comptabilité
///   qu'`UltraDefragStrategy` tient par tour. Ici un point de
///   contrôle tombe tous les `checkpointMoves` déplacements : les
///   enregistrements de MFT et la bitmap sont écrits d'une traite, triés, et
///   ce qui était retenu redevient libre. Aucune écriture ne tombe sur un
///   cluster dont la libération n'est pas encore écrite ;
/// - **le déplacement par blocs pleins** (`DefragOperations.gatheredMove`) :
///   un bloc de 8 ou 16 Mo se lit morceau par morceau et s'écrit une fois.
///
/// La zone MFT n'est jamais une destination, et un fichier qui s'y trouve
/// peut en sortir.
struct FragmentMergeStrategy: DefragStrategy {

    let id = "fragmentMerge"
    let label = String(localized: "strategy.fragmentMerge", defaultValue: "Thrifty merge")

    /// En dessous de cette taille, un morceau vaut d'être recollé.
    ///
    /// Sur les huit volumes : à 16 Mo, 12 % de durée en plus pour 14 % de
    /// morceaux en moins ; à 2 Mo, 5 % de durée en moins pour 17 % de morceaux
    /// en plus. UltraDefrag retient 20 Mo, mais recopie d'abord les fichiers
    /// entiers.
    var smallPiece = 4 << 20

    /// Un morceau jusqu'à cette taille est recopié contre son voisin quand le
    /// trou qui le borde l'accepte : un morceau de moins, pour au plus 16 Mo
    /// recopiés. De 8 à 32 Mo, la durée croît de 17 % et les morceaux restants
    /// baissent de 14 %.
    var attachLimit = 16 << 20

    /// Les fichiers déplacés pour consolider l'espace libre ne dépassent pas
    /// cette taille. À 1 Mo il reste 77 % de trous en plus ; à 16 Mo, 5 % de
    /// durée en plus pour 14 % de trous en moins.
    var consolidationLimit = 4 << 20

    /// Nombre de déplacements entre deux points de contrôle. Tous les 4, les
    /// validations coûtent 9 % de durée en plus ; tous les 64, la passe gagne
    /// 4 % de durée mais l'espace libéré attend plus longtemps, et il reste 3 %
    /// de trous en plus.
    var checkpointMoves = 16

    /// Un tour qui retire moins de cette part des trous est le dernier, en
    /// millièmes. Sans lui, la consolidation traîne des centaines de tours
    /// pour quelques clusters.
    var minimumHoleGainPerMille = 10

    /// Garde-fou : aucun volume de la galerie n'en demande plus de 31.
    var maximumRounds = 60

    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: String(localized: "phase.analyse", defaultValue: "Analysing the volume"),
                        detail: String(localized: "phase.analyse.merge.detail", defaultValue: "The broken files, and the holes outside the MFT zone")),
        PhaseDescriptor(id: "merge", label: String(localized: "phase.merge", defaultValue: "Merging"),
                        detail: String(localized: "phase.merge.detail", defaultValue: "The small pieces copied back in one piece, and the small files separating two holes moved")),
        PhaseDescriptor.commit(on: .ntfs),
        PhaseDescriptor(id: "done", label: String(localized: "phase.done", defaultValue: "Finished"),
                        detail: String(localized: "phase.done.merge.detail", defaultValue: "The big pieces have not moved")),
    ]

    // MARK: - Planification

    func plan(volume: DefragVolume, into sink: OperationSink) -> DefragPlan {
        run(volume: volume, into: sink).plan
    }

    /// Le plan complet, opérations comprises, et le détail de ce que la passe
    /// a fait pour y arriver.
    func run(volume: DefragVolume) -> (plan: DefragPlan, report: Report) {
        let sink = OperationSink()
        let (plan, report) = run(volume: volume, into: sink)
        return (plan.with(operations: sink.operations, mutations: sink.mutations), report)
    }

    func run(volume input: DefragVolume, into sink: OperationSink) -> (plan: DefragPlan, report: Report) {
        let before = input.stats
        let initialRuns = input.categoryRuns()

        DefragOperations.analysis(volume: input, into: sink)

        var pass = Pass(strategy: self, volume: input, sink: sink)
        pass.run(phase: 1)
        pass.volume.releaseHeldClusters()

        sink.progress = 1
        DefragOperations.final(partition: input.partition, phase: 2, into: sink)

        let movable = input.files.filter(Pass.isMovable).count
        let plan = DefragPlan(
            strategy: self,
            partition: input.partition,
            initialRuns: initialRuns,
            operations: [],
            mutations: [],
            phases: phases,
            before: before,
            after: pass.volume.stats,
            movedBytes: pass.report.movedClusters * input.partition.clusterBytes,
            filesMoved: pass.touched.count,
            filesAlreadyInPlace: movable - pass.touched.count,
            // Toute destination est un trou libre : personne n'est délogé
            // pour faire place.
            evacuations: 0,
            arrangement: pass.volume.arrangement
        )
        return (plan, pass.report)
    }

    /// Ce que les compteurs communs ne disent pas.
    struct Report {
        var rounds = 0
        var movedClusters = 0
        /// Suites de petits morceaux recopiées d'un seul tenant, dont celles
        /// posées contre un gros morceau du même fichier, et celles coupées
        /// faute d'un trou à leur taille.
        var runs = 0
        var runsBesideNeighbour = 0
        var runsSplit = 0
        /// Suites laissées en place : aucun trou n'en accepte deux morceaux.
        var runsLeft = 0
        /// Morceaux, petits ou gros, recopiés contre leur voisin logique.
        var attachments = 0
        /// Fichiers déplacés pour réunir deux trous, et pour vider le bord d'un
        /// trou ; parmi eux, ceux posés dans un trou exactement à leur taille.
        var consolidations = 0
        var erosions = 0
        var exactFits = 0
        var checkpoints = 0
        /// Écritures de métadonnées, une fois triées et fusionnées.
        var metadataWrites = 0
    }

    func summary(of plan: DefragPlan) -> String {
        String(localized: "summary.fragmentMerge",
               defaultValue: "The pass merges the small pieces of \(plan.before.fragmentedFiles) broken files and leaves the big ones where they are; \(plan.filesMoved) files moved in all, the others to bring holes together. No write ever lands on a cluster whose release is not written.")
    }
}

// MARK: - La passe

extension FragmentMergeStrategy {

    /// Un morceau réel d'un fichier : deux extents qui se suivent dans le
    /// fichier et se touchent sur le plateau n'en font qu'un.
    struct Piece {
        let vcn: UInt32
        let lcn: UInt32
        let length: UInt32
        var end: UInt32 { lcn + length }
    }

    struct Pass {
        let strategy: FragmentMergeStrategy
        var volume: DefragVolume
        let sink: OperationSink
        let partition: PartitionGeometry
        let total: UInt32
        let bufferBytes: Int
        let smallPiece: UInt32
        let attachLimit: UInt32
        let consolidationLimit: UInt32

        /// Les trous où poser, zone MFT exclue : par début, et par taille puis
        /// début. Ils ne voient pas les clusters retenus, qui n'y entrent qu'au
        /// point de contrôle.
        var holes: [Extent] = []
        var bySize: [Extent] = []

        /// Les validations depuis le dernier point de contrôle.
        var pendingCommits: [(extents: [Extent], file: Int)] = []
        var pendingFiles = Set<Int>()
        var movesSinceCheckpoint = 0

        var touched = Set<Int>()
        var report = Report()

        init(strategy: FragmentMergeStrategy, volume: DefragVolume, sink: OperationSink) {
            self.strategy = strategy
            self.volume = volume
            self.sink = sink
            self.partition = volume.partition
            self.total = UInt32(volume.partition.clusterCount)
            // Le grain d'UltraDefrag, qui suit la capacité du volume : 8 ou
            // 16 Mo sur les volumes de 2007, 4 Mo sur ceux de 2003.
            self.bufferBytes = UltraDefragStrategy.moveAtOnce(capacityBytes: volume.partition.capacityBytes)
            let clusterBytes = volume.partition.clusterBytes
            self.smallPiece = UInt32(max(1, strategy.smallPiece / clusterBytes))
            self.attachLimit = UInt32(strategy.attachLimit / clusterBytes)
            self.consolidationLimit = UInt32(strategy.consolidationLimit / clusterBytes)
        }

        static func isMovable(_ file: DefragFile) -> Bool {
            file.isMovable && file.category != .reserved && file.clusterCount > 0
        }

        // MARK: Tours

        mutating func run(phase: Int) {
            var holeCount = volume.bitmap.freeRunCount()
            while report.rounds < strategy.maximumRounds {
                report.rounds += 1
                volume.releaseHeldClusters()
                rebuildHoles()
                let moved = report.movedClusters

                // Dans l'ordre du plateau, pour que le bras balaie le volume.
                let order = volume.files.indices
                    .filter { Self.isMovable(volume.files[$0]) && !volume.files[$0].isContiguous }
                    .map { ($0, volume.files[$0].extents.map(\.start).min() ?? 0) }
                    .sorted { $0.1 < $1.1 }
                    .map(\.0)
                // L'essentiel du travail est au premier tour ; les suivants
                // se partagent ce qui reste de la barre.
                let span = pow(0.5, Double(report.rounds))
                for (rank, position) in order.enumerated() {
                    sink.progress = 1 - 2 * span + span * Double(rank) / Double(max(order.count, 1))
                    mergeSmallPieces(of: position, phase: phase)
                    attachPieces(of: position, phase: phase)
                }
                consolidate(phase: phase)
                flush(phase: phase)

                if report.movedClusters == moved { break }
                // Le rendement du tour se mesure une fois ses clusters rendus.
                volume.releaseHeldClusters()
                let remaining = volume.bitmap.freeRunCount()
                if report.rounds > 2,
                   (holeCount - min(holeCount, remaining)) * 1000 < holeCount * strategy.minimumHoleGainPerMille {
                    break
                }
                holeCount = remaining
            }
        }

        // MARK: Recollage

        func pieces(of position: Int) -> [Piece] {
            var result: [Piece] = []
            var vcn: UInt32 = 0
            for extent in volume.files[position].extents where !extent.isEmpty {
                if let last = result.last, last.end == extent.start {
                    result[result.count - 1] = Piece(vcn: last.vcn, lcn: last.lcn, length: last.length + extent.length)
                } else {
                    result.append(Piece(vcn: vcn, lcn: extent.start, length: extent.length))
                }
                vcn += extent.length
            }
            return result
        }

        /// Chaque suite de petits morceaux, recopiée d'un seul tenant.
        ///
        /// Une suite d'un seul morceau ne bouge que si elle peut rejoindre un
        /// voisin : ailleurs, ce serait déplacer un morceau sans en supprimer
        /// un seul. Une suite qu'aucun trou n'accepte est coupée à la taille du
        /// plus grand, tant que la coupe garde deux morceaux.
        mutating func mergeSmallPieces(of position: Int, phase: Int) {
            var index = 0
            while true {
                let list = pieces(of: position)
                guard list.count > 1 else { return }
                while index < list.count && list[index].length >= smallPiece { index += 1 }
                guard index < list.count else { return }

                let first = index
                var last = index
                var length = list[index].length
                while last + 1 < list.count && list[last + 1].length < smallPiece {
                    last += 1
                    length += list[last].length
                }

                var target = besideNeighbour(of: list, first: first, last: last, length: length)
                if target != nil {
                    report.runsBesideNeighbour += 1
                } else {
                    guard last > first else { index = last + 1; continue }
                    target = nearestHole(length: length, near: list[first].lcn).map {
                        (Extent(start: holes[$0].start, length: length), $0)
                    }
                    if target == nil {
                        guard let largest = bySize.last else { report.runsLeft += 1; return }
                        var cut = first
                        var sum: UInt32 = 0
                        while cut <= last && sum + list[cut].length <= largest.length {
                            sum += list[cut].length
                            cut += 1
                        }
                        guard cut - first >= 2 else { report.runsLeft += 1; index = last + 1; continue }
                        length = sum
                        target = (Extent(start: largest.start, length: length), holeIndex(startingAt: largest.start)!)
                        report.runsSplit += 1
                    }
                }

                let (extent, hole) = target!
                take(extent, fromHole: hole)
                relocate(position, vcn: list[first].vcn, length: length, to: extent, phase: phase)
                report.runs += 1

                let end = list[first].vcn + length
                index = pieces(of: position).firstIndex { $0.vcn >= end } ?? Int.max
            }
        }

        /// La place contre le morceau qui précède la suite, ou contre celui qui
        /// la suit, si le trou qui les borde l'accepte.
        func besideNeighbour(of list: [Piece], first: Int, last: Int, length: UInt32) -> (Extent, Int)? {
            if first > 0, let hole = holeIndex(startingAt: list[first - 1].end), holes[hole].length >= length {
                return (Extent(start: list[first - 1].end, length: length), hole)
            }
            if last + 1 < list.count {
                let next = list[last + 1]
                let hole = lowerHole(next.lcn) - 1
                if hole >= 0, holes[hole].end == next.lcn, holes[hole].length >= length {
                    return (Extent(start: next.lcn - length, length: length), hole)
                }
            }
            return nil
        }

        /// Chaque morceau d'au plus `attachLimit`, posé contre son voisin
        /// logique quand le trou qui borde celui-ci l'accepte.
        mutating func attachPieces(of position: Int, phase: Int) {
            var index = 0
            while true {
                let list = pieces(of: position)
                guard index < list.count, list.count > 1 else { return }
                let piece = list[index]
                guard piece.length <= attachLimit,
                      let (extent, hole) = besideNeighbour(of: list, first: index, last: index, length: piece.length)
                else {
                    index += 1
                    continue
                }
                take(extent, fromHole: hole)
                relocate(position, vcn: piece.vcn, length: piece.length, to: extent, phase: phase)
                report.attachments += 1
                // Le morceau a rejoint un voisin : le précédent a peut-être
                // maintenant un trou à côté de lui.
                index = max(0, index - 1)
            }
        }

        // MARK: Consolidation

        /// Les petits fichiers d'un seul tenant au bord des trous.
        ///
        /// - entre deux trous, il part dans un trou exactement à sa taille, ou
        ///   à défaut dans le plus proche qui l'accepte : les deux trous qu'il
        ///   séparait n'en font plus qu'un ;
        /// - au bord d'un seul, il part dans un trou exactement à sa taille,
        ///   qui disparaît, ou dans le plus petit qui l'accepte s'il est plus
        ///   petit que celui qu'il borde. Le nombre de trous ne bouge pas, mais
        ///   l'espace libre passe du petit au grand.
        ///
        /// Les candidats sont relevés en tête de consolidation, et leurs voisins
        /// relus au moment de les déplacer : un point de contrôle a pu passer.
        mutating func consolidate(phase: Int) {
            var runs: [Extent] = []
            var cursor: UInt32 = 0
            while let run = volume.bitmap.nextFreeRun(from: cursor) {
                runs.append(run)
                cursor = run.end
            }
            guard runs.count > 1 else { return }

            var candidates: [Int] = []
            var seen = Set<Int>()
            func consider(_ range: Range<UInt32>) {
                for position in volume.occupants(of: range) where !seen.contains(position) {
                    let file = volume.files[position]
                    guard Self.isMovable(file), file.clusterCount <= consolidationLimit, file.isContiguous
                    else { continue }
                    seen.insert(position)
                    candidates.append(position)
                }
            }
            for index in 0..<(runs.count - 1) {
                let start = runs[index].end, end = runs[index + 1].start
                if end - start <= consolidationLimit {
                    consider(start..<end)
                } else {
                    consider(start..<(start + 1))
                    consider((end - 1)..<end)
                }
            }

            for position in candidates {
                let extents = volume.files[position].extents.coalesced()
                guard extents.count == 1, let file = extents.first else { continue }
                let left = freeLength(endingAt: file.start)
                let right = freeLength(startingAt: file.end)
                guard left > 0 || right > 0 else { continue }
                let between = left > 0 && right > 0

                var index = exactHole(length: file.length, near: file.start)
                // Seul trou voisin, il n'est pas une destination : le fichier y
                // glisserait, et le trou passerait de l'autre côté.
                if !between, let hole = index, holes[hole].end == file.start || holes[hole].start == file.end {
                    index = nil
                }
                if index != nil {
                    report.exactFits += 1
                } else if between {
                    index = nearestHole(length: file.length, near: file.start)
                } else {
                    index = smallerHole(length: file.length, than: max(left, right), besides: file)
                }
                guard let index else { continue }

                let target = Extent(start: holes[index].start, length: file.length)
                take(target, fromHole: index)
                relocate(position, vcn: 0, length: file.length, to: target, phase: phase)
                if between { report.consolidations += 1 } else { report.erosions += 1 }
            }
        }

        /// La longueur du trou qui finit juste avant `cluster`, zone MFT
        /// comprise : c'est la bitmap qui compte les trous.
        func freeLength(endingAt cluster: UInt32) -> UInt32 {
            guard cluster > 0, !volume.bitmap.isAllocated(cluster - 1),
                  let run = volume.bitmap.previousFreeRun(before: cluster), run.end == cluster else { return 0 }
            return run.length
        }

        func freeLength(startingAt cluster: UInt32) -> UInt32 {
            guard cluster < total, !volume.bitmap.isAllocated(cluster) else { return 0 }
            return volume.bitmap.nextFreeRun(from: cluster)?.length ?? 0
        }

        // MARK: Trous

        mutating func rebuildHoles() {
            holes.removeAll(keepingCapacity: true)
            var cursor: UInt32 = 0
            while let run = volume.bitmap.nextFreeRun(from: cursor) {
                cursor = run.end
                if let zone = volume.mftZone, run.start < zone.upperBound, run.end > zone.lowerBound {
                    if run.start < zone.lowerBound {
                        holes.append(Extent(start: run.start, length: zone.lowerBound - run.start))
                    }
                    if run.end > zone.upperBound {
                        holes.append(Extent(start: zone.upperBound, length: run.end - zone.upperBound))
                    }
                    continue
                }
                holes.append(run)
            }
            bySize = holes.sorted { ($0.length, $0.start) < ($1.length, $1.start) }
        }

        func holeIndex(startingAt start: UInt32) -> Int? {
            let index = lowerHole(start)
            return index < holes.count && holes[index].start == start ? index : nil
        }

        /// Le premier trou qui commence à `cluster` ou après.
        func lowerHole(_ cluster: UInt32) -> Int {
            var low = 0, high = holes.count
            while low < high {
                let middle = (low + high) / 2
                if holes[middle].start < cluster { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// Le premier trou d'au moins `length` clusters, par taille.
        func lowerSize(_ length: UInt32) -> Int {
            var low = 0, high = bySize.count
            while low < high {
                let middle = (low + high) / 2
                if bySize[middle].length < length { low = middle + 1 } else { high = middle }
            }
            return low
        }

        func sizeIndex(_ hole: Extent) -> Int {
            var low = 0, high = bySize.count
            while low < high {
                let middle = (low + high) / 2
                if (bySize[middle].length, bySize[middle].start) < (hole.length, hole.start) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        /// Le trou le plus proche de `near` qui accepte `length` clusters.
        func nearestHole(length: UInt32, near: UInt32) -> Int? {
            let center = lowerHole(near)
            var left = center - 1, right = center
            while left >= 0 || right < holes.count {
                let toLeft = left >= 0 ? near - min(near, holes[left].end) : .max
                let toRight = right < holes.count ? holes[right].start - min(holes[right].start, near) : .max
                let index: Int
                if toLeft <= toRight { index = left; left -= 1 } else { index = right; right += 1 }
                if holes[index].length >= length { return index }
            }
            return nil
        }

        /// Le plus proche des trous d'exactement `length` clusters.
        func exactHole(length: UInt32, near: UInt32) -> Int? {
            var best: Extent?
            var bestDistance = UInt32.max
            var index = lowerSize(length)
            while index < bySize.count && bySize[index].length == length {
                let hole = bySize[index]
                let distance = hole.start > near ? hole.start - near : near - hole.start
                if distance < bestDistance { bestDistance = distance; best = hole }
                index += 1
            }
            return best.flatMap { holeIndex(startingAt: $0.start) }
        }

        /// Le plus petit trou qui accepte `length` clusters, s'il est plus petit
        /// que `limit` et ne borde pas `file`.
        func smallerHole(length: UInt32, than limit: UInt32, besides file: Extent) -> Int? {
            let index = lowerSize(length)
            guard index < bySize.count else { return nil }
            let hole = bySize[index]
            guard hole.length < limit, hole.end != file.start, hole.start != file.end else { return nil }
            return holeIndex(startingAt: hole.start)
        }

        /// Prendre `taken` dans le trou `index` ; ce qui en reste reste un trou.
        mutating func take(_ taken: Extent, fromHole index: Int) {
            let hole = holes[index]
            bySize.remove(at: sizeIndex(hole))
            holes.remove(at: index)
            var insertion = index
            if taken.start > hole.start {
                let head = Extent(start: hole.start, length: taken.start - hole.start)
                holes.insert(head, at: insertion)
                insertion += 1
                bySize.insert(head, at: sizeIndex(head))
            }
            if taken.end < hole.end {
                let tail = Extent(start: taken.end, length: hole.end - taken.end)
                holes.insert(tail, at: insertion)
                bySize.insert(tail, at: sizeIndex(tail))
            }
        }

        // MARK: Déplacements et validations

        /// Recopier une plage de `position` dans un trou libre, et retenir ce
        /// qu'elle quitte jusqu'au prochain point de contrôle.
        mutating func relocate(_ position: Int, vcn: UInt32, length: UInt32, to target: Extent, phase: Int) {
            let file = volume.files[position]
            let (source, result) = DefragOperations.relocation(of: file.extents, vcn: vcn,
                                                               length: length, to: target)
            let extents = result.coalesced()
            DefragOperations.gatheredMove(source: source, destination: [target], category: file.category,
                                          contiguous: extents.count <= 1, phase: phase,
                                          partition: partition, bufferBytes: bufferBytes, into: sink)
            pendingCommits.append(([target], position))
            pendingFiles.insert(position)
            volume.relocateHoldingReleased(position, to: extents)
            touched.insert(position)
            sink.moves.filesMoved = touched.count
            report.movedClusters += Int(length)

            movesSinceCheckpoint += 1
            if movesSinceCheckpoint >= strategy.checkpointMoves { checkpoint(phase: phase) }
        }

        /// Le point de contrôle : les validations sont écrites, et ce que les
        /// déplacements ont quitté redevient libre.
        mutating func checkpoint(phase: Int) {
            flush(phase: phase)
            volume.releaseHeldClusters()
            rebuildHoles()
            movesSinceCheckpoint = 0
            report.checkpoints += 1
        }

        /// Les enregistrements de MFT et les secteurs de bitmap des déplacements
        /// en attente, triés et fusionnés quand ils se touchent : quelques
        /// écritures voisines au lieu de deux allers-retours par déplacement.
        mutating func flush(phase: Int) {
            guard !pendingCommits.isEmpty else { return }
            var accesses: [MetadataAccess] = []
            for commit in pendingCommits {
                accesses += partition.commitAccesses(for: commit.extents,
                                                     fileIndex: volume.mftRecord(of: commit.file),
                                                     entrySector: volume.entrySector(of: commit.file),
                                                     validation: sink.nextValidation())
            }
            accesses.sort { $0.lba < $1.lba }
            var merged: [MetadataAccess] = []
            for access in accesses {
                if let last = merged.last, access.lba <= last.lba + last.sectors {
                    let end = max(last.lba + last.sectors, access.lba + access.sectors)
                    merged[merged.count - 1] = MetadataAccess(lba: last.lba, sectors: end - last.lba)
                } else {
                    merged.append(access)
                }
            }
            // Les fichiers déplacés prennent la teinte de leur état validé avec
            // la première écriture : un morceau resté en place gardait celle
            // d'avant.
            let first = sink.mutationMark
            for position in pendingFiles.sorted() {
                let file = volume.files[position]
                let contiguous = file.isContiguous
                for extent in file.extents where !extent.isEmpty {
                    sink.record(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                            category: file.category, contiguous: contiguous))
                }
            }
            for (index, access) in merged.enumerated() {
                let start = index == 0 ? first : sink.mutationMark
                sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: access.lba,
                                        sectors: access.sectors, isWrite: true, issueTime: 0, cluster: nil,
                                        mutationStart: start, mutationCount: sink.mutationMark - start))
            }
            report.metadataWrites += merged.count
            pendingCommits.removeAll(keepingCapacity: true)
            pendingFiles.removeAll(keepingCapacity: true)
        }
    }
}
