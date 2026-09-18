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
    static func analysis(partition: PartitionGeometry,
                         directoryCount: Int,
                         into sink: OperationSink) {
        sink.emit(contentsOf: analysis(partition: partition, directoryCount: directoryCount))
    }

    static func analysis(partition: PartitionGeometry,
                         directoryCount: Int) -> [DiskOperation] {
        var ops: [DiskOperation] = []
        let span = 4.5

        for (index, access) in partition.scanAccesses.enumerated() {
            ops.append(DiskOperation(kind: .scan, phase: 0, lba: access.lba,
                                     sectors: access.sectors, isWrite: false,
                                     issueTime: 0.30 + 0.45 * Double(index),
                                     cluster: nil))
        }

        // Parcours des répertoires : leurs clusters sont dispersés dans la zone
        // de données, chaque lecture est un seek isolé au milieu du silence.
        var rng = SeededGenerator(seed: 0xDEF7_A61C)
        let count = max(directoryCount, 1)
        for index in 0..<count {
            let t = 2.0 + span * Double(index) / Double(count) * 0.55
            let cluster = rng.uniform(0...(partition.clusterCount - 1))
            ops.append(DiskOperation(kind: .scan, phase: 0,
                                     lba: partition.lba(ofCluster: cluster),
                                     sectors: partition.clusterSectors, isWrite: false,
                                     issueTime: t, cluster: cluster))
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
    static func move(source: [Extent],
                     destination: [Extent],
                     category: ClusterCategory,
                     contiguous: Bool,
                     phase: Int,
                     partition: PartitionGeometry,
                     bufferBytes: Int,
                     fullBlocks: Bool = false,
                     into sink: OperationSink) {
        if fullBlocks {
            gatheredMove(source: source, destination: destination, category: category,
                         contiguous: contiguous, phase: phase, partition: partition,
                         bufferBytes: bufferBytes, into: sink)
            return
        }
        let buffer = UInt32(max(bufferBytes / partition.clusterBytes, 1))

        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var destinationIndex = 0
        var destinationOffset: UInt32 = 0

        // Ce que la destination recouvre de la source : ces clusters-là ne
        // repassent pas en « libre », ils changent simplement de contenu.
        // Triés une fois pour être cherchés par dichotomie : un refuge
        // d'évacuation peut compter des centaines de morceaux, et chaque
        // tronçon déplacé le consulte.
        let kept = destination.count > 1
            ? destination.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
            : destination

        while sourceIndex < source.count && destinationIndex < destination.count {
            let from = source[sourceIndex]
            let to = destination[destinationIndex]
            let length = min(from.length - sourceOffset, to.length - destinationOffset, buffer)
            guard length > 0 else { break }

            let readStart = from.start + sourceOffset
            let writeStart = to.start + destinationOffset

            sink.emit(DiskOperation(
                kind: .readExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(readStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: false, issueTime: 0, cluster: Int(readStart)))

            let first = sink.mutationMark
            sink.record(MapMutation(start: Int(writeStart), count: Int(length),
                                    category: category, contiguous: contiguous))
            recordFreed(start: readStart, length: length, kept: kept, into: sink)

            sink.emit(DiskOperation(
                kind: .writeExtent, phase: phase,
                lba: partition.lba(ofCluster: Int(writeStart)),
                sectors: Int(length) * partition.clusterSectors,
                isWrite: true, issueTime: 0, cluster: Int(writeStart),
                mutationStart: first, mutationCount: sink.mutationMark - first))

            sourceOffset += length
            destinationOffset += length
            if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
            if destinationOffset == to.length { destinationIndex += 1; destinationOffset = 0 }
        }
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
                                    kept: [Extent], into sink: OperationSink) {
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
            sink.record(MapMutation(start: Int(cursor), count: Int(stop - cursor),
                                    category: .free))
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
    static func commit(cluster: Int,
                       fileIndex: Int,
                       entrySector: Int? = nil,
                       phase: Int,
                       partition: PartitionGeometry,
                       repaint: (extents: [Extent], category: ClusterCategory, contiguous: Bool)? = nil,
                       into sink: OperationSink) {
        var pending = repaint
        for access in partition.commitAccesses(forCluster: cluster, fileIndex: fileIndex,
                                               entrySector: entrySector,
                                               validation: sink.nextValidation()) {
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

    /// Réécriture complète des tables, en fin de passe.
    static func final(partition: PartitionGeometry, phase: Int, into sink: OperationSink) {
        sink.emit(contentsOf: final(partition: partition, phase: phase,
                                    validations: sink.validations))
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
/// `FSCTL_MOVE_FILE` et relit le bitmap du volume à chaque recherche de trou.
///
/// Un tel outil ne choisit rien : c'est Windows qui fait le point de contrôle,
/// **toutes les cinq secondes** (« NTFS writes checkpoint every 5 sec », dans
/// le chapitre sur la reprise de NTFS des supports de *Windows Internals*),
/// « every few seconds » pour Russinovich. Entre deux, les clusters qu'un
/// déplacement quitte sont occupés dans le bitmap que l'outil relit, et un
/// déplacement vers eux échouerait. C'est la cadence du défragmenteur de XP et
/// de JkDefrag.
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
    /// Les clusters retenus au moment de la dernière validation.
    private var heldAtLastCommit = 0

    /// Après chaque validation : si un point de contrôle est tombé depuis la
    /// précédente, ce qu'elle avait laissé retenu redevient libre.
    mutating func afterCommit(_ volume: inout DefragVolume, sink: OperationSink) {
        guard volume.releaseWaitsForCheckpoint else { return }
        let now = sink.plannedSeconds
        let checkpoint = (now / Self.interval).rounded(.down) * Self.interval
        if checkpoint > last {
            volume.releaseHeldClusters(first: heldAtLastCommit)
            last = checkpoint
        }
        heldAtLastCommit = volume.heldClusters.count
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
