import Foundation
import DiskCore

/// Ce qu'un défragmenteur décide de faire d'un volume.
///
/// Le volume, sa géométrie et le coût d'une validation ne dépendent pas de
/// l'outil : ils sont dans `DefragVolume` et `PartitionGeometry`. Ce qui change
/// d'un outil à l'autre, c'est **l'ordre dans lequel les fichiers sont touchés
/// et l'endroit où ils atterrissent** — et c'est cela, plus que le format, qui
/// fait la signature sonore d'une passe :
///
/// - le défragmenteur de Windows 95 tasse tout contre le début du volume dans
///   l'ordre du parcours de l'arborescence, donc évacue sans arrêt et revient
///   au bord du plateau une fois par fichier ;
/// - JkDefrag range le volume en zones et comble les trous par des fichiers
///   pris plus haut, sans jamais évacuer personne ;
/// - une passe NTFS façon `FSCTL_MOVE_FILE` ne touche que les fichiers
///   réellement fragmentés — sur un volume de 2007, quelques centaines sur
///   des dizaines de milliers.
///
/// Une stratégie est une valeur et non un espace de noms : les variantes d'un
/// même outil (analyse seule, optimisation complète, comblement seul) sont des
/// réglages, pas des algorithmes différents.
protocol DefragStrategy: Sendable {

    /// Identifiant stable, pour les réglages et les traces.
    var id: String { get }

    /// L'outil simulé, tel qu'un écran peut le nommer.
    var label: String { get }

    /// Les étapes traversées, dans l'ordre : l'indice d'une phase dans ce
    /// tableau est celui que portent ses opérations.
    var phases: [PhaseDescriptor] { get }

    /// Les mêmes étapes, dites pour le format du volume qu'on écoute.
    ///
    /// Trois outils annonçaient « les derniers enregistrements de MFT et la
    /// bitmap du volume » à l'écriture des métadonnées — sur un FAT16 aussi,
    /// qui n'a pas de MFT : le libellé était en dur, et les douze volumes FAT
    /// du catalogue le portaient (`UX_REVIEW.md` §3). L'ordre et le nombre des
    /// phases ne changent pas, puisque c'est l'indice qui relie une opération
    /// à son étape ; seul ce qu'on en dit change.
    func phases(on format: VolumeFormat) -> [PhaseDescriptor]

    /// Le volume passé n'est pas modifié — une stratégie travaille sur sa
    /// propre copie, où elle rejoue chaque déplacement pour connaître l'état
    /// d'arrivée.
    ///
    /// Les opérations ne sont pas rendues mais **émises**, une à une, dans
    /// `sink` : c'est ce qui permet d'écouter une passe à mesure qu'elle se
    /// planifie. Le plan rendu porte les compteurs et l'état d'arrivée, sans
    /// opérations ni mutations — celles-là, c'est le récepteur qui décide s'il
    /// les garde.
    func plan(volume: DefragVolume, into sink: OperationSink) -> DefragPlan

    /// Ce que les compteurs de la passe veulent dire, en une phrase d'écran.
    ///
    /// Les mêmes nombres ne racontent pas la même histoire selon l'outil.
    /// « 921 évacuations » est la mécanique normale d'un tassage ; « 0
    /// évacuation » n'est pas un tassage qui aurait échoué, c'est le principe
    /// d'un outil qui ne déloge personne. Laisser l'écran commenter lui-même
    /// revenait à lui faire dire, sur une passe XP, que la destination est
    /// « presque toujours occupée » juste au-dessus d'un zéro.
    func summary(of plan: DefragPlan) -> String
}

extension DefragStrategy {

    /// Par défaut, un outil dit ses étapes de la même façon sur tous les
    /// formats : seuls ceux qui nomment une métadonnée ont à redire.
    func phases(on format: VolumeFormat) -> [PhaseDescriptor] { phases }

    /// Toute la passe d'un coup, opérations comprises : ce dont les tests ont
    /// besoin pour relire un plan.
    func plan(volume: DefragVolume) -> DefragPlan {
        let sink = OperationSink()
        let plan = plan(volume: volume, into: sink)
        return plan.with(operations: sink.operations, mutations: sink.mutations)
    }
}

// MARK: - Fabriques d'opérations

/// Ce que toute stratégie a besoin d'émettre : lire une zone, l'écrire
/// ailleurs, valider, et parcourir le volume au départ.
///
/// Rien ici ne décide de *quoi* déplacer ni *où* — ces fonctions ne savent que
/// traduire une décision déjà prise en requêtes bloc et en mutations de la
/// carte. C'est la frontière entre ce qui est commun à tous les défragmenteurs
/// et ce qui les distingue.
enum DefragOperations {

    /// L'analyse lit les tables d'allocation, la racine, puis chaque
    /// répertoire. Elle est étalée sur quelques secondes : à l'époque le coût
    /// dominant n'était pas le disque mais le parcours des chaînes en mémoire.
    /// Ce que l'outil calcule entre deux lectures de l'analyse : après chaque
    /// table, et après chaque répertoire — décoder les entrées, classer les
    /// fichiers. **Une hypothèse** : aucune mesure d'époque n'a été trouvée
    /// pour une analyse de `dfrg.msc`, ni pour celle de `DEFRAG` (la relecture
    /// sur source de `LEDGER-REALISME.md`). Ce qui n'est pas une hypothèse,
    /// c'est le reste de la durée, que fait le disque : la MFT entière et
    /// chaque répertoire là où il est.
    static let tableThinkSeconds = 0.05
    static let directoryThinkSeconds = 0.010

    static func analysis(volume: DefragVolume, into sink: OperationSink) {
        sink.emit(contentsOf: analysis(volume: volume))
    }

    /// L'analyse : les tables — sur NTFS, la bitmap de la MFT, celle du
    /// volume et la MFT —, puis chaque répertoire.
    ///
    /// Longtemps un forfait — la MFT plafonnée à 2 Mo, les répertoires lus à
    /// des clusters tirés au hasard, le tout minuté en dur sur 4,5 s, si bien
    /// qu'un FAT16 de 180 Mo et un NTFS de 320 Go s'analysaient dans la même
    /// poignée de secondes (`LEDGER-REALISME.md`, F4). Ici la MFT se lit là où
    /// le volume l'a posée et en entier, et les répertoires à leurs extents ;
    /// la durée est celle que le disque met à les servir, plus le calcul
    /// ci-dessus. Un volume d'essai qui ne connaît pas ses répertoires les
    /// tire encore au hasard, comme avant.
    static func analysis(volume: DefragVolume) -> [DiskOperation] {
        let partition = volume.partition
        var ops: [DiskOperation] = []
        var t = 0.30

        func read(lba: Int, sectors: Int, cluster: Int?, think: Double) {
            ops.append(DiskOperation(kind: .scan, phase: 0, lba: lba, sectors: sectors,
                                     isWrite: false, issueTime: t, cluster: cluster))
            t += think
        }

        for access in partition.scanAccesses {
            read(lba: access.lba, sectors: access.sectors, cluster: nil, think: tableThinkSeconds)
        }
        if partition.format == .ntfs {
            // Ce que lit `dfrgntfs` de XP, dans son ordre (B#24) : l'attribut
            // `$BITMAP` de la MFT, par `DasdReadClusters` (`GetMftBitmap`,
            // `dfrgntfs.cpp:4588-4613`, appelé à la ligne 1780) ; la bitmap du
            // volume, par `FSCTL_GET_VOLUME_BITMAP` (`GetVolumeBitmap`,
            // `freespace.cpp:1345`, ligne 1832) ; puis la MFT, tampon par
            // tampon, extent après extent (`ScanNtfs`, `dfrgntfs.cpp:5110-5160`).
            // Ni `$LogFile`, ni `$MFTMirr`, ni `$Boot` : l'outil ne lit que ce
            // qui décrit les fichiers et l'espace libre, et apprend le reste
            // du volume par `FSCTL_GET_NTFS_VOLUME_DATA`, que le pilote sert
            // de mémoire. Le modèle lisait jusqu'ici tous les extents système,
            // dont les 64 Mio du journal à chaque passe.
            let layout = partition.ntfsLayout
            for extent in [layout.mftBitmap, layout.bitmap] where !extent.isEmpty {
                read(lba: partition.lba(ofCluster: Int(extent.start)),
                     sectors: Int(extent.length) * partition.clusterSectors,
                     cluster: Int(extent.start), think: tableThinkSeconds)
            }
            // La MFT là où le volume la porte — extent par extent quand elle
            // s'est fragmentée. Un volume qui ne publie pas ses extents la lit
            // d'un bloc à sa place d'origine, un enregistrement par fichier.
            if volume.mftExtents.isEmpty {
                read(lba: partition.mftLBA,
                     sectors: (volume.files.count + 16) * partition.mftRecordSectors,
                     cluster: Int(layout.mftStart), think: tableThinkSeconds)
            } else {
                for extent in volume.mftExtents where !extent.isEmpty {
                    read(lba: partition.lba(ofCluster: Int(extent.start)),
                         sectors: Int(extent.length) * partition.clusterSectors,
                         cluster: Int(extent.start), think: tableThinkSeconds)
                }
            }
        }

        // Parcours des répertoires, là où ils sont : chaque lecture est un
        // seek isolé au milieu du silence, et un répertoire en morceaux en
        // coûte plusieurs.
        let directories = volume.files.filter { $0.category == .directory }
        if directories.isEmpty {
            var rng = SeededGenerator(seed: 0xDEF7_A61C)
            for _ in 0..<directoryCount(of: volume) {
                let cluster = rng.uniform(0...(partition.clusterCount - 1))
                read(lba: partition.lba(ofCluster: cluster), sectors: partition.clusterSectors,
                     cluster: cluster, think: directoryThinkSeconds)
            }
        } else {
            for directory in directories {
                for extent in directory.extents where !extent.isEmpty {
                    read(lba: partition.lba(ofCluster: Int(extent.start)),
                         sectors: Int(extent.length) * partition.clusterSectors,
                         cluster: Int(extent.start), think: 0)
                }
                t += directoryThinkSeconds
            }
        }
        return ops
    }

    /// Déplacement d'une suite d'extents vers une autre, par tampons successifs.
    ///
    /// Chaque tampon est une lecture d'une portion de la source suivie de
    /// l'écriture de la portion de destination correspondante. Les deux
    /// découpages ne coïncident jamais — c'est tout le problème d'un fichier
    /// fragmenté — d'où le pas à pas sur la plus longue portion contiguë des
    /// deux côtés, plafonnée à la taille du tampon.
    ///
    /// `contiguous` dit ce que sera le fichier **une fois déplacé** : c'est
    /// la teinte que prennent sur la carte les clusters écrits.
    ///
    /// `bufferBytes` est ce qui fixe le rythme des allers-retours
    /// lecture/écriture, donc le tempo de la passe : c'est un réglage de l'outil
    /// simulé, pas une constante.
    ///
    /// `fullBlocks` remplace ce découpage par celui de `gatheredMove`.
    ///
    /// `validClusters` : les clusters du fichier qui portent des données
    /// valides, comptés depuis le début du fichier ; `firstVCN`, le rang dans
    /// le fichier du premier cluster de `source`. Un tronçon qui commence
    /// au-delà n'est ni lu ni écrit, seulement réalloué (`moveFile`).
    /// `afterBlock` est appelé après chaque tronçon posé : c'est là que le
    /// pilote de XP valide sa transaction.
    static func move(source: [Extent],
                     destination: [Extent],
                     category: ClusterCategory,
                     contiguous: Bool,
                     phase: Int,
                     partition: PartitionGeometry,
                     bufferBytes: Int,
                     fullBlocks: Bool = false,
                     firstVCN: UInt32 = 0,
                     validClusters: UInt32? = nil,
                     afterBlock: ((MoveChunk) -> Void)? = nil,
                     into sink: OperationSink) {
        if fullBlocks {
            gatheredMove(source: source, destination: destination, category: category,
                         contiguous: contiguous, phase: phase, partition: partition,
                         bufferBytes: bufferBytes, afterBlock: afterBlock, into: sink)
            return
        }
        let buffer = UInt32(max(bufferBytes / partition.clusterBytes, 1))

        // Ce que la destination recouvre de la source : ces clusters-là ne
        // repassent pas en « libre », ils changent simplement de contenu.
        // Triés une fois pour être cherchés par dichotomie : un refuge
        // d'évacuation peut compter des centaines de morceaux, et chaque
        // tronçon déplacé le consulte.
        let kept = destination.count > 1
            ? destination.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
            : destination

        // 1. Les tronçons, dans l'ordre du fichier.
        var chunks: [MoveChunk] = []
        var vcns: [UInt32] = []
        var vcn = firstVCN
        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var destinationIndex = 0
        var destinationOffset: UInt32 = 0
        while sourceIndex < source.count && destinationIndex < destination.count {
            let from = source[sourceIndex]
            let to = destination[destinationIndex]
            let length = min(from.length - sourceOffset, to.length - destinationOffset, buffer)
            guard length > 0 else { break }
            chunks.append(MoveChunk(read: from.start + sourceOffset,
                                    write: to.start + destinationOffset, length: length))
            vcns.append(vcn)
            vcn += length
            sourceOffset += length
            destinationOffset += length
            if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
            if destinationOffset == to.length { destinationIndex += 1; destinationOffset = 0 }
        }

        // 2. Dans l'ordre où ils peuvent l'être sans rien perdre.
        let (order, unordered) = safeOrder(chunks)
        // Au-delà des données valides, le pilote de XP réalloue sans copier
        // (`deviosup.c:10530-10561`) : la carte change, le disque se tait.
        func copies(_ index: Int) -> Bool {
            guard let validClusters else { return true }
            return vcns[index] <= validClusters
        }
        func read(_ index: Int) {
            guard copies(index) else { return }
            let chunk = chunks[index]
            sink.emit(DiskOperation(
                kind: .readExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(chunk.read)),
                sectors: Int(chunk.length) * partition.clusterSectors,
                isWrite: false, issueTime: 0, cluster: Int(chunk.read)))
        }
        func write(_ index: Int) {
            let chunk = chunks[index]
            guard copies(index) else {
                sink.carry(MapMutation(start: Int(chunk.write), count: Int(chunk.length),
                                       category: category, contiguous: contiguous))
                recordFreed(start: chunk.read, length: chunk.length, kept: kept, carried: true, into: sink)
                afterBlock?(chunk)
                return
            }
            let first = sink.mutationMark
            sink.record(MapMutation(start: Int(chunk.write), count: Int(chunk.length),
                                    category: category, contiguous: contiguous))
            recordFreed(start: chunk.read, length: chunk.length, kept: kept, into: sink)
            sink.emit(DiskOperation(
                kind: .writeExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(chunk.write)),
                sectors: Int(chunk.length) * partition.clusterSectors,
                isWrite: true, issueTime: 0, cluster: Int(chunk.write),
                mutationStart: first, mutationCount: sink.mutationMark - first))
            afterBlock?(chunk)
        }
        for index in order {
            read(index)
            write(index)
        }
        // Un cycle — deux morceaux qui s'écrasent l'un l'autre — ne se
        // résout pas tronçon par tronçon : tout ce qui en reste est lu, puis
        // écrit.
        for index in unordered { read(index) }
        for index in unordered { write(index) }
    }

    /// Un tronçon de `move` : ce qu'il lit, où il l'écrit.
    struct MoveChunk: Equatable {
        let read: UInt32
        let write: UInt32
        let length: UInt32
        var readEnd: UInt32 { read + length }
        var writeEnd: UInt32 { write + length }
    }

    /// L'ordre dans lequel copier les tronçons d'un déplacement sans écrire
    /// sur un morceau du fichier que personne n'a encore lu.
    ///
    /// Un tronçon lit sa source puis l'écrit : il peut écraser ce qu'il vient
    /// de lire, ou ce qu'un tronçon précédent a lu, jamais ce qu'un tronçon
    /// suivant lira. Or la destination d'un fichier fragmenté recouvre souvent
    /// ses propres morceaux, et pas toujours dans l'ordre : un morceau posé
    /// plus loin dans le fichier mais plus tôt sur le disque, au début de la
    /// place visée, serait recouvert par le premier tronçon avant d'avoir été
    /// lu. C'est ce qu'un copieur fait d'un chevauchement quand il copie à
    /// l'envers — l'ordre d'un `memmove` —, et c'est ce que fait tout outil qui
    /// ne détruit pas ce qu'il déplace.
    ///
    /// L'ordre du fichier est gardé chaque fois qu'il est sûr, c'est-à-dire
    /// presque toujours ; sinon, un tronçon passe après ceux dont il recouvre
    /// la source, et à contraintes égales le premier dans le fichier passe le
    /// premier. Rend aussi ce qu'un cycle a laissé sans ordre.
    static func safeOrder(_ chunks: [MoveChunk]) -> (order: [Int], unordered: [Int]) {
        let natural = Array(chunks.indices)
        guard chunks.count > 1 else { return (natural, []) }
        let byRead = chunks.indices.sorted { chunks[$0].read < chunks[$1].read }
        // Les tronçons dont la source recoupe l'écriture du tronçon `i`.
        func overwritten(by i: Int) -> [Int] {
            let chunk = chunks[i]
            var low = 0, high = byRead.count
            while low < high {
                let middle = (low + high) / 2
                if chunks[byRead[middle]].readEnd <= chunk.write { low = middle + 1 } else { high = middle }
            }
            var hits: [Int] = []
            while low < byRead.count, chunks[byRead[low]].read < chunk.writeEnd {
                if byRead[low] != i { hits.append(byRead[low]) }
                low += 1
            }
            return hits
        }
        let edges = chunks.indices.map(overwritten)
        guard edges.enumerated().contains(where: { i, later in later.contains { $0 > i } }) else {
            return (natural, [])
        }
        // `j` doit passer avant `i` dès que `i` écrit sur ce que `j` lit.
        var waiting = [Int](repeating: 0, count: chunks.count)
        var unlocks = [[Int]](repeating: [], count: chunks.count)
        for (i, sources) in edges.enumerated() {
            waiting[i] = sources.count
            for j in sources { unlocks[j].append(i) }
        }
        // Les tronçons prêts, le premier du fichier en dernier : on le prend.
        var ready = Array(chunks.indices.filter { waiting[$0] == 0 }.reversed())
        var order: [Int] = []
        order.reserveCapacity(chunks.count)
        while let next = ready.popLast() {
            order.append(next)
            for i in unlocks[next] {
                waiting[i] -= 1
                guard waiting[i] == 0 else { continue }
                var low = 0, high = ready.count
                while low < high {
                    let middle = (low + high) / 2
                    if ready[middle] > i { low = middle + 1 } else { high = middle }
                }
                ready.insert(i, at: low)
            }
        }
        let placed = Set(order)
        return (order, natural.filter { !placed.contains($0) })
    }

    /// Le même déplacement, mais par **blocs pleins** : chaque écriture de
    /// `bufferBytes` est précédée des lectures de tous les morceaux de source
    /// qui la composent.
    ///
    /// `move` coupe ses tampons aux bornes des extents, des deux côtés : un
    /// fichier en dix mille morceaux de 150 Ko s'y recopie en dix mille allers-
    /// retours du bras entre la source et la destination. Un bloc de 16 Mo qui
    /// en rassemble cent se lit en cent lectures voisines, et s'écrit une fois.
    static func gatheredMove(source: [Extent],
                             destination: [Extent],
                             category: ClusterCategory,
                             contiguous: Bool,
                             phase: Int,
                             partition: PartitionGeometry,
                             bufferBytes: Int,
                             afterBlock: ((MoveChunk) -> Void)? = nil,
                             into sink: OperationSink) {
        let buffer = UInt32(max(bufferBytes / partition.clusterBytes, 1))
        let kept = destination.count > 1
            ? destination.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
            : destination

        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var freed: [Extent] = []

        for to in destination where !to.isEmpty {
            var written: UInt32 = 0
            while written < to.length {
                let block = min(to.length - written, buffer)
                var gathered: UInt32 = 0
                freed.removeAll(keepingCapacity: true)
                while gathered < block && sourceIndex < source.count {
                    let from = source[sourceIndex]
                    let length = min(from.length - sourceOffset, block - gathered)
                    let readStart = from.start + sourceOffset
                    sink.emit(DiskOperation(
                        kind: .readExtent, phase: phase,
                        lba: partition.lba(ofCluster: Int(readStart)),
                        sectors: Int(length) * partition.clusterSectors,
                        isWrite: false, issueTime: 0, cluster: Int(readStart)))
                    freed.append(Extent(start: readStart, length: length))
                    gathered += length
                    sourceOffset += length
                    if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
                }
                guard gathered > 0 else { return }

                let writeStart = to.start + written
                let first = sink.mutationMark
                sink.record(MapMutation(start: Int(writeStart), count: Int(gathered),
                                        category: category, contiguous: contiguous))
                for extent in freed {
                    recordFreed(start: extent.start, length: extent.length, kept: kept, into: sink)
                }
                sink.emit(DiskOperation(
                    kind: .writeExtent, phase: phase,
                    lba: partition.lba(ofCluster: Int(writeStart)),
                    sectors: Int(gathered) * partition.clusterSectors,
                    isWrite: true, issueTime: 0, cluster: Int(writeStart),
                    mutationStart: first, mutationCount: sink.mutationMark - first))
                afterBlock?(MoveChunk(read: freed.first?.start ?? writeStart, write: writeStart,
                                      length: gathered))
                written += gathered
            }
        }
    }

    /// Les clusters d'une portion de source qui redeviennent libres : tout ce
    /// qui n'est pas recouvert par la destination du même fichier.
    ///
    /// `kept` est trié par début, sans extent vide ni chevauchement — ce que
    /// sont les extents d'un fichier : au plus un le couvre, et le suivant est
    /// le premier qui commence après.
    ///
    /// Écrit directement dans le récepteur, sans tableau intermédiaire : c'est
    /// appelé à chaque tronçon déplacé, un demi-million de fois sur une passe
    /// de `dev-1999`, et les allocations y coûtaient plus que le calcul.
    private static func recordFreed(start: UInt32, length: UInt32,
                                    kept: [Extent], carried: Bool = false,
                                    into sink: OperationSink) {
        var cursor = start
        let end = start + length

        while cursor < end {
            // Premier extent conservé qui commence après `cursor`.
            var low = 0
            var high = kept.count
            while low < high {
                let middle = (low + high) / 2
                if kept[middle].start <= cursor { low = middle + 1 } else { high = middle }
            }
            // Celui d'avant couvre-t-il `cursor` ?
            if low > 0 && kept[low - 1].end > cursor {
                cursor = min(kept[low - 1].end, end)
                continue
            }
            // Jusqu'où peut-on libérer sans heurter un extent conservé ? Le
            // suivant commence après `cursor` par construction de la
            // dichotomie, et `end` aussi tant que la boucle tourne : la plage
            // n'est jamais vide, et la boucle avance toujours.
            let next = low < kept.count ? kept[low].start : end
            let stop = min(next, end)
            let freed = MapMutation(start: Int(cursor), count: Int(stop - cursor), category: .free)
            if carried { sink.carry(freed) } else { sink.record(freed) }
            cursor = stop
        }
    }

    /// Ce qu'un déplacement partiel lit, et ce que devient la description du
    /// fichier une fois qu'il est fait.
    ///
    /// C'est la seule chose que `move_file(file, vcn, length, lcn)` ajoute au
    /// modèle : jusqu'ici un fichier était déplacé en entier, donc sa nouvelle
    /// description était le simple extent d'arrivée. Ici il faut **couper** la
    /// liste aux bornes de la plage, remplacer le milieu par l'extent
    /// d'arrivée, et garder l'ordre logique — c'est lui, et non l'ordre sur le
    /// plateau, qui dit ce que la tête lira à la suite.
    ///
    /// Écrite pour UltraDefrag, elle sert aussi à JKDefrag, dont `Defragment`
    /// recopie un fichier trop gros par tranches, chacune dans le plus grand
    /// trou du moment.
    static func relocation(of extents: [Extent], vcn: UInt32, length: UInt32,
                           to target: Extent) -> (source: [Extent], result: [Extent]) {
        var source: [Extent] = []
        var result: [Extent] = []
        var inserted = false
        var offset: UInt32 = 0

        for extent in extents {
            let start = offset
            let end = offset + extent.length
            offset = end

            let from = max(start, vcn)
            let to = min(end, vcn + length)
            guard from < to else { result.append(extent); continue }

            if from > start {
                result.append(Extent(start: extent.start, length: from - start))
            }
            source.append(Extent(start: extent.start + (from - start), length: to - from))
            if !inserted { result.append(target); inserted = true }
            if to < end {
                result.append(Extent(start: extent.start + (to - start), length: end - to))
            }
        }
        return (source, result)
    }

    /// Validation d'un déplacement — ce que le format fait payer, et où.
    ///
    /// - Parameter repaint: le fichier entier, quand un déplacement **partiel**
    ///   le fait changer d'état — recollé, ou au contraire coupé. Les morceaux
    ///   qui n'ont pas bougé gardaient la teinte de l'ancien état ; ils prennent
    ///   la nouvelle au moment où le système de fichiers valide le déplacement,
    ///   avec la première écriture de métadonnées.
    ///
    /// - Parameter entrySector: sur FAT, le secteur de répertoire qui porte
    ///   l'entrée du fichier (`DefragVolume.entrySector`).
    static func commit(extents: [Extent],
                       fileIndex: Int,
                       entrySector: Int? = nil,
                       phase: Int,
                       partition: PartitionGeometry,
                       repaint: (extents: [Extent], category: ClusterCategory, contiguous: Bool)? = nil,
                       into sink: OperationSink) {
        var pending = repaint
        let validation = sink.nextValidation()
        // La page de journal que cette validation remplit part avec elle :
        // tout ce qui la précède est sur le disque.
        if partition.format == .ntfs, (validation + 1) % PartitionGeometry.validationsPerLogPage == 0 {
            sink.loggedValidations = validation + 1
        }
        for access in partition.commitAccesses(for: extents, fileIndex: fileIndex,
                                               entrySector: entrySector,
                                               validation: validation) {
            let first = sink.mutationMark
            if let file = pending {
                for extent in file.extents where !extent.isEmpty {
                    sink.record(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                            category: file.category, contiguous: file.contiguous))
                }
                pending = nil
            }
            sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: access.lba,
                                     sectors: access.sectors, isWrite: true,
                                     issueTime: 0, cluster: nil,
                                     mutationStart: first, mutationCount: sink.mutationMark - first))
        }
    }

    // MARK: - Un `FSCTL_MOVE_FILE`

    /// Si le pilote qui porte ce volume est celui de XP SP1, dont le code
    /// fait foi : une transaction par bloc de 64 Kio, des métadonnées écrites
    /// par le *lazy writer*. Vista et 7 gardent le modèle d'avant : une
    /// validation par fichier, écrite aussitôt.
    static func journalsEachBlock(_ partition: PartitionGeometry) -> Bool {
        partition.format == .ntfs && partition.ntfsFormatting == .xp
    }

    /// Le passage du *lazy writer*, en secondes de temps planifié. Le modèle
    /// l'avait déjà pour les installations et les journées de XP
    /// (`InstallEra`, une seconde) ; le détail du vrai — un réveil par
    /// seconde, un huitième des pages sales, le premier passage à 3 s — est
    /// au chantier 51.
    static let lazyWriterInterval = 1.0

    /// Un déplacement demandé par un outil qui passe par `FSCTL_MOVE_FILE` —
    /// XP, JkDefrag, UltraDefrag —, tel que le pilote le joue.
    ///
    /// D'abord `deletePending` : sous XP, se poser sur des clusters tout
    /// juste quittés vide le journal. Puis la copie.
    ///
    /// **Sous XP**, `NtfsDefragFile` copie par blocs de 64 Kio, et chaque bloc
    /// est une transaction : `NtfsReallocateRange` — clusters rendus et pris,
    /// dont les bits sont journalisés page de bitmap par page
    /// (`bitmpsup.c:3068-3080`), *mapping pairs* réécrits — puis
    /// `NtfsCheckpointCurrentTransaction`, un enregistrement de validation
    /// dans `$LogFile` et les raisons USN (`deviosup.c:10614-10618`,
    /// `logsup.c:2979-3014`). Le commit n'est pas écrit en *write-through*
    /// (`logsup.c:2951-2956`) : l'enregistrement de MFT et les pages de
    /// `$Bitmap` sont salis dans le cache, et c'est le *lazy writer* qui les
    /// écrit (`lazyFlush`). LFS, lui, garde les enregistrements en tampon
    /// jusqu'au prochain vidage (`flushLog`). Le modèle compte donc une
    /// validation par bloc — huit remplissent une page de journal, l'ordre de
    /// grandeur d'avant — et marque les pages sales au lieu de les écrire ; le
    /// journal part avec le lazy writer, le point de contrôle de cinq secondes
    /// ou un `DELETE_PENDING`. Au-delà de `validBytes`, la
    /// `ValidDataLength`, un bloc est réalloué sans être lu ni écrit
    /// (`deviosup.c:10530-10561`, « `StartingVcn <= UpperBound` »).
    ///
    /// **Ailleurs** : la copie, puis la validation par fichier (`commit`).
    static func moveFile(source: [Extent], destination: [Extent],
                         category: ClusterCategory, contiguous: Bool, phase: Int,
                         volume: inout DefragVolume, fileIndex: Int, entrySector: Int? = nil,
                         bufferBytes: Int, fullBlocks: Bool = false,
                         firstVCN: UInt32 = 0, validBytes: UInt64? = nil,
                         repaint: (extents: [Extent], category: ClusterCategory, contiguous: Bool)? = nil,
                         into sink: OperationSink) {
        deletePending(target: destination, volume: &volume, phase: phase, into: sink)
        let partition = volume.partition
        guard journalsEachBlock(partition) else {
            move(source: source, destination: destination, category: category,
                 contiguous: contiguous, phase: phase, partition: partition,
                 bufferBytes: bufferBytes, fullBlocks: fullBlocks, into: sink)
            commit(extents: destination, fileIndex: fileIndex, entrySector: entrySector,
                   phase: phase, partition: partition, repaint: repaint, into: sink)
            return
        }
        let clusterBytes = UInt64(partition.clusterBytes)
        let validClusters = validBytes.map { UInt32(($0 + clusterBytes - 1) / clusterBytes) }
        let record = fileIndex
        move(source: source, destination: destination, category: category,
             contiguous: contiguous, phase: phase, partition: partition,
             bufferBytes: bufferBytes, fullBlocks: fullBlocks,
             firstVCN: firstVCN, validClusters: validClusters,
             afterBlock: { chunk in
                 blockTransaction(chunk, fileIndex: record, phase: phase,
                                  partition: partition, into: sink)
             },
             into: sink)
        // Le recoloriage d'un fichier que la transaction recolle ou coupe :
        // avec la prochaine opération, puisqu'aucune écriture de métadonnées
        // ne suit aussitôt.
        if let repaint {
            for extent in repaint.extents where !extent.isEmpty {
                sink.carry(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                       category: repaint.category, contiguous: repaint.contiguous))
            }
        }
    }

    /// Un bloc de `NtfsDefragFile` validé : ses enregistrements de journal,
    /// que LFS garde en tampon, et les pages sales — l'enregistrement de MFT
    /// du fichier, les pages de `$Bitmap` des clusters rendus et pris. Puis
    /// ce que le temps a amené : le point de contrôle, le *lazy writer*.
    private static func blockTransaction(_ chunk: MoveChunk, fileIndex: Int, phase: Int,
                                         partition: PartitionGeometry, into sink: OperationSink) {
        _ = sink.nextValidation()
        sink.journalsLazily = true
        let pageSectors = PartitionGeometry.logPageSectors
        // Quatre enregistrements d'un kilo-octet par page de 4 Ko.
        let recordsPerPage = max(pageSectors / partition.mftRecordSectors, 1)
        let mftPage = partition.mftRecordLBA(fileIndex - fileIndex % recordsPerPage)
        sink.lazyDirty[mftPage] = max(sink.lazyDirty[mftPage] ?? 0, pageSectors)
        // Une page de bitmap couvre 32 768 clusters.
        let clustersPerPage = pageSectors * DriveGeometry.bytesPerSector * 8
        for range in [(chunk.read, chunk.length), (chunk.write, chunk.length)] {
            let first = Int(range.0) / clustersPerPage
            let last = (Int(range.0) + Int(range.1) - 1) / clustersPerPage
            for page in first...last {
                let lba = partition.bitmapLBA + page * pageSectors
                sink.lazyDirty[lba] = max(sink.lazyDirty[lba] ?? 0, pageSectors)
            }
        }
        kernelTick(partition: partition, phase: phase, into: sink)
    }

    /// Ce que le pilote de XP fait de lui-même pendant qu'un outil déplace :
    /// toutes les cinq secondes le **point de contrôle** — le minuteur est
    /// armé tant que le volume est sale (`logsup.c:902-906`,
    /// `verfysup.c:1470-1490`) ; `LfsWriteRestartArea` vide le journal et
    /// réécrit la zone de redémarrage (`restart.c:380-425`) — et chaque
    /// seconde le *lazy writer* (`lazyFlush`).
    static func kernelTick(partition: PartitionGeometry, phase: Int, into sink: OperationSink) {
        let tick = Int(sink.plannedSeconds / NTFSCheckpoints.interval)
        if tick > sink.kernelCheckpoints {
            sink.kernelCheckpoints = tick
            flushLog(partition: partition, phase: phase, into: sink)
            sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: partition.logFileLBA,
                                    sectors: PartitionGeometry.logPageSectors, isWrite: true,
                                    issueTime: 0, cluster: nil))
        }
        lazyFlush(partition: partition, phase: phase, force: false, into: sink)
    }

    /// Ce que LFS n'a pas encore posé : les pages de journal que les
    /// validations ont remplies ou entamées depuis le dernier vidage, d'un
    /// trait dans le fichier circulaire. `LfsWrite` écrit « paresseusement » :
    /// un enregistrement n'est sur le disque qu'après un `LfsFlushToLsn`, un
    /// `LfsForceWrite` ou une réécriture de la zone de redémarrage
    /// (`lfs/write.c:185-190`). La page entamée est réécrite au vidage
    /// suivant.
    static func flushLog(partition: PartitionGeometry, phase: Int, into sink: OperationSink) {
        let validations = sink.validations
        guard validations > sink.loggedValidations else { return }
        let perPage = PartitionGeometry.validationsPerLogPage
        let firstPage = sink.loggedValidations / perPage
        let lastPage = (validations - 1) / perPage
        var page = firstPage
        while page <= lastPage {
            let start = partition.logPage(page)
            var count = 1
            // D'un trait tant que les pages se suivent sur le disque : le
            // journal reboucle à sa fin.
            while page + count <= lastPage,
                  partition.logPage(page + count).lba == start.lba + count * start.sectors {
                count += 1
            }
            sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: start.lba,
                                    sectors: count * start.sectors, isWrite: true,
                                    issueTime: 0, cluster: nil))
            page += count
        }
        sink.loggedValidations = validations
    }

    /// Le *lazy writer* : toutes les `lazyWriterInterval` secondes planifiées,
    /// les pages sales partent dans l'ordre du disque, fusionnées quand elles
    /// se touchent, après le journal — un enregistrement doit être sur le
    /// disque avant la page qu'il décrit (le vidage d'un flux journalisé
    /// passe par `LfsFlushToLsn`).
    static func lazyFlush(partition: PartitionGeometry, phase: Int, force: Bool,
                          into sink: OperationSink) {
        guard !sink.lazyDirty.isEmpty else { return }
        if !force, sink.plannedSeconds - sink.lastLazyFlush < lazyWriterInterval { return }
        var runs: [(lba: Int, sectors: Int)] = []
        for lba in sink.lazyDirty.keys.sorted() {
            let sectors = sink.lazyDirty[lba] ?? 1
            if let last = runs.last, lba <= last.lba + last.sectors {
                runs[runs.count - 1].sectors = max(last.sectors, lba + sectors - last.lba)
            } else {
                runs.append((lba, sectors))
            }
        }
        sink.lazyDirty.removeAll(keepingCapacity: true)
        flushLog(partition: partition, phase: phase, into: sink)
        for run in runs {
            sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: run.lba,
                                    sectors: run.sectors, isWrite: true,
                                    issueTime: 0, cluster: nil))
        }
        sink.lastLazyFlush = sink.plannedSeconds
    }

    /// Réécriture complète des tables, en fin de passe.
    static func final(partition: PartitionGeometry, phase: Int, into sink: OperationSink) {
        // Sous XP, ce que le lazy writer n'a pas encore écrit part d'abord.
        guard sink.journalsLazily else {
            sink.emit(contentsOf: final(partition: partition, phase: phase,
                                        validations: sink.validations))
            return
        }
        // Sous XP, le journal et ce que le lazy writer n'a pas encore écrit
        // partent d'abord ; la page entamée avec eux.
        lazyFlush(partition: partition, phase: phase, force: true, into: sink)
        flushLog(partition: partition, phase: phase, into: sink)
        sink.emit(contentsOf: final(partition: partition, phase: phase, validations: 0))
    }

    /// - Parameter validations: validations de la passe. Sur NTFS, la page de
    ///   journal entamée part avant les tables, sans attendre d'être pleine :
    ///   c'est la règle de l'écriture anticipée.
    static func final(partition: PartitionGeometry, phase: Int,
                      validations: Int = 0) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        if partition.format == .ntfs, validations % PartitionGeometry.validationsPerLogPage != 0 {
            let page = partition.logPage(forValidation: validations - 1)
            ops.append(DiskOperation(kind: .metadata, phase: phase, lba: page.lba,
                                     sectors: page.sectors, isWrite: true,
                                     issueTime: 0, cluster: nil))
        }
        ops += partition.finalAccesses.map {
            DiskOperation(kind: .metadata, phase: phase, lba: $0.lba, sectors: $0.sectors,
                          isWrite: true, issueTime: 0, cluster: nil)
        }
        // Une dernière relecture, pour le point final.
        if let first = partition.finalAccesses.first {
            ops.append(DiskOperation(kind: .scan, phase: phase, lba: first.lba,
                                     sectors: first.sectors, isWrite: false,
                                     issueTime: 0, cluster: nil))
        }
        return ops
    }

    // MARK: - Mesures du volume

    /// Combien de répertoires l'analyse aura à parcourir.
    static func directoryCount(of volume: DefragVolume) -> Int {
        var directories = Set<String>()
        for file in volume.files {
            guard let slash = file.path.lastIndex(of: "\\") else { continue }
            directories.insert(String(file.path[file.path.startIndex..<slash]))
        }
        return max(directories.count, 1)
    }
}

// MARK: - Points de contrôle

/// La cadence des points de contrôle NTFS, vue d'un outil qui passe par
/// `FSCTL_MOVE_FILE` et relit le bitmap du volume.
///
/// Un tel outil ne choisit rien : c'est Windows qui fait le point de contrôle,
/// **toutes les cinq secondes** : le minuteur est armé à −5 s dès qu'un
/// volume est sali, et réarmé à chaque point de contrôle (`FiveSecondsFromNow`,
/// `logsup.c:902-906`, `verfysup.c:1470-1490`) ; à sa fin,
/// `NtfsFreeRecentlyDeallocated` rend les clusters libérés avant lui
/// (`logsup.c:2260, 4500-4533`).
///
/// Ce que cela change dépend du volume. **Hors XP**
/// (`DefragVolume.releaseWaitsForCheckpoint`), les clusters qu'un
/// déplacement quitte sont occupés dans le bitmap que l'outil relit jusqu'au
/// point de contrôle : la règle de Russinovich pour NT 4, gardée pour Vista
/// et 7 faute de source. Les **décisions** d'un outil qui la suit dépendent
/// alors de l'horloge : deux secondes d'analyse en moins décalaient la grille
/// et changeaient le plan (chantier 48). **Sous XP**
/// (`DefragVolume.reusesWithDeletePending`), ces clusters sont libres pour
/// l'outil tout de suite ; le point de contrôle ne décide que de ce que le
/// pilote suit encore, donc des vidages de journal qu'un réemploi coûte
/// (`DefragOperations.deletePending`). Le plan ne dépend plus de l'horloge,
/// seulement le nombre de ces vidages.
///
/// Les outils qui ont leur propre comptabilité en ont une autre, et chacune est
/// un choix : UltraDefrag ne relit sa liste de trous qu'en tête de tour, le
/// recollage économe fait un point de contrôle tous les `checkpointMoves`
/// déplacements, le tassage à la frontière un par lot de validations.
///
/// Le temps est celui de `OperationSink.plannedSeconds`, une estimation. Un
/// point de contrôle qui tombe **pendant** un déplacement libère ce que les
/// déplacements précédents ont quitté, pas ce que celui-ci quitte : il n'est
/// validé qu'à sa fin.
struct NTFSCheckpoints {

    static let interval = 5.0

    private var last = 0.0
    /// Les clusters retenus, ou récemment désalloués sous XP, au moment de la
    /// dernière validation.
    private var heldAtLastCommit = 0

    /// Après chaque validation : si un point de contrôle est tombé depuis la
    /// précédente, ce qu'elle avait laissé retenu redevient libre — ou, sous
    /// XP, cesse d'être suivi par le pilote.
    mutating func afterCommit(_ volume: inout DefragVolume, sink: OperationSink) {
        let waits = volume.releaseWaitsForCheckpoint
        guard waits || volume.reusesWithDeletePending else { return }
        let now = sink.plannedSeconds
        let checkpoint = (now / Self.interval).rounded(.down) * Self.interval
        if checkpoint > last {
            if waits {
                volume.releaseHeldClusters(first: heldAtLastCommit)
            } else {
                volume.forgetRecentlyDeallocated(first: heldAtLastCommit)
            }
            last = checkpoint
        }
        heldAtLastCommit = waits ? volume.heldClusters.count : volume.recentlyDeallocated.count
    }
}

extension DefragOperations {

    /// Sous XP, un `FSCTL_MOVE_FILE` dont la destination recoupe des clusters
    /// récemment désalloués : `STATUS_DELETE_PENDING` au premier bloc, que
    /// `NtfsDefragFile` intercepte ; il prend tous les fichiers, **vide le
    /// journal** jusqu'à son dernier enregistrement (`LfsFlushToLsn(LiMax)`),
    /// rend tous les clusters récemment désalloués
    /// (`NtfsFreeRecentlyDeallocated` avec `CleanVolume`) et recommence
    /// (`deviosup.c:10360-10390, 10661-10671, 10745-10790`). Le déplacement
    /// réussit ; un seul vidage suffit, puisque tout est rendu.
    ///
    /// À appeler **avant** d'émettre le déplacement : le vidage le précède.
    /// Il écrit ce que LFS n'a pas encore posé (`flushLog`) — rien, si le
    /// *lazy writer* vient de le faire.
    ///
    /// - Returns: `true` si le journal a été vidé.
    @discardableResult
    static func deletePending(target: [Extent], volume: inout DefragVolume,
                              phase: Int, into sink: OperationSink) -> Bool {
        guard volume.reusesWithDeletePending, volume.touchesRecentlyDeallocated(target) else { return false }
        flushLog(partition: volume.partition, phase: phase, into: sink)
        volume.forgetRecentlyDeallocated()
        sink.logFlushes += 1
        return true
    }
}

// MARK: - Recherche de trous

extension DefragOperations {

    /// Le premier trou d'au moins `need` clusters, depuis le début du volume.
    ///
    /// La recherche repart de zéro à chaque appel, et ce n'est pas une
    /// négligence : c'est ce que font `FindGap` de JKDefrag comme
    /// `find_first_free_region` d'UltraDefrag, qui relisent le bitmap du volume
    /// à chaque fois plutôt que de le mettre en cache. La conséquence est
    /// visible sur la carte — les fichiers réparés se regroupent vers l'avant,
    /// dans les trous que la passe vient elle-même d'ouvrir — et le coût reste
    /// modeste tant qu'on ne traite que les fichiers cassés. Sur NTFS, ces
    /// trous-là n'apparaissent qu'au point de contrôle (`NTFSCheckpoints`).
    ///
    /// `limit: need` est ce qui évite le piège quadratique : on ne mesure
    /// jamais un trou au-delà de la taille cherchée. Sur un volume presque
    /// vide, le premier trou fait la taille du disque.
    ///
    /// - Parameter avoidingMFTZone: sauter la zone réservée à la MFT. C'est un
    ///   choix **de l'outil**, pas une règle du volume : Windows y laisse
    ///   écrire un défragmenteur. La zone est libre dans la bitmap et fait sur
    ///   un volume de 320 Go quarante gigaoctets d'un seul tenant, donc le plus
    ///   grand trou du volume et de très loin ; un outil qui s'en sert y range
    ///   le premier gros fichier cassé venu, et la MFT se fragmentera à la
    ///   prochaine création de fichier. JkDefrag la saute (`MftExcludes`),
    ///   UltraDefrag s'en sert exprès depuis XP — chaque stratégie le dit.
    static func firstGap(in volume: DefragVolume, need: UInt32,
                         avoidingMFTZone: Bool) -> Extent? {
        let total = UInt32(volume.partition.clusterCount)
        let mftZone = avoidingMFTZone ? volume.mftZone : nil
        var cursor: UInt32 = 0
        while cursor < total {
            guard let run = volume.bitmap.nextFreeRun(from: cursor, limit: need) else { return nil }

            // Un trou qui mord sur la zone MFT est tronqué à ce qui la précède,
            // et la recherche reprend derrière elle.
            if let zone = mftZone, run.start < zone.upperBound, run.start + run.length > zone.lowerBound {
                if run.start < zone.lowerBound, zone.lowerBound - run.start >= need {
                    return Extent(start: run.start, length: need)
                }
                cursor = max(zone.upperBound, run.start + run.length)
                continue
            }

            if run.length >= need { return Extent(start: run.start, length: need) }
            // Le trou est plus court que demandé : `limit` n'a pas tronqué la
            // mesure, il est bien maximal, on peut sauter par-dessus.
            cursor = run.start + run.length
        }
        return nil
    }

    /// Des clusters libres au-dessus de `floor`, en partant du fond du volume,
    /// jusqu'à `need` — moins s'il n'y en a pas assez.
    ///
    /// C'est la zone de manœuvre d'un outil qui évacue : posé au fond, un
    /// fichier délogé n'est plus sur le chemin de ce qui avance depuis le
    /// début du volume. Chaque trou est pris par le haut, et ce qui en reste
    /// en dessous reste d'un tenant.
    static func highestFreeRuns(in volume: DefragVolume, downTo floor: UInt32, need: UInt32,
                                avoidingMFTZone: Bool) -> [Extent] {
        let total = UInt32(volume.partition.clusterCount)
        let mftZone = avoidingMFTZone ? volume.mftZone : nil
        var runs: [Extent] = []
        var remaining = need
        var cursor = total
        while remaining > 0, cursor > floor, let run = volume.bitmap.previousFreeRun(before: cursor) {
            cursor = run.start
            var pieces = [run]
            if let zone = mftZone, run.start < zone.upperBound, run.end > zone.lowerBound {
                pieces = []
                if run.start < zone.lowerBound {
                    pieces.append(Extent(start: run.start, length: zone.lowerBound - run.start))
                }
                if run.end > zone.upperBound {
                    pieces.append(Extent(start: zone.upperBound, length: run.end - zone.upperBound))
                }
            }
            for piece in pieces.reversed() {
                let start = max(piece.start, floor)
                guard start < piece.end, remaining > 0 else { continue }
                let take = min(piece.end - start, remaining)
                runs.append(Extent(start: piece.end - take, length: take))
                remaining -= take
            }
        }
        return runs
    }

    /// Le plus grand trou du volume — `find_largest_free_region`
    /// d'UltraDefrag —, zone MFT exclue ou non comme pour `firstGap`.
    ///
    /// Il ne sert pas à placer quoi que ce soit mais à **borner une ambition** :
    /// la défragmentation partielle ne fusionne jamais plus de clusters qu'il
    /// n'en tient dans le plus grand trou disponible, faute de quoi elle
    /// planifierait un déplacement qui n'a nulle part où aller.
    ///
    /// Contrairement à `firstGap`, cette mesure balaie tout le volume : c'est
    /// le seul endroit de la couche où un appel coûte proportionnellement à la
    /// taille du disque, et c'est pour cela qu'il n'est fait qu'une fois par
    /// tour de boucle et jamais par fichier.
    static func largestGap(in volume: DefragVolume, avoidingMFTZone: Bool) -> Extent? {
        let total = UInt32(volume.partition.clusterCount)
        let mftZone = avoidingMFTZone ? volume.mftZone : nil
        var best: Extent?
        var cursor: UInt32 = 0
        while cursor < total {
            guard var run = volume.bitmap.nextFreeRun(from: cursor) else { break }

            if let zone = mftZone, run.start < zone.upperBound, run.end > zone.lowerBound {
                // Ce qui précède la zone compte, ce qu'elle couvre est interdit,
                // et la mesure reprend derrière elle.
                if run.start < zone.lowerBound {
                    let head = Extent(start: run.start, length: zone.lowerBound - run.start)
                    if best == nil || head.length > best!.length { best = head }
                }
                cursor = max(zone.upperBound, run.end)
                if run.end > zone.upperBound {
                    run = Extent(start: zone.upperBound, length: run.end - zone.upperBound)
                    if best == nil || run.length > best!.length { best = run }
                }
                continue
            }

            if best == nil || run.length > best!.length { best = run }
            cursor = run.end
        }
        return best
    }
}
