import Foundation
import DiskCore

/// Un tassage du volume écrit pour ce projet, et qui ne reproduit aucun outil.
///
/// Il part de ce que les défragmenteurs simulés font mal sur FAT, mesuré sur
/// les douze volumes FAT de la galerie :
///
/// - **Windows 95** range, mais dans l'ordre du parcours de l'arborescence :
///   presque chaque fichier a une destination occupée, et ce qu'il évacue au
///   fond du volume devra en revenir. Il déplace plus que le contenu du
///   volume, et quand le fond est plein il ne sait plus où évacuer ;
/// - **JkDefrag** et **UltraDefrag** n'évacuent personne, donc n'ont rien à
///   faire quand les trous manquent : à 99 % de remplissage, ils ne réparent
///   aucun des fichiers cassés de `gamer-1996` — Windows 95 non plus.
///
/// Le principe tient en une règle : **l'ordre d'arrivée est l'ordre actuel**.
/// Une frontière balaie le volume depuis son début ; tout ce qui est sous elle
/// est rangé — des fichiers d'un seul tenant, bout à bout, et des obstacles
/// immobiles. À la frontière :
///
/// 1. un fichier d'un seul tenant qui y commence **reste où il est** ;
/// 2. un petit trou est comblé au cluster près par des fichiers qui **doivent
///    bouger de toute façon** — en morceaux, ou au-delà de la fin du volume
///    tassé ;
/// 3. sinon, le fichier qui suit le trou **glisse** vers le bas.
///
/// Le glissement est ce qui permet de travailler sans espace libre. Il ne
/// recopie pas le fichier ailleurs pour le ramener : il en déplace un tronçon
/// de la taille du trou, et recommence dans le trou que ce tronçon vient de
/// laisser. Deux clusters libres suffisent à tasser un volume entier. Et le
/// trou grossit en montant, de chaque trou qu'il absorbe : c'est pour le
/// laisser grossir qu'un grand trou n'est pas comblé (`exactFillLimit`), et
/// qu'un fichier qui glisserait en trop de tronçons est poussé au fond du
/// volume (`slideChunkLimit`).
///
/// Trois choses entourent ce balayage :
///
/// - **avant**, chaque fichier en morceaux qui tient dans un trou libre y est
///   recopié d'un seul tenant. Le balayage le traitera comme les autres, au
///   lieu de croiser ses morceaux un à un ;
/// - **les obstacles** — le fichier d'échange, parfois en centaines de
///   morceaux — découpent le volume en fenêtres. Un gros fichier qui ne
///   tiendra dans aucune des fenêtres suivantes passe avant les autres, et le
///   trou qu'on ne peut pas combler devant un obstacle sert de refuge ;
/// - **les validations sont groupées.** Un déplacement vers des clusters déjà
///   libres n'écrit les tables qu'avec les suivants, en une traite, et les
///   clusters qu'il quitte restent retenus d'ici là. Le groupement ne tient
///   que tant qu'il reste de la place : le lot est vidé chaque fois qu'un
///   cluster retenu barre la frontière ou qu'une évacuation manque de place,
///   et c'est plus fréquent quand le volume est plein. Au chantier 24, sur
///   les onze volumes FAT où la passe a du travail, un lot validait de 1,7 à
///   12 déplacements sous 90 % de remplissage, jamais plus de 3,3 au-dessus,
///   et 1,4 sur `gamer-1996`, plein à 99 % : presque un aller-retour du bras
///   jusqu'aux tables par déplacement, comme pour Windows 95. C'est le prix
///   d'avancer sans espace libre.
///
/// D'où une garantie que les outils d'époque n'avaient pas : **aucune écriture
/// ne tombe sur une donnée encore référencée**, pas même sur celles du fichier
/// déplacé. Une coupure de courant au milieu d'une passe laisse un volume
/// cohérent.
struct FrontierCompactionStrategy: DefragStrategy {

    let id = "frontierCompaction"
    let label = String(localized: "strategy.frontierCompaction", defaultValue: "Frontier compaction")

    /// Le même tampon que la passe de Windows 95 : l'écart de durée doit venir
    /// de l'algorithme, pas d'une mémoire plus généreuse.
    var bufferBytes = 256 * 1024

    /// Au-delà de ce nombre de tronçons, un fichier d'un seul tenant ne glisse
    /// pas : il est poussé au fond du volume, et le trou qu'il laisse s'ajoute
    /// à celui de la frontière.
    ///
    /// Glisser coûte une validation par tronçon, donc un aller-retour du bras
    /// jusqu'aux tables ; pousser puis ramener coûte deux fois les données mais
    /// deux validations. Le seuil importe peu tant qu'il existe : de 2 à 16, la
    /// durée cumulée des douze volumes FAT ne varie pas de 2 %.
    var slideChunkLimit: UInt32 = 8

    /// Au-delà de cette taille, un trou n'est plus comblé par une combinaison
    /// de fichiers qui devaient bouger : il est gardé pour faire glisser la
    /// suite.
    ///
    /// Combler un grand trou ramène la frontière à un trou nul, et chaque
    /// fichier qui glisse ensuite le fait en tronçons minuscules. Sans plafond,
    /// `famille-1999` glissait par tronçons de 18 clusters en moyenne. Plafonné
    /// à 16 clusters, sa passe raccourcit d'un quart.
    var exactFillLimit: UInt32 = 16

    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: String(localized: "phase.analyse", defaultValue: "Analysing the volume"),
                        detail: String(localized: "phase.analyse.fat.detail", defaultValue: "Reading the allocation tables and walking the tree")),
        PhaseDescriptor(id: "compact", label: String(localized: "phase.compact", defaultValue: "Packing"),
                        detail: String(localized: "phase.compact.detail", defaultValue: "Every hole filled by a file that had to move, otherwise closed by sliding the next one down")),
        PhaseDescriptor(id: "commit", label: String(localized: "phase.commitFAT", defaultValue: "Writing the allocation tables"),
                        detail: String(localized: "phase.commitFAT.detail", defaultValue: "Full rewrite of the tables and the root")),
        PhaseDescriptor(id: "done", label: String(localized: "phase.done", defaultValue: "Finished"),
                        detail: String(localized: "phase.done.frontier.detail", defaultValue: "The files are in one piece, the free space is at the far end of the volume")),
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
        sink.reserveCapacity(input.files.count * 4)

        DefragOperations.analysis(partition: input.partition,
                                  directoryCount: DefragOperations.directoryCount(of: input),
                                  into: sink)

        var pass = Pass(strategy: self, volume: input, sink: sink)
        pass.repairInHoles(phase: 1)
        pass.compact(phase: 1)
        pass.flush(phase: 1)

        sink.progress = 1
        DefragOperations.final(partition: input.partition, phase: 2, into: sink)

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
            filesAlreadyInPlace: pass.movableCount - pass.touched.count,
            evacuations: pass.report.evacuations + pass.report.parked,
            arrangement: pass.volume.arrangement
        )
        return (plan, pass.report)
    }

    /// Ce que les compteurs communs ne disent pas.
    struct Report {
        var movedClusters = 0
        /// Fichiers en morceaux recopiés d'un seul tenant dans un trou libre,
        /// avant le balayage.
        var repairs = 0
        /// Fichiers posés à la frontière, dans un trou où ils tenaient entiers.
        var pulls = 0
        /// Fichiers rangés à la frontière pièce par pièce : glissements, et
        /// fichiers en morceaux reconstitués sur place.
        var placements = 0
        /// Déplacements unitaires faits pendant ces rangements — un tronçon, un
        /// déplacement, une validation.
        var placementMoves = 0
        /// Morceaux poussés plus haut pour libérer une place, et les clusters
        /// qu'ils pesaient.
        var evacuations = 0
        var evacuatedClusters = 0
        /// Fichiers d'un seul tenant poussés au fond du volume plutôt que de
        /// glisser en trop de tronçons.
        var parked = 0
        /// Écritures groupées des tables : chacune valide un lot de
        /// déplacements.
        var commits = 0
        /// Trous laissés devant un obstacle immobile, faute d'un fichier assez
        /// petit pour y tenir.
        var holesLeft = 0
        /// Fichiers qu'il a fallu renoncer à ranger — plus un seul cluster libre
        /// où pousser ce qui les gênait. Ils deviennent des obstacles.
        var abandoned = 0
    }

    /// Ce qui distingue cette passe du tassage de Windows 95 : le même
    /// résultat, sans remettre le volume dans un autre ordre.
    func summary(of plan: DefragPlan) -> String {
        String(localized: "summary.frontierCompaction",
               defaultValue: "The pass packs the volume in the order it is already in: \(plan.filesMoved) files moved, \(plan.filesAlreadyInPlace) left in place, \(plan.evacuations) evacuations. No write ever lands on data that is still in use.")
    }
}

// MARK: - La passe

extension FrontierCompactionStrategy {

    /// Un fichier en attente, rangé par taille puis par position : ce que la
    /// recherche d'un fichier pour combler un trou a besoin de parcourir.
    struct SizeKey: Comparable {
        let size: UInt32
        let end: UInt32
        let position: Int32

        static func < (a: SizeKey, b: SizeKey) -> Bool {
            (a.size, a.end, a.position) < (b.size, b.end, b.position)
        }
    }

    struct Pass {
        let strategy: FrontierCompactionStrategy
        var volume: DefragVolume
        let sink: OperationSink
        let total: UInt32

        /// Tout ce qui est sous la frontière est rangé.
        var frontier: UInt32 = 0

        /// Fichiers encore à ranger. Leurs clusters sont au-dessus de la
        /// frontière, sauf les morceaux mis à l'abri dans un trou laissé
        /// derrière elle.
        var pending: [Bool]
        var pendingClusters: UInt64 = 0
        var movableCount = 0

        /// Les fichiers en attente, par taille croissante.
        var bySize: [SizeKey] = []
        /// Le cluster qui suit le morceau le plus haut de chaque fichier.
        var highestEnd: [UInt32]
        var fragmented: [Bool]

        /// Ce que la passe ne déplacera pas, fusionné et trié : fichier
        /// d'échange, extents système, zone MFT, fichiers abandonnés.
        var obstacles: [Extent] = []
        /// `obstacleSuffix[i]` : les clusters des obstacles `i...`.
        var obstacleSuffix: [UInt64] = []
        /// `windowSuffix[i]` : la plus grande fenêtre entre deux obstacles
        /// après l'obstacle `i`, fin du volume comprise.
        var windowSuffix: [UInt32] = []

        /// Les trous laissés sous la frontière, devant un obstacle. Ils restent
        /// libres à l'arrivée, mais pendant la passe ils servent de refuge : sur
        /// un volume à deux clusters libres, ils sont **tout** l'espace libre, et
        /// les laisser vides immobiliserait la passe.
        var shelters: [Extent] = []

        /// Les validations en attente : des déplacements faits vers des
        /// clusters qui étaient libres, dont les tables ne sont pas encore
        /// écrites. Les clusters qu'ils ont quittés restent retenus d'ici là.
        var pendingCommits: [(cluster: Int, file: Int,
                              repaint: (extents: [Extent], category: ClusterCategory, contiguous: Bool)?)] = []
        /// Les fichiers qui ont un déplacement dans le lot en cours.
        var committing = Set<Int>()

        var touched = Set<Int>()
        var report = Report()

        init(strategy: FrontierCompactionStrategy, volume: DefragVolume, sink: OperationSink) {
            self.strategy = strategy
            self.volume = volume
            self.sink = sink
            self.total = UInt32(volume.partition.clusterCount)
            pending = Array(repeating: false, count: volume.files.count)
            highestEnd = Array(repeating: 0, count: volume.files.count)
            fragmented = Array(repeating: false, count: volume.files.count)

            var fixed: [Extent] = volume.systemExtents
            if let zone = volume.mftZone, !zone.isEmpty {
                fixed.append(Extent(start: zone.lowerBound, length: zone.upperBound - zone.lowerBound))
            }
            for (position, file) in volume.files.enumerated() {
                guard file.clusterCount > 0 else { continue }
                guard file.isMovable, file.category != .reserved else {
                    fixed.append(contentsOf: file.extents)
                    continue
                }
                pending[position] = true
                pendingClusters += UInt64(file.clusterCount)
                movableCount += 1
                highestEnd[position] = file.extents.map(\.end).max() ?? 0
                fragmented[position] = !file.isContiguous
                bySize.append(SizeKey(size: file.clusterCount, end: highestEnd[position],
                                      position: Int32(position)))
            }
            bySize.sort()
            setObstacles(fixed)
        }

        // MARK: Obstacles

        mutating func setObstacles(_ extents: [Extent]) {
            let sorted = extents.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
            var merged: [Extent] = []
            for extent in sorted {
                if let last = merged.last, extent.start <= last.end {
                    let end = max(last.end, extent.end)
                    merged[merged.count - 1] = Extent(start: last.start, length: end - last.start)
                } else {
                    merged.append(extent)
                }
            }
            obstacles = merged
            obstacleSuffix = Array(repeating: 0, count: merged.count + 1)
            windowSuffix = Array(repeating: 0, count: merged.count + 1)
            for index in stride(from: merged.count - 1, through: 0, by: -1) {
                obstacleSuffix[index] = obstacleSuffix[index + 1] + UInt64(merged[index].length)
                let next = index + 1 < merged.count ? merged[index + 1].start : total
                windowSuffix[index] = max(next - merged[index].end, windowSuffix[index + 1])
            }
        }

        /// Indice du premier obstacle qui finit après `cluster`.
        func obstacleIndex(after cluster: UInt32) -> Int {
            var low = 0, high = obstacles.count
            while low < high {
                let middle = (low + high) / 2
                if obstacles[middle].end <= cluster { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// La fin du volume tassé : la frontière, plus tout ce qui reste à
        /// ranger, plus les obstacles qui ne sont pas encore derrière elle. Un
        /// fichier qui déborde au-delà devra bouger, quoi qu'on fasse.
        var boundary: UInt64 {
            UInt64(frontier) + pendingClusters + obstacleSuffix[obstacleIndex(after: frontier)]
        }

        // MARK: Réparation préalable

        /// Chaque fichier en morceaux qui tient dans un trou libre y est
        /// recopié d'un seul tenant, dans le plus petit trou qui convient.
        ///
        /// Le balayage le retrouvera d'un seul tenant : il le fera glisser ou le
        /// laissera en place, au lieu de pousser ses morceaux un à un à chaque
        /// fois que la frontière en croise un.
        mutating func repairInHoles(phase: Int) {
            var holes: [Extent] = []
            // Sous la frontière, tout est rangé : un trou qui y reste est un
            // refuge, pas une destination.
            var cursor: UInt32 = frontier
            while let run = volume.bitmap.nextFreeRun(from: cursor) {
                holes.append(run)
                cursor = run.end
            }
            holes.sort { ($0.length, $0.start) < ($1.length, $1.start) }
            let candidates = volume.files.indices
                .filter { pending[$0] && fragmented[$0] }
                .sorted { volume.files[$0].clusterCount > volume.files[$1].clusterCount }
            for position in candidates {
                let size = volume.files[position].clusterCount
                var low = 0, high = holes.count
                while low < high {
                    let middle = (low + high) / 2
                    if holes[middle].length < size { low = middle + 1 } else { high = middle }
                }
                guard low < holes.count else { continue }
                let hole = holes.remove(at: low)
                move(position, vcn: 0, to: [Extent(start: hole.start, length: size)], phase: phase)
                report.repairs += 1
                if hole.length > size {
                    let rest = Extent(start: hole.start + size, length: hole.length - size)
                    var index = 0
                    while index < holes.count && (holes[index].length, holes[index].start) < (rest.length, rest.start) {
                        index += 1
                    }
                    holes.insert(rest, at: index)
                }
            }
        }

        // MARK: Balayage

        mutating func compact(phase: Int) {
            while frontier < total && pendingClusters > 0 {
                sink.progress = Double(frontier) / Double(total)

                let index = obstacleIndex(after: frontier)
                let obstacle = index < obstacles.count ? obstacles[index] : nil
                if let obstacle, obstacle.start <= frontier {
                    frontier = obstacle.end
                    continue
                }
                // Jusqu'où un fichier posé à la frontière peut s'étendre.
                let room = (obstacle?.start ?? total) - frontier

                // Les gros fichiers qui ne trouveront plus de fenêtre assez
                // grande entre les obstacles à venir passent avant les autres,
                // qui rempliraient celle-ci sans leur laisser de place.
                if obstacle != nil, let position = urgentFile(obstacle: index, room: room) {
                    if place(position, at: frontier, phase: phase) {
                        finalize(position)
                    } else {
                        abandon(position)
                    }
                    continue
                }

                // Un cluster retenu à la frontière : le lot est validé, et le
                // cluster rendu.
                if !pendingCommits.isEmpty, held(frontier) != nil {
                    flush(phase: phase)
                    continue
                }

                var gap: UInt32 = 0
                if !volume.bitmap.isAllocated(frontier) {
                    gap = min(volume.bitmap.nextFreeRun(from: frontier, limit: room)?.length ?? 0, room)
                    // Devant un obstacle, le trou ne se refermera pas en faisant
                    // glisser la suite : tout ce qui y tient est bon à prendre.
                    // Ailleurs, seulement un petit trou, et au cluster près.
                    let bounded = gap == room
                    if bounded {
                        if fill(gap: gap, mustMove: true, exact: false, phase: phase) { continue }
                    } else if gap <= strategy.exactFillLimit,
                              fill(gap: gap, mustMove: true, exact: true, phase: phase) {
                        continue
                    }
                    if bounded {
                        if fill(gap: gap, mustMove: false, exact: false, phase: phase) { continue }
                        // Rien ne tient devant l'obstacle : le trou reste.
                        report.holesLeft += 1
                        shelters.append(Extent(start: frontier, length: gap))
                        frontier += gap
                        continue
                    }
                }

                var at = frontier + gap
                // Derrière le trou, ce que le lot vient de quitter : on regarde
                // plus loin, pour continuer à remplir le trou sans valider. Plus
                // de trou du tout, et le lot est validé : sur un volume plein,
                // les clusters retenus sont ceux qui manquent pour avancer —
                // attendre coûte 10 % de durée sur `gamer-1996`.
                if !pendingCommits.isEmpty {
                    let end = frontier + room
                    while at < end {
                        if let extent = held(at) { at = extent.end; continue }
                        if !volume.bitmap.isAllocated(at) {
                            at = volume.bitmap.nextFreeRun(from: at, limit: end - at)?.end ?? end
                            continue
                        }
                        break
                    }
                    if at >= end || gap == 0 {
                        flush(phase: phase)
                        continue
                    }
                }
                guard let owner = pendingOwner(of: at) else {
                    // Un cluster occupé qui n'appartient à personne en attente
                    // ne peut être qu'un obstacle — que la recherche aurait dû
                    // trouver. On ne range pas au hasard.
                    return
                }
                let file = volume.files[owner]
                let size = file.clusterCount

                // 1. Déjà à sa place.
                if gap == 0 && !fragmented[owner] && file.extents[0].start == frontier {
                    finalize(owner)
                    continue
                }

                // Un extent peut commencer sous la frontière quand elle a sauté
                // un obstacle qui le recouvrait : la zone MFT courante, sur un
                // volume NTFS qui a débordé dedans. Son fichier n'est pas « juste
                // après le trou » — il n'y en a pas — et se range comme un
                // fichier en morceaux, depuis ce qui dépasse de la frontière.
                let straddling = file.extents.first { $0.start < at && $0.end > at }
                let piece = straddling.map { Extent(start: at, length: $0.end - at) }
                    ?? file.extents.first { $0.start == at } ?? Extent(start: at, length: 1)
                let straddles = straddling != nil
                let target = Extent(start: frontier, length: size)
                let fits = size <= room

                // 2. D'un seul tenant, juste après le trou : il glisse, sauf s'il
                //    faut trop de tronçons pour ça.
                if !fragmented[owner] && !straddles && fits {
                    let chunks = (size + gap - 1) / gap
                    if chunks > strategy.slideChunkLimit {
                        if fill(gap: gap, mustMove: false, exact: true, phase: phase) { continue }
                        if evacuate(owner, piece: piece, above: piece.end, wrapFrom: nil,
                                    far: true, whole: true, phase: phase) {
                            report.evacuations -= 1
                            report.parked += 1
                            sink.moves.evacuations = report.evacuations + report.parked
                            continue
                        }
                    }
                    if place(owner, at: frontier, phase: phase) { finalize(owner); continue }
                    if fill(gap: gap, mustMove: false, exact: false, phase: phase) { continue }
                    abandon(owner)
                    continue
                }

                // 3. En morceaux : le ranger ici, ou pousser plus haut le morceau
                //    qui barre la frontière — ce qui déplace le moins d'autrui.
                if fits {
                    let foreign = foreignClusters(in: target, besides: owner)
                    if foreign <= UInt64(piece.length) {
                        if place(owner, at: frontier, phase: phase) { finalize(owner); continue }
                    } else {
                        // Au fond du volume : posé juste au-dessus, le morceau
                        // serait retrouvé et repoussé à chaque avancée de la
                        // frontière — 70 000 évacuations sur `famille-1999`.
                        if evacuate(owner, piece: piece, above: max(piece.end, target.end),
                                    wrapFrom: piece.end, far: true, phase: phase) {
                            continue
                        }
                        if place(owner, at: frontier, phase: phase) { finalize(owner); continue }
                    }
                    if fill(gap: gap, mustMove: false, exact: false, phase: phase) { continue }
                    abandon(owner)
                    continue
                }

                // 4. Trop gros pour tenir avant l'obstacle. Son morceau part
                //    au-delà, ou à défaut remonte vers l'obstacle, ce qui libère
                //    déjà la frontière.
                if evacuate(owner, piece: piece, above: obstacle?.end ?? total, wrapFrom: piece.end,
                            far: true, phase: phase) {
                    continue
                }
                // Plus de place au-delà : tout l'espace libre est devant la
                // frontière. Un fichier qui tient avant l'obstacle y est rangé,
                // d'un coup s'il tient dans le trou, sinon pièce à pièce en se
                // servant du trou comme d'une navette.
                if fill(gap: gap, mustMove: false, exact: false, phase: phase) { continue }
                if let other = nearestPending(from: at, fitting: room, besides: owner) {
                    if place(other, at: frontier, phase: phase) { finalize(other) } else { abandon(other) }
                    continue
                }
                // Plus personne ne tient avant l'obstacle : la zone est laissée,
                // avec les morceaux qui y restent, et sert de refuge.
                report.holesLeft += 1
                shelters.append(Extent(start: frontier, length: room))
                frontier += room
            }
        }

        /// Le premier fichier en attente, en montant depuis `from`, qui tient
        /// dans `room` clusters.
        func nearestPending(from: UInt32, fitting room: UInt32, besides file: Int) -> Int? {
            let pending = self.pending
            let files = volume.files
            return volume.index.firstExtent(from: from) { position in
                position != file && pending[position] && files[position].clusterCount <= room
            }?.file
        }

        /// Un fichier en attente qui tient avant l'obstacle `index` et qui ne
        /// tiendra dans aucune des fenêtres suivantes, une fois celles-ci
        /// partagées entre les plus gros — rangement « plus gros d'abord ».
        ///
        /// Seuls comptent les fichiers de plus du quart de la plus grande
        /// fenêtre à venir : les autres trouvent toujours leur place.
        func urgentFile(obstacle index: Int, room: UInt32) -> Int? {
            let top = windowSuffix[index]
            guard top > 0, let largest = bySize.last, largest.size > top / 4 else { return nil }
            var capacities: [UInt32] = []
            for later in index..<obstacles.count {
                let next = later + 1 < obstacles.count ? obstacles[later + 1].start : total
                let size = next - obstacles[later].end
                if size > top / 4 { capacities.append(size) }
            }
            capacities.sort(by: >)
            var cursor = bySize.count - 1
            while cursor >= 0 && bySize[cursor].size > top / 4 {
                let key = bySize[cursor]
                cursor -= 1
                if let slot = capacities.firstIndex(where: { $0 >= key.size }) {
                    capacities[slot] -= key.size
                    continue
                }
                let position = Int(key.position)
                let file = volume.files[position]
                guard key.size <= room else { continue }
                if !fragmented[position] && file.extents[0].start == frontier { return nil }
                return position
            }
            return nil
        }

        /// Combler le trou à la frontière de fichiers qui y tiennent entiers.
        ///
        /// - Parameters:
        ///   - mustMove: ne prendre que des fichiers qui devront bouger de
        ///     toute façon — en morceaux, ou au-delà de la fin du volume tassé ;
        ///   - exact: ne rien prendre si la combinaison ne remplit pas le trou
        ///     au cluster près. Sinon, le plus gros qui tient, et un seul.
        mutating func fill(gap: UInt32, mustMove: Bool, exact: Bool, phase: Int) -> Bool {
            guard gap > 0 else { return false }
            let limit = boundary
            var chosen: [Int] = []
            if exact {
                var remaining = gap
                var index = upperIndex(size: gap) - 1
                while index >= 0 && remaining > 0 {
                    let key = bySize[index]
                    if key.size <= remaining
                        && (!mustMove || fragmented[Int(key.position)] || UInt64(key.end) > limit) {
                        chosen.append(Int(key.position))
                        remaining -= key.size
                    }
                    index -= 1
                }
                guard remaining == 0 else { return false }
            } else {
                let fragmented = self.fragmented
                guard let position = largest(upTo: gap, where: { key in
                    !mustMove || fragmented[Int(key.position)] || UInt64(key.end) > limit
                }) else { return false }
                chosen = [position]
            }
            for position in chosen {
                let size = volume.files[position].clusterCount
                move(position, vcn: 0, to: [Extent(start: frontier, length: size)], phase: phase)
                report.pulls += 1
                finalize(position)
            }
            return true
        }

        func upperIndex(size: UInt32) -> Int {
            var low = 0, high = bySize.count
            while low < high {
                let middle = (low + high) / 2
                if bySize[middle].size <= size { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// Le plus gros fichier en attente d'au plus `size` clusters que
        /// `accept` retient ; à taille égale, le plus haut.
        func largest(upTo size: UInt32, where accept: (SizeKey) -> Bool) -> Int? {
            var low = 0, high = bySize.count
            while low < high {
                let middle = (low + high) / 2
                if bySize[middle].size <= size { low = middle + 1 } else { high = middle }
            }
            var index = low - 1
            while index >= 0 {
                if accept(bySize[index]) { return Int(bySize[index].position) }
                index -= 1
            }
            return nil
        }

        /// Le fichier en attente qui occupe `cluster`.
        func pendingOwner(of cluster: UInt32) -> Int? {
            volume.occupants(of: cluster..<(cluster + 1)).first { pending[$0] }
        }

        /// Les clusters de `range` occupés par d'autres fichiers que `file`.
        func foreignClusters(in range: Extent, besides file: Int) -> UInt64 {
            var count: UInt64 = 0
            for other in volume.occupants(of: range.start..<range.end) where other != file {
                for extent in volume.files[other].extents {
                    let start = max(extent.start, range.start)
                    let end = min(extent.end, range.end)
                    if start < end { count += UInt64(end - start) }
                }
            }
            return count
        }

        // MARK: Rangement pièce à pièce

        /// Reconstituer `file` d'un seul tenant à partir de `start`, en ne
        /// déplaçant jamais un cluster que vers un cluster libre.
        ///
        /// La place est remplie dans l'ordre : ce qui y est déjà au bon rang
        /// reste, un cluster libre reçoit la suite du fichier, un cluster
        /// occupé est d'abord vidé. C'est le même geste qui fait glisser un
        /// fichier d'un seul tenant — ses tronçons descendent un par un dans le
        /// trou que le précédent vient de quitter — et qui recolle un fichier
        /// en morceaux.
        ///
        /// `far` pousse ce qui gêne au fond du volume plutôt que juste
        /// au-dessus : quand la suite de la frontière ne suit pas l'ordre du
        /// volume, un voisin poussé juste au-dessus serait repoussé à la place
        /// suivante.
        mutating func place(_ file: Int, at start: UInt32, far: Bool = false, phase: Int) -> Bool {
            let size = volume.files[file].clusterCount
            let end = start + size
            report.placements += 1
            var cursor = start

            while cursor < end {
                let rank = cursor - start
                if let (location, remaining) = physical(of: file, vcn: rank), location == cursor {
                    cursor += min(remaining, end - cursor)
                    continue
                }

                if !volume.bitmap.isAllocated(cursor) {
                    let free = min(volume.bitmap.nextFreeRun(from: cursor, limit: end - cursor)?.length ?? 1,
                                   end - cursor)
                    move(file, vcn: rank, to: [Extent(start: cursor, length: free)], phase: phase)
                    report.placementMoves += 1
                    cursor += free
                    continue
                }

                if !pendingCommits.isEmpty, held(cursor) != nil {
                    flush(phase: phase)
                    continue
                }
                guard let owner = volume.occupants(of: cursor..<(cursor + 1)).first,
                      pending[owner] || owner == file,
                      let extent = volume.files[owner].extents.first(where: { $0.contains(cursor) })
                else { return false }
                let piece = Extent(start: cursor, length: min(extent.end, end) - cursor)

                // Un morceau du fichier lui-même, au mauvais rang : s'il peut
                // aller directement au sien, c'est un déplacement de gagné.
                if owner == file, let pieceVcn = vcn(of: cursor, in: file) {
                    let proper = Extent(start: start + pieceVcn, length: piece.length)
                    if proper.end <= end, volume.bitmap.isFree(proper) {
                        move(file, vcn: pieceVcn, to: [proper], phase: phase)
                        report.placementMoves += 1
                        continue
                    }
                }
                // Près d'ici : ce qui gêne est d'ordinaire un fichier voisin, que
                // la frontière retrouvera tout de suite après.
                guard evacuate(owner, piece: piece, above: end, wrapFrom: piece.end, far: far, phase: phase)
                else { return false }
            }
            return true
        }

        /// Pousser `piece`, un morceau de `file`, vers des clusters libres
        /// au-dessus de `above` — puis, si `wrapFrom` est donné, entre
        /// `wrapFrom` et `above`, et en dernier recours dans les trous laissés
        /// sous la frontière. Autant qu'il y a de place : un morceau évacué en
        /// partie libère déjà son premier cluster.
        mutating func evacuate(_ file: Int, piece: Extent, above: UInt32, wrapFrom: UInt32?,
                               far: Bool, whole: Bool = false, phase: Int) -> Bool {
            guard let pieceVcn = vcn(of: piece.start, in: file) else { return false }
            var destinations = far
                ? DefragOperations.highestFreeRuns(in: volume, downTo: above, need: piece.length,
                                                   avoidingMFTZone: true)
                : freeRuns(from: above, to: total, need: piece.length)
            var found = destinations.reduce(0) { $0 + $1.length }
            if found < piece.length, let wrap = wrapFrom, wrap < above {
                let more = freeRuns(from: wrap, to: above, need: piece.length - found)
                destinations += more
                found += more.reduce(0) { $0 + $1.length }
            }
            var shelter = 0
            while found < piece.length && shelter < shelters.count {
                let hole = shelters[shelter]
                let more = freeRuns(from: hole.start, to: hole.end, need: piece.length - found)
                destinations += more
                found += more.reduce(0) { $0 + $1.length }
                shelter += 1
            }
            guard found > 0, !whole || found == piece.length else {
                guard !pendingCommits.isEmpty else { return false }
                flush(phase: phase)
                return evacuate(file, piece: piece, above: above, wrapFrom: wrapFrom, far: far,
                                whole: whole, phase: phase)
            }
            move(file, vcn: pieceVcn, to: destinations, phase: phase)
            report.evacuations += 1
            sink.moves.evacuations = report.evacuations + report.parked
            report.evacuatedClusters += Int(found)
            return true
        }

        /// Des clusters libres entre `from` et `to`, en montant, jusqu'à `need`.
        /// La zone MFT, libre dans la bitmap, n'en fait pas partie.
        func freeRuns(from: UInt32, to: UInt32, need: UInt32) -> [Extent] {
            var runs: [Extent] = []
            var remaining = need
            var cursor = from
            while remaining > 0, cursor < to,
                  let run = volume.bitmap.nextFreeRun(from: cursor, limit: remaining, before: to) {
                guard run.start < to else { break }
                let end = min(run.end, to)
                cursor = end
                if let zone = volume.mftZone, run.start < zone.upperBound, end > zone.lowerBound {
                    cursor = max(end, zone.upperBound)
                    if run.start < zone.lowerBound {
                        let take = min(zone.lowerBound - run.start, remaining)
                        runs.append(Extent(start: run.start, length: take))
                        remaining -= take
                    }
                    continue
                }
                let take = min(end - run.start, remaining)
                runs.append(Extent(start: run.start, length: take))
                remaining -= take
            }
            return runs
        }

        // MARK: Fichiers

        /// Où se trouve le cluster logique `vcn` de `file`, et combien de
        /// clusters le suivent dans le même extent.
        func physical(of file: Int, vcn: UInt32) -> (UInt32, UInt32)? {
            var offset: UInt32 = 0
            for extent in volume.files[file].extents {
                if vcn < offset + extent.length {
                    return (extent.start + (vcn - offset), extent.length - (vcn - offset))
                }
                offset += extent.length
            }
            return nil
        }

        /// Le rang, dans `file`, du cluster physique `cluster`.
        func vcn(of cluster: UInt32, in file: Int) -> UInt32? {
            var offset: UInt32 = 0
            for extent in volume.files[file].extents {
                if extent.contains(cluster) { return offset + (cluster - extent.start) }
                offset += extent.length
            }
            return nil
        }

        /// Déplacer une plage de `file` vers des clusters libres.
        ///
        /// Les destinations sont prises dans l'ordre : la première reçoit le
        /// début de la plage. La validation attend le lot : d'ici là, les
        /// clusters quittés restent retenus, et aucun déplacement ne peut
        /// écrire dessus. Une coupure avant la validation laisse les tables
        /// pointer sur l'ancienne copie, intacte.
        mutating func move(_ file: Int, vcn: UInt32, to destinations: [Extent], phase: Int) {
            // Un fichier déjà déplacé dans ce lot est validé avant de repartir :
            // sa nuance sur la carte doit être celle du dernier état écrit.
            if committing.contains(file) { flush(phase: phase) }
            let before = volume.files[file]
            var extents = before.extents
            var sources: [Extent] = []
            var offset = vcn
            for destination in destinations {
                let (source, result) = DefragOperations.relocation(of: extents, vcn: offset,
                                                                  length: destination.length,
                                                                  to: destination)
                sources += source
                extents = result
                offset += destination.length
            }
            let length = offset - vcn
            let result = extents.coalesced()
            let contiguous = result.count <= 1

            DefragOperations.move(source: sources, destination: destinations,
                                  category: before.category, contiguous: contiguous, phase: phase,
                                  partition: volume.partition, bufferBytes: strategy.bufferBytes,
                                  into: sink)
            let repaint = contiguous == before.isContiguous || length >= before.clusterCount
                ? nil : (extents: result, category: before.category, contiguous: contiguous)

            let oldKey = SizeKey(size: before.clusterCount, end: highestEnd[file], position: Int32(file))
            pendingCommits.append((Int(destinations[0].start), file, repaint))
            committing.insert(file)
            volume.relocateHoldingReleased(file, to: result)
            highestEnd[file] = result.map(\.end).max() ?? 0
            fragmented[file] = !contiguous
            if pending[file] {
                removeKey(oldKey)
                insertKey(SizeKey(size: before.clusterCount, end: highestEnd[file], position: Int32(file)))
            }
            touched.insert(file)
            sink.moves.filesMoved = touched.count
            report.movedClusters += Int(length)
        }

        /// Écrire les tables pour tous les déplacements du lot, d'une traite.
        ///
        /// Chaque déplacement a sa copie de la table et son entrée de
        /// répertoire à réécrire ; triées et fusionnées quand elles se
        /// touchent, elles tiennent en quelques écritures voisines au début de
        /// la partition, au lieu d'un aller-retour du bras par déplacement.
        mutating func flush(phase: Int) {
            guard !pendingCommits.isEmpty else { return }
            var accesses: [MetadataAccess] = []
            for commit in pendingCommits {
                accesses += volume.partition.commitAccesses(forCluster: commit.cluster,
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
            // Les fichiers dont un déplacement partiel a changé l'état prennent
            // leur nouvelle teinte avec la première écriture des tables.
            let first = sink.mutationMark
            for commit in pendingCommits {
                guard let file = commit.repaint else { continue }
                for extent in file.extents where !extent.isEmpty {
                    sink.record(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                            category: file.category, contiguous: file.contiguous))
                }
            }
            for (position, access) in merged.enumerated() {
                let start = position == 0 ? first : sink.mutationMark
                sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: access.lba,
                                        sectors: access.sectors, isWrite: true, issueTime: 0, cluster: nil,
                                        mutationStart: start, mutationCount: sink.mutationMark - start))
            }
            pendingCommits.removeAll(keepingCapacity: true)
            committing.removeAll(keepingCapacity: true)
            volume.releaseHeldClusters()
            report.commits += 1
        }

        /// L'extent retenu qui contient `cluster`, s'il y en a un.
        func held(_ cluster: UInt32) -> Extent? {
            volume.heldClusters.first { $0.contains(cluster) }
        }

        /// Le fichier est d'un seul tenant à la frontière : il est rangé.
        mutating func finalize(_ file: Int) {
            let size = volume.files[file].clusterCount
            removeKey(SizeKey(size: size, end: highestEnd[file], position: Int32(file)))
            pending[file] = false
            pendingClusters -= UInt64(size)
            frontier = volume.files[file].extents[0].start + size
        }

        /// Plus rien à pousser nulle part : le fichier reste comme il est, et
        /// devient un obstacle comme le fichier d'échange.
        mutating func abandon(_ file: Int) {
            let size = volume.files[file].clusterCount
            removeKey(SizeKey(size: size, end: highestEnd[file], position: Int32(file)))
            pending[file] = false
            pendingClusters -= UInt64(size)
            report.abandoned += 1
            setObstacles(obstacles + volume.files[file].extents)
        }

        mutating func removeKey(_ key: SizeKey) {
            let index = lowerBound(key)
            if index < bySize.count && bySize[index] == key { bySize.remove(at: index) }
        }

        mutating func insertKey(_ key: SizeKey) {
            bySize.insert(key, at: lowerBound(key))
        }

        func lowerBound(_ key: SizeKey) -> Int {
            var low = 0, high = bySize.count
            while low < high {
                let middle = (low + high) / 2
                if bySize[middle] < key { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }
}
