import Foundation
import DiskCore

/// Le rangement intelligent : une passe écrite pour ce projet, qui vise trois
/// mesures à la fois — la durée du démarrage qui suit, les morceaux des
/// fichiers, les trous de l'espace libre — et non l'imitation d'un outil. La
/// durée de la passe n'en fait pas partie : elle reste de l'ordre d'un tassage
/// complet, une fois le contenu du volume déplacé.
///
/// Elle part de trois constats mesurés sur les vingt disques de la galerie :
///
/// - **le tassage à la frontière** laisse déjà sur FAT un volume sans fichier
///   déplaçable en morceaux et d'un seul trou, mais dans l'ordre où il était :
///   le démarrage n'y gagne presque rien ;
/// - **ce qu'un démarrage lit tient en quelques centaines de mégaoctets**, et
///   les poser à la suite, dans l'ordre où il les lit, lui retire jusqu'à
///   12 s sur FAT et 5 s sur NTFS ;
/// - **les trous qui restent** sont presque tous au-delà du dernier fichier
///   tassé, entre des obstacles que personne ne déplace : les morceaux du
///   fichier d'échange sur FAT, de petits métafichiers sur NTFS.
///
/// D'où trois temps :
///
/// 1. **le bloc de démarrage** : en tête du volume — derrière la zone MFT sur
///    NTFS —, chaque élément que lit le démarrage, dans l'ordre de
///    `Layout.ini` (`BootLayout`), répertoires compris. Ce qui occupe la place
///    en est chassé. Sur NTFS, les plus gros fichiers du volume suivent le
///    bloc (`giants`) ;
/// 2. **la queue** : les fenêtres qui suivent la dernière assez grande pour
///    recevoir tout l'espace libre sont remplies d'abord (`tailStart`) ;
/// 3. **le tassage** du reste, dans l'ordre où il est, par le moteur du
///    tassage à la frontière : l'espace libre s'y retrouve d'un seul tenant.
///
/// Une seule stratégie pour les deux formats, comme UltraDefrag et JkDefrag :
/// ce qui change de l'un à l'autre se lit sur le volume au moment de planifier.
/// Le tampon de l'époque — 256 Ko comme l'outil de Windows 95, 4 Mo comme celui
/// de XP —, et sur NTFS les géants, et une zone MFT qu'on cesse de respecter
/// quand les fichiers l'ont déjà prise (`withoutSpentZone`).
struct SmartDefragStrategy: DefragStrategy, BootLayoutConsumer {

    let id = "smart"
    let label = "Rangement intelligent"

    /// Ce que le démarrage lit, dans l'ordre. Sans lui, pas de bloc de
    /// démarrage : la passe se réduit au tassage, queue d'abord.
    var layout: BootLayout?

    /// Le tampon d'un déplacement, sur FAT et sur NTFS.
    static func bufferBytes(for format: VolumeFormat) -> Int {
        format.isFAT ? 256 * 1024 : 4 * 1024 * 1024
    }

    let phases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Lecture des tables, parcours de l'arborescence et de Layout.ini"),
        PhaseDescriptor(id: "boot", label: "Bloc de démarrage",
                        detail: "Ce que lit le démarrage, posé en tête du volume dans l'ordre où il le lit"),
        PhaseDescriptor(id: "compact", label: "Tassage",
                        detail: "La queue du volume remplie, puis le reste tassé derrière le bloc"),
        PhaseDescriptor(id: "commit", label: "Écriture des tables",
                        detail: "Réécriture des tables d'allocation"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Démarrage d'un trait, fichiers d'un seul tenant, espace libre d'un tenant"),
    ]

    func informed(by layout: BootLayout) -> SmartDefragStrategy {
        var copy = self
        copy.layout = layout
        return copy
    }

    func plan(volume input: DefragVolume, into sink: OperationSink) -> DefragPlan {
        let before = input.stats
        let initialRuns = input.categoryRuns()
        sink.reserveCapacity(input.files.count * 4)

        DefragOperations.analysis(partition: input.partition,
                                  directoryCount: DefragOperations.directoryCount(of: input),
                                  into: sink)

        let ntfs = !input.partition.format.isFAT
        var engine = FrontierCompactionStrategy()
        engine.bufferBytes = Self.bufferBytes(for: input.partition.format)
        let volume = ntfs ? Self.withoutSpentZone(input) : input
        var pass = FrontierCompactionStrategy.Pass(strategy: engine, volume: volume, sink: sink)
        var block = layout?.files ?? []
        if ntfs { block += pass.giants().map { pass.volume.files[$0].id } }
        pass.placeBlock(block, phase: 1)
        pass.repairInHoles(phase: 2)
        pass.compactTailFirst(phase: 2)
        pass.flush(phase: 2)

        sink.progress = 1
        DefragOperations.final(partition: input.partition, phase: 3, into: sink)

        return DefragPlan(
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
    }

    /// Le volume, sans sa zone MFT si les fichiers l'ont déjà prise.
    ///
    /// La zone n'est pas une règle du volume mais une réserve : NTFS n'y met
    /// personne tant qu'il reste de la place ailleurs, puis s'en sert. Quand
    /// des fichiers en occupent plus de la moitié, elle ne réserve plus rien,
    /// et les trous laissés entre eux ne sont que des trous : sur `dev-2003`,
    /// plein à 95 %, 585 des 589 qui restaient après la passe. La passe la
    /// tasse alors comme le reste du volume.
    static func withoutSpentZone(_ volume: DefragVolume) -> DefragVolume {
        guard let zone = volume.mftZone, !zone.isEmpty else { return volume }
        var occupied: UInt64 = 0
        for file in volume.files {
            for extent in file.extents where extent.start < zone.upperBound && extent.end > zone.lowerBound {
                occupied += UInt64(min(extent.end, zone.upperBound) - max(extent.start, zone.lowerBound))
            }
        }
        guard occupied * 2 > UInt64(zone.count) else { return volume }
        return DefragVolume(partition: volume.partition, files: volume.files, mftZone: nil,
                            systemExtents: volume.systemExtents)
    }

    func summary(of plan: DefragPlan) -> String {
        String(format: "La passe pose en tête ce que lit le démarrage, dans l'ordre où il le lit, "
               + "puis tasse le reste derrière : %d fichiers déplacés, %d laissés en place, "
               + "%d évacuations.",
               plan.filesMoved, plan.filesAlreadyInPlace, plan.evacuations)
    }
}

// MARK: - Les trois temps

extension FrontierCompactionStrategy.Pass {

    /// Poser à la frontière, dans l'ordre donné, les éléments que nomme
    /// `ids` — identifiants du catalogue.
    ///
    /// Un élément qui ne tient pas avant le prochain obstacle le saute : la
    /// fenêtre qu'il laisse sera comblée par le tassage. Celui qui ne tient
    /// dans aucune fenêtre est laissé au tassage. Le bloc s'arrête dès qu'il
    /// n'y a plus de place pour chasser ce qui gêne — sur `gamer-1993`, plein
    /// à 100 %, avant même d'avoir commencé.
    ///
    /// Une fois posé, le bloc devient un obstacle, et la frontière repart du
    /// début du volume : ce qui suit se tasse autour de lui.
    mutating func placeBlock(_ ids: [UInt32], phase: Int) {
        var positions: [UInt32: Int] = [:]
        for (position, file) in volume.files.enumerated() { positions[file.id] = position }
        let widest = windowSuffix.first ?? total
        var block: [Extent] = []

        // Où finira le bloc, à peu près : ce qui gêne n'est pas chassé en
        // deçà, où il gênerait de nouveau.
        let chosen = ids.compactMap { positions[$0] }.filter { pending[$0] }
        let blockClusters = chosen.reduce(UInt64(0)) { $0 + UInt64(volume.files[$1].clusterCount) }

        for position in chosen where pending[position] {
            let size = volume.files[position].clusterCount
            guard size <= max(widest, obstacles.first?.start ?? total) else { continue }
            var room: UInt32 = 0
            while frontier < total {
                let index = obstacleIndex(after: frontier)
                if index < obstacles.count, obstacles[index].start <= frontier {
                    frontier = obstacles[index].end
                    continue
                }
                room = (index < obstacles.count ? obstacles[index].start : total) - frontier
                if size <= room { break }
                frontier = index < obstacles.count ? obstacles[index].end : total
            }
            guard size <= room else { break }
            let file = volume.files[position]
            if !(file.isContiguous && file.extents[0].start == frontier) {
                let beyond = UInt32(min(UInt64(frontier) + blockClusters + blockClusters / 8, UInt64(total)))
                clear(Extent(start: frontier, length: size), for: position, beyond: beyond, phase: phase)
                guard place(position, at: frontier, far: true, phase: phase) else { break }
            }
            finalize(position)
            block += volume.files[position].extents
        }
        flush(phase: phase)
        setObstacles(obstacles + block)
        frontier = 0
    }

    /// Chasser de `target` ce qui n'est pas `file` et qui y est surtout : chaque
    /// occupant **entier**, dans le plus petit trou qui le contient au-delà de
    /// `beyond`, sinon au-delà de la cible, sinon en morceaux dans les premiers
    /// trous venus. Un occupant qui ne fait que déborder sur la cible reste :
    /// `place` n'en poussera que le morceau qui gêne.
    ///
    /// `place` seul pousse morceau par morceau au fond du volume, et ce qui y
    /// part en morceaux en revient en morceaux : sur `famille-2003`, un fichier
    /// de 1,3 Go finissait en 4 495 morceaux que le tassage ne savait plus
    /// recoller. Et déménager entier un fichier de 500 Mo qui ne mord que d'un
    /// cluster sur la cible faisait déplacer 33 Go à `secretaire-1999`, pour un
    /// volume de 4,5 Go.
    mutating func clear(_ target: Extent, for file: Int, beyond: UInt32, phase: Int) {
        for owner in volume.occupants(of: target.start..<target.end) where owner != file && pending[owner] {
            let size = volume.files[owner].clusterCount
            let inside = volume.files[owner].extents.reduce(UInt32(0)) { sum, extent in
                let start = max(extent.start, target.start)
                let end = min(extent.end, target.end)
                return sum + (start < end ? end - start : 0)
            }
            guard inside * 2 >= size else { continue }
            let hole = smallestHole(size, from: beyond, avoiding: target)
                ?? smallestHole(size, from: target.end, avoiding: target)
            let destinations = hole.map { [Extent(start: $0.start, length: size)] }
                ?? scatteredRuns(size, avoiding: target)
            guard !destinations.isEmpty else { continue }
            move(owner, vcn: 0, to: destinations, phase: phase)
            report.evacuations += 1
            report.evacuatedClusters += Int(size)
        }
    }

    /// Les fichiers qui pèsent plus du quart de l'espace libre, du plus gros au
    /// plus petit.
    ///
    /// Sur NTFS, de petits métafichiers épars découpent la fin du volume en
    /// fenêtres. Le tassage y arrive avec ses plus gros fichiers, et un espace
    /// libre semé en refuges derrière lui : sur `famille-2003`, deux fichiers de
    /// 1,3 Go n'y trouvaient plus de fenêtre à leur taille. Posés juste derrière
    /// le bloc de démarrage, là où la frontière passe de toute façon, ils ne
    /// dépendent plus de ce qui reste à la fin. Les poser d'abord au fond du
    /// volume, fenêtre par fenêtre, a été essayé : 64 Go de va-et-vient sur ce
    /// volume de 40 Go, pour quatre trous de plus.
    func giants() -> [Int] {
        let free = UInt64(volume.bitmap.freeCount)
        return volume.files.indices
            .filter { pending[$0] && UInt64(volume.files[$0].clusterCount) * 4 > free }
            .sorted { volume.files[$0].clusterCount > volume.files[$1].clusterCount }
    }

    /// Tasser le volume, les fenêtres de queue d'abord.
    ///
    /// Un tassage vers le début du volume laisse l'espace libre au-delà du
    /// dernier fichier posé — dans toutes les fenêtres qui suivent, quand des
    /// obstacles découpent la fin du volume : sur `famille-1996`, 95 trous
    /// entre les morceaux du fichier d'échange. Ces fenêtres-là sont donc
    /// balayées d'abord, et remplies de fichiers pris plus bas ; le reste est
    /// tassé ensuite depuis le début, et l'espace libre se retrouve d'un seul
    /// tenant dans la fenêtre choisie (`tailStart`).
    ///
    /// Pendant le premier balayage, tout l'espace libre est en deçà de la
    /// frontière : c'est là qu'on pousse ce qui gêne, comme dans les refuges
    /// qu'un balayage laisse derrière lui. Après lui, la queue n'est plus de la
    /// place mais un obstacle : sans cela, le second balayage comptait sur des
    /// fenêtres pleines, et abandonnait des fichiers faute de place.
    mutating func compactTailFirst(phase: Int) {
        if let start = tailStart() {
            shelters = [Extent(start: 0, length: start)]
            frontier = start
            compact(phase: phase)
            flush(phase: phase)
            setObstacles(obstacles + [Extent(start: start, length: total - start)])
            shelters = []
            frontier = 0
        }
        compact(phase: phase)
    }

    /// Où commencent les fenêtres de queue : celles qui suivent la dernière
    /// fenêtre assez grande pour recevoir tout l'espace libre — à défaut, la
    /// plus grande. `nil` si c'est déjà la dernière.
    func tailStart() -> UInt32? {
        var windows: [Extent] = []
        var cursor: UInt32 = 0
        for obstacle in obstacles {
            if obstacle.start > cursor { windows.append(Extent(start: cursor, length: obstacle.start - cursor)) }
            cursor = max(cursor, obstacle.end)
        }
        if cursor < total { windows.append(Extent(start: cursor, length: total - cursor)) }
        let capacity = windows.reduce(UInt64(0)) { $0 + UInt64($1.length) }
        guard capacity > pendingClusters else { return nil }
        let free = capacity - pendingClusters
        let chosen = windows.lastIndex { UInt64($0.length) >= free }
            ?? windows.indices.max { windows[$0].length < windows[$1].length }
        guard let chosen, chosen + 1 < windows.count else { return nil }
        return windows[chosen + 1].start
    }

    // MARK: Trous

    /// Le plus petit trou libre d'au moins `size` clusters au-dessus de
    /// `from`, hors zone MFT et hors de `target`.
    func smallestHole(_ size: UInt32, from: UInt32, avoiding target: Extent) -> Extent? {
        var best: Extent?
        var cursor = from
        while cursor < total, let run = volume.bitmap.nextFreeRun(from: cursor) {
            cursor = run.end
            var usable = run
            if let zone = volume.mftZone, usable.start < zone.upperBound, usable.end > zone.lowerBound {
                guard usable.end > zone.upperBound else { continue }
                usable = Extent(start: zone.upperBound, length: usable.end - zone.upperBound)
            }
            guard usable.length >= size,
                  usable.end <= target.start || usable.start >= target.end else { continue }
            if best == nil || usable.length < best!.length { best = usable }
            if usable.length == size { break }
        }
        return best
    }

    /// Des clusters libres pour `size` clusters, en montant depuis le début du
    /// volume, hors zone MFT et hors de `target` ; rien s'il n'y en a pas
    /// assez.
    func scatteredRuns(_ size: UInt32, avoiding target: Extent) -> [Extent] {
        var barriers = [target]
        if let zone = volume.mftZone, !zone.isEmpty {
            barriers.append(Extent(start: zone.lowerBound, length: zone.upperBound - zone.lowerBound))
        }
        var runs: [Extent] = []
        var remaining = size
        var cursor: UInt32 = 0
        while remaining > 0, cursor < total, let run = volume.bitmap.nextFreeRun(from: cursor) {
            cursor = run.end
            var pieces = [run]
            for barrier in barriers {
                pieces = pieces.flatMap { piece -> [Extent] in
                    guard piece.start < barrier.end, barrier.start < piece.end else { return [piece] }
                    var kept: [Extent] = []
                    if piece.start < barrier.start {
                        kept.append(Extent(start: piece.start, length: barrier.start - piece.start))
                    }
                    if barrier.end < piece.end {
                        kept.append(Extent(start: barrier.end, length: piece.end - barrier.end))
                    }
                    return kept
                }
            }
            for piece in pieces where remaining > 0 && !piece.isEmpty {
                let take = min(piece.length, remaining)
                runs.append(Extent(start: piece.start, length: take))
                remaining -= take
            }
        }
        return remaining == 0 ? runs : []
    }
}
