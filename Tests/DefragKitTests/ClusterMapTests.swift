import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que la carte des clusters doit au volume qu'elle représente.
///
/// La vue n'est qu'un pavage de rectangles ; tout ce qu'elle montre se décide
/// dans le rejeu — quel cluster tombe dans quel bloc, quelle catégorie l'emporte
/// dans un bloc, et ce qu'on voit quand on fait défiler la passe en arrière.
/// Ces invariants-là comptent d'autant plus que la grille n'est plus figée : le
/// plein écran en demandera une bien plus fine, et rien ne doit changer ailleurs
/// que dans la finesse du dessin.
@Suite("Carte des clusters")
struct ClusterMapTests {

    private static let categoryCount = ClusterCategory.allCases.count

    /// Un volume mité, fabriqué exactement comme dans les tests du
    /// planificateur : des fichiers en deux morceaux éloignés, de sorte que la
    /// passe ait vraiment de quoi brasser la carte.
    private static func volume(clusterCount: Int = 20_000, files: Int = 200) -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                          clusterSectors: 8, format: .fat16)
        let categories: [ClusterCategory] = [.system, .application, .document, .churn]
        let records: [DefragFile] = (0..<files).map { index in
            let head = UInt32(index) * 40 + 7
            let tail = UInt32(clusterCount / 2 + index * 30)
            return DefragFile(id: UInt32(index), path: "\\DIR\\F\(index).DAT",
                              category: categories[index % categories.count],
                              walkOrder: index,
                              extents: [Extent(start: head, length: 6),
                                        Extent(start: tail, length: 4)],
                              isMovable: true)
        }
        return DefragVolume(partition: partition, files: records)
    }

    private static func plan(clusterCount: Int = 20_000, files: Int = 200) -> DefragPlan {
        DefragPlanner.plan(volume: volume(clusterCount: clusterCount, files: files))
    }

    /// Le compilateur de scénarios date les mutations depuis la chronologie
    /// mécanique ; il vit dans l'application et n'est pas compilé ici. Une date
    /// régulière suffit à tout ce qu'on vérifie : le rejeu ne connaît des
    /// instants que leur ordre.
    private static func timeline(from plan: DefragPlan, step: Double = 0.01) -> ClusterMapTimeline {
        let mutations = plan.mutations.enumerated().map { position, mutation in
            TimedMutation(time: Double(position + 1) * step,
                          start: mutation.start,
                          count: mutation.count,
                          category: mutation.category.rawValue)
        }
        return ClusterMapTimeline(clusterCount: plan.partition.clusterCount,
                                  initialRuns: plan.initialRuns,
                                  mutations: mutations)
    }

    /// Fin de la passe, avec de la marge : rejouer au-delà ne fait plus rien.
    private static func endTime(_ timeline: ClusterMapTimeline) -> Double {
        (timeline.mutations.last?.time ?? 0) + 1
    }

    // MARK: - Le décompte

    /// Un bloc prend la nuance « d'un seul tenant » quand la majorité des
    /// clusters de sa catégorie dominante l'est.
    @Test("La nuance d'un bloc suit la majorité de sa catégorie")
    func contiguousMajority() {
        let player = ClusterMapPlayer(grid: MapGrid(columns: 2, rows: 1))
        let document = ClusterCategory.document.rawValue
        player.load(clusterCount: 200, initialRuns: [
            MapRun(start: 0, count: 60, category: document, contiguous: true),
            MapRun(start: 60, count: 40, category: document),
            MapRun(start: 100, count: 30, category: document, contiguous: true),
            MapRun(start: 130, count: 70, category: document),
        ])
        #expect(player.shades(at: 0).map(\.contiguous) == [true, false])

        // Un fichier recollé repeint le second bloc sans en changer le décompte.
        player.enqueue([TimedMutation(time: 1, start: 130, count: 70,
                                      category: document, contiguous: true)])
        #expect(player.shades(at: 1).map(\.contiguous) == [true, true])
        #expect(player.tallyTotal == 200)
    }

    /// Chaque catégorie n'a ici qu'un fichier : sur la carte rejouée, ses
    /// plages sont donc exactement ce fichier, et la nuance qu'elles portent
    /// doit dire s'il est d'un seul tenant, après chaque déplacement validé.
    @Test("À la fin de la passe, la nuance dit l'état réel de chaque fichier",
          arguments: DefragPlanner.all.map(\.id))
    func contiguityAfterPass(strategyID: String) throws {
        let strategy = try #require(DefragPlanner.strategy(named: strategyID))
        let fat = [Windows95Strategy().id, FrontierCompactionStrategy().id]
        let format: VolumeFormat = fat.contains(strategyID) ? .fat16 : .ntfs
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 4_000,
                                          clusterSectors: 8, format: format)
        let categories: [ClusterCategory] = [.system, .application, .document, .archive, .churn]
        var records: [DefragFile] = categories.enumerated().map { index, category in
            // Quatre morceaux entrelacés avec ceux des autres, et de tailles
            // inégales pour que les défragmenteurs partiels aient à choisir.
            let extents = (0..<4).map { piece in
                Extent(start: UInt32(1_000 + piece * 500 + index * 90),
                       length: UInt32(20 + (index * 7 + piece * 13) % 60))
            }
            return DefragFile(id: UInt32(index), path: "\\DIR\\F\(index).DAT",
                              category: category, walkOrder: index,
                              extents: extents, isMovable: true)
        }
        records.append(DefragFile(id: 9, path: "\\PAGEFILE.SYS", category: .swap,
                                  walkOrder: 9, extents: [Extent(start: 3_600, length: 50)],
                                  isMovable: false))
        let volume = DefragVolume(partition: partition, files: records)
        let sink = OperationSink()
        let plan = strategy.plan(volume: volume, into: sink)
            .with(operations: sink.operations, mutations: sink.mutations)

        var map = ClusterRunMap(clusterCount: partition.clusterCount, occupied: volume.categoryRuns())
        var validations = 0
        for operation in plan.operations {
            let start = Int(operation.mutationStart)
            for mutation in plan.mutations[start..<start + Int(operation.mutationCount)] {
                map.replace(start: mutation.start, count: mutation.count,
                            category: mutation.category.rawValue,
                            contiguous: mutation.contiguous) { _ in }
            }
            // Entre la première écriture et la validation, un fichier en cours
            // de déplacement est à la fois ici et là : on ne juge qu'une fois
            // le déplacement validé, ce qui vaut aussi pour la fin de la passe.
            guard operation.kind == .metadata else { continue }
            validations += 1
            let runs = map.runs()
            for category in categories + [.swap] {
                let pieces = runs.filter { $0.category == category.rawValue }
                let extents = pieces.map { Extent(start: $0.start, length: $0.count) }.coalesced()
                #expect(!pieces.isEmpty, "\(category)")
                #expect(pieces.allSatisfy { $0.contiguous == (extents.count == 1) },
                        "\(strategyID), validation \(validations) : \(category) en \(extents.count) morceau(x)")
            }
        }
        #expect(validations > 0)
    }

    /// L'invariant qui tient tout le reste : le décompte par bloc est une
    /// partition des clusters. Une mutation qui décrémenterait la mauvaise
    /// catégorie, ou un cluster tombé hors grille, s'y verrait immédiatement —
    /// et sur l'écran, sous la forme d'un bloc qui garde une couleur périmée.
    @Test("Le décompte des blocs totalise exactement les clusters de la carte")
    func tallyCountsEveryCluster() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)

        for grid in [MapGrid.standard, MapGrid(columns: 192, rows: 108), MapGrid(columns: 4, rows: 3)] {
            let player = ClusterMapPlayer(grid: grid)
            player.load(timeline)
            #expect(player.tallyTotal == timeline.clusterCount)

            // Et il le reste tout au long de la passe, mutation après mutation.
            for time in stride(from: 0.0, through: Self.endTime(timeline), by: 1.0) {
                _ = player.cells(at: time)
                #expect(player.tallyTotal == timeline.clusterCount,
                        "à \(time) s sur une grille \(grid.columns)×\(grid.rows)")
            }
        }
    }

    // MARK: - Le rejeu

    /// Le rejeu ne revient plus en arrière : il n'a gardé ni la carte de
    /// départ ni les mutations passées. Demander un instant antérieur doit
    /// laisser la carte exactement où elle en est — et surtout ne pas la
    /// corrompre pour la suite.
    @Test("Un instant antérieur ne rembobine pas la carte")
    func earlierInstantLeavesTheMapAlone() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let player = ClusterMapPlayer()
        player.load(timeline)

        let instant = Self.endTime(timeline) * 0.6
        let reference = player.cells(at: instant)

        #expect(player.cells(at: 0) == reference)
        #expect(player.cells(at: instant * 0.2) == reference)
        #expect(player.cells(at: instant) == reference)

        // Et la suite de la passe tombe sur ce qu'aurait vu un player qui n'a
        // jamais regardé en arrière.
        let end = Self.endTime(timeline)
        let fresh = ClusterMapPlayer()
        fresh.load(timeline)
        #expect(player.cells(at: end) == fresh.cells(at: end))
    }

    /// C'est ainsi que la carte est nourrie pendant l'écoute : quelques
    /// secondes de mutations à la fois, reçues en avance, entrecoupées
    /// d'images. Le découpage ne doit rien changer à l'arrivée.
    @Test("Des mutations reçues par paquets donnent la carte de la passe entière")
    func chunkedMutationsMatchTheWholePass() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let end = Self.endTime(timeline)

        let streamed = ClusterMapPlayer()
        streamed.load(clusterCount: timeline.clusterCount, initialRuns: timeline.initialRuns)
        let mutations = timeline.mutations
        var cursor = 0
        var time = 0.0
        while cursor < mutations.count {
            let next = min(cursor + 97, mutations.count)
            streamed.enqueue(Array(mutations[cursor..<next]))
            cursor = next
            time += 0.5
            _ = streamed.cells(at: time)
            #expect(streamed.tallyTotal == timeline.clusterCount)
        }

        let whole = ClusterMapPlayer()
        whole.load(timeline)
        #expect(streamed.cells(at: end) == whole.cells(at: end))
        #expect(streamed.pendingCount == 0)
    }

    /// Le rejeu avance par petits pas soixante fois par seconde ; il doit
    /// arriver au même endroit qu'un saut direct, sans quoi la carte de fin de
    /// passe dépendrait de la façon dont on y est venu.
    @Test("Avancer image par image donne la même carte qu'un saut direct")
    func steppingMatchesSeeking() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let end = Self.endTime(timeline)

        let stepping = ClusterMapPlayer()
        stepping.load(timeline)
        var time = 0.0
        while time < end {
            _ = stepping.cells(at: time)
            time += 1.0 / 60
        }

        let seeking = ClusterMapPlayer()
        seeking.load(timeline)
        #expect(stepping.cells(at: end) == seeking.cells(at: end))
    }

    /// La carte ne refait sa réduction que lorsqu'une mutation est tombée, et
    /// seulement pour les blocs que cette mutation a touchés. Le risque d'un tel
    /// cache est un bloc figé sur une couleur périmée ; on compare donc, une
    /// image sur deux, à un player neuf qui ne peut rien avoir retenu — et on
    /// vérifie que le cache sert vraiment, sans quoi il ne ferait que coûter.
    /// Oublier un seul bloc touché par image suffit à faire échouer ce test.
    @Test("Une image sans mutation reprend la carte de l'image d'avant, jamais une carte périmée")
    func unchangedFramesReuseTheReduction() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let end = Self.endTime(timeline)

        let player = ClusterMapPlayer()
        player.load(timeline)
        var frames = 0
        var reductions = 0
        var previous = player.shades(at: 0)
        var revision = player.revision
        var time = 0.0
        while time < end {
            time += 1.0 / 60
            frames += 1
            let shades = player.shades(at: time)
            if player.revision == revision {
                // Le même stockage, pas seulement le même contenu : c'est ce
                // qui dispense la vue de comparer seize mille blocs.
                let same = shades.withUnsafeBufferPointer { a in
                    previous.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
                }
                #expect(same, "à \(time) s")
            } else {
                reductions += 1
            }
            if frames % 2 == 0 {
                let fresh = ClusterMapPlayer()
                fresh.load(timeline)
                #expect(shades == fresh.shades(at: time), "à \(time) s")
            }
            previous = shades
            revision = player.revision
        }
        // Le petit volume des tests mute presque à chaque image ; le cache doit
        // tout de même avoir servi.
        #expect(reductions > 0)
        #expect(reductions < frames, "\(reductions) réductions pour \(frames) images")

        // Changer de grille invalide aussi.
        let fine = MapGrid(columns: 96, rows: 54)
        player.setGrid(fine)
        #expect(player.shades(at: end).count == fine.cellCount)
    }

    // MARK: - La grille

    /// Changer de grille ne change pas l'état du disque, seulement la finesse
    /// avec laquelle on le regarde : y revenir doit redonner l'image exacte, et
    /// non une image reconstruite de mémoire.
    @Test("Changer de grille puis revenir redonne les mêmes cellules")
    func gridRoundTripPreservesCells() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let player = ClusterMapPlayer()
        player.load(timeline)

        let instant = Self.endTime(timeline) * 0.45
        let reference = player.cells(at: instant)
        #expect(reference.count == MapGrid.standard.cellCount)

        let fine = MapGrid(columns: 192, rows: 108)
        player.setGrid(fine)
        let fineCells = player.cells(at: instant)
        #expect(fineCells.count == fine.cellCount)

        player.setGrid(.standard)
        #expect(player.cells(at: instant) == reference)

        // Et l'image fine ne dépend pas non plus du chemin par lequel on y est
        // arrivé : un player né avec cette grille voit la même chose.
        let born = ClusterMapPlayer(grid: fine)
        born.load(timeline)
        #expect(born.cells(at: instant) == fineCells)
    }

    /// Le plein écran changera de grille au milieu d'une passe, sans revenir au
    /// début : l'avancement du rejeu doit survivre au changement.
    @Test("Changer de grille en cours de passe ne rembobine pas le rejeu")
    func gridChangeKeepsPosition() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let instant = Self.endTime(timeline) * 0.5

        let switched = ClusterMapPlayer()
        switched.load(timeline)
        _ = switched.cells(at: instant)
        let fine = MapGrid(columns: 96, rows: 54)
        switched.setGrid(fine)

        let born = ClusterMapPlayer(grid: fine)
        born.load(timeline)
        #expect(switched.cells(at: instant) == born.cells(at: instant))
    }

    /// Un cluster hors grille, et c'est un débordement de tableau : le rejeu
    /// indexe le décompte avec ce numéro de bloc. Les deux extrêmes sont ceux
    /// qui cassent une division naïve — une grille de trois blocs pour vingt
    /// mille clusters, et une grille qui en compte plus que le volume n'a de
    /// clusters.
    @Test("Un cluster tombe toujours dans un bloc valide, quelle que soit la grille")
    func everyClusterLandsInTheGrid() {
        let clusterCount = 20_000
        let plan = Self.plan(clusterCount: clusterCount)
        let timeline = Self.timeline(from: plan)

        let grids = [MapGrid.standard,
                     MapGrid(columns: 1, rows: 1),
                     MapGrid(columns: 3, rows: 1),
                     MapGrid(columns: 192, rows: 108),
                     MapGrid(columns: 400, rows: 200),
                     MapGrid(columns: 0, rows: -5)]

        for grid in grids {
            #expect(grid.columns >= 1 && grid.rows >= 1, "une grille vide n'est pas permise")
            let player = ClusterMapPlayer(grid: grid)
            player.load(timeline)

            // Le rejeu complet passe par tous les clusters mutés : s'il en
            // projetait un hors du décompte, il s'arrêterait ici.
            let cells = player.cells(at: Self.endTime(timeline))
            #expect(cells.count == grid.cellCount)

            for cluster in [0, 1, clusterCount / 2, clusterCount - 1] {
                let cell = player.cell(ofCluster: cluster)
                #expect(cell >= 0 && cell < grid.cellCount,
                        "cluster \(cluster) sur une grille \(grid.columns)×\(grid.rows)")
            }
            // Un bloc vaut au moins un cluster, même quand il y a plus de blocs
            // que de clusters : sans ce plancher, la division serait nulle.
            #expect(player.clustersPerCell >= 1)
        }
    }

    /// Le cas de « Secrétariat, 1996 » en plein écran : 850 Mo en FAT16, soit
    /// 54 400 clusters, sur une grille de 85 × 170 blocs. Arrondie à trois
    /// clusters par bloc, la carte entassait les 11 050 derniers dans la
    /// dernière case, et la fin du volume n'apparaissait nulle part.
    @Test("La fin du volume occupe la fin de la carte, pas sa dernière case")
    func volumeTailSpreadsOverTheGrid() {
        let clusterCount = 54_400
        let grid = MapGrid(columns: 85, rows: 170)
        let player = ClusterMapPlayer(grid: grid)
        let tail = clusterCount * 4 / 5
        player.load(clusterCount: clusterCount,
                    initialRuns: [MapRun(start: UInt32(tail), count: UInt32(clusterCount - tail),
                                         category: ClusterCategory.allCases[1].rawValue)])

        let shades = player.shades(at: 0)
        let firstTailCell = grid.cellCount * 4 / 5
        #expect(shades[firstTailCell - 1].fill == 0)
        #expect(shades[firstTailCell...].allSatisfy { $0.fill == 255 },
                "le dernier cinquième de la grille porte le dernier cinquième du volume")
        #expect(player.tallyTotal == clusterCount)

        // Les blocs se suivent sans trou ni recouvrement, et chacun vaut sa
        // part à un cluster près.
        let partition = player.partition
        var next = 0
        for cell in 0..<grid.cellCount {
            let clusters = partition.clusters(ofCell: cell)
            #expect(clusters.lowerBound == next)
            #expect(clusters.count == 3 || clusters.count == 4)
            #expect(clusters.allSatisfy { partition.cell(ofCluster: $0) == cell })
            next = clusters.upperBound
        }
        #expect(next == clusterCount)
    }

    /// Sans passe chargée, la carte n'a rien à montrer — et la vue ne doit pas
    /// pour autant tomber sur un tableau de la mauvaise taille.
    @Test("Une carte sans passe ne rend aucune cellule")
    func emptyPlayback() {
        let player = ClusterMapPlayer()
        #expect(player.cells(at: 0).isEmpty)
        #expect(player.clustersPerCell == 1)

        player.load(nil)
        #expect(player.cells(at: 12).isEmpty)
    }

    /// La carte garde la silhouette du volume : après la passe, tout est tassé
    /// contre le début et la fin est libre. C'est ce que l'écran doit montrer,
    /// et c'est le seul test qui regarde les couleurs plutôt que les comptes.
    @Test("Après la passe, la carte est pleine au début et libre à la fin")
    func packedVolumeShowsOnTheMap() {
        let plan = Self.plan()
        let timeline = Self.timeline(from: plan)
        let player = ClusterMapPlayer()
        player.load(timeline)

        let free = ClusterCategory.free.rawValue
        let before = player.cells(at: 0)
        let after = player.cells(at: Self.endTime(timeline))

        #expect(after.prefix(4).allSatisfy { $0 != free }, "le début du volume est occupé")
        #expect(after.suffix(4).allSatisfy { $0 == free }, "la fin du volume est libre")
        // Le volume mité du départ, lui, portait des blocs occupés bien au-delà
        // de ce que son remplissage exige.
        #expect(before != after)
    }

    // MARK: - Contre l'ancienne méthode

    /// La garantie que le changement est à comportement constant.
    ///
    /// Le rejeu ne matérialise plus la carte par cluster ; sur un volume assez
    /// petit pour qu'elle tienne, on la déroule quand même — `categoryMap()`
    /// existe encore pour cela — et on lui applique les mutations exactement
    /// comme le faisait l'ancien rejeu. Les deux doivent voir la même chose,
    /// cluster par cluster, à tout instant et sur toutes les grilles : si les
    /// plages découpaient ou refusionnaient de travers, le décompte dériverait
    /// et l'écart se verrait ici avant de se voir à l'écran.
    @Test("Le décompte par plages est celui de la carte par cluster")
    func runsMatchTheClusterMap() {
        let volume = Self.volume()
        let plan = DefragPlanner.plan(volume: volume)
        let timeline = Self.timeline(from: plan)
        let end = Self.endTime(timeline)

        for grid in [MapGrid.standard, MapGrid(columns: 192, rows: 108),
                     MapGrid(columns: 7, rows: 5), MapGrid(columns: 400, rows: 200)] {
            let player = ClusterMapPlayer(grid: grid)
            player.load(timeline)

            // La référence : la carte par cluster d'autrefois, avancée en même
            // temps que le rejeu.
            var map = volume.categoryMap()
            var next = 0

            for time in stride(from: 0.0, through: end, by: end / 12) {
                while next < timeline.mutations.count && timeline.mutations[next].time <= time {
                    let mutation = timeline.mutations[next]
                    let last = min(mutation.start + mutation.count, map.count)
                    if mutation.start < last {
                        for cluster in mutation.start..<last { map[cluster] = mutation.category }
                    }
                    next += 1
                }
                #expect(player.cells(at: time) == Self.reference(of: map, grid: grid),
                        "à \(time) s sur une grille \(grid.columns)×\(grid.rows)")
            }
        }
    }

    /// L'agrégation telle qu'elle se faisait avant : un parcours de tous les
    /// clusters, puis la catégorie occupée la plus représentée de chaque bloc.
    private static func reference(of map: [UInt8], grid: MapGrid) -> [UInt8] {
        // Chaque cluster dans le bloc de sa position relative, ⌊k · C / N⌋ :
        // pas de reste de division entassé dans le dernier bloc.
        let span = max(map.count, grid.cellCount)
        var tally = [UInt32](repeating: 0, count: grid.cellCount * categoryCount)
        for cluster in 0..<map.count {
            let cell = cluster * grid.cellCount / span
            tally[cell * categoryCount + Int(map[cluster])] += 1
        }
        return (0..<grid.cellCount).map { cell in
            let base = cell * categoryCount
            var best = 0
            var bestCount: UInt32 = 0
            for category in 1..<categoryCount where tally[base + category] > bestCount {
                best = category
                bestCount = tally[base + category]
            }
            return UInt8(best)
        }
    }
}

/// Ce que la carte par plages doit savoir faire.
///
/// Le rejeu ne lui demande que deux choses — rendre ses plages, et dire qui
/// occupait ce qu'une mutation recouvre — mais les deux reposent entièrement
/// sur sa façon de découper et de refusionner. Ces cas-là sont ceux qui
/// cassent une implémentation naïve, et ils ne se voient pas depuis les
/// cellules : un décompte faux s'y rattrape souvent par hasard.
@Suite("Carte par plages")
struct ClusterRunMapTests {

    private static let system = ClusterCategory.system.rawValue
    private static let document = ClusterCategory.document.rawValue
    private static let churn = ClusterCategory.churn.rawValue
    private static let free = ClusterCategory.free.rawValue

    /// Ce que la carte porte, plages recollées de part et d'autre des blocs,
    /// sous une forme comparable : début, longueur, catégorie.
    private static func shape(_ map: ClusterRunMap) -> [(Int, Int, UInt8)] {
        map.runs().map { (Int($0.start), Int($0.count), $0.category) }
    }

    private static func expect(_ map: ClusterRunMap, _ expected: [(Int, Int, UInt8)],
                               _ note: Comment) {
        let actual = shape(map)
        #expect(actual.count == expected.count, note)
        for (left, right) in zip(actual, expected) {
            #expect(left == right, note)
        }
        // Une carte qui ne couvre pas exactement le volume est une carte fausse,
        // quelles que soient ses plages.
        #expect(actual.reduce(0) { $0 + $1.1 } == map.clusterCount, note)
    }

    /// Ce qui n'est pas déclaré occupé est libre : c'est la convention sur
    /// laquelle repose toute l'économie de la structure.
    @Test("Les trous entre les extents sont libres")
    func gapsAreFree() {
        let map = ClusterRunMap(clusterCount: 100, occupied: [
            MapRun(start: 10, count: 5, category: Self.system),
            MapRun(start: 40, count: 10, category: Self.document),
        ])
        Self.expect(map, [(0, 10, Self.free), (10, 5, Self.system), (15, 25, Self.free),
                          (40, 10, Self.document), (50, 50, Self.free)], "carte de départ")
    }

    @Test("Une mutation au milieu d'une plage la coupe en trois")
    func splitInTheMiddle() {
        var map = ClusterRunMap(clusterCount: 100,
                                occupied: [MapRun(start: 0, count: 100, category: Self.system)])
        var replaced: [(Int, Int, UInt8)] = []
        map.replace(start: 40, count: 10, category: Self.document) {
            replaced.append((Int($0.start), Int($0.count), $0.category))
        }

        // Ce que la mutation a recouvert, et c'est de cela seul que le décompte
        // se décrémente : dix clusters de système, pas un de plus.
        #expect(replaced.count == 1)
        #expect(replaced.first.map { $0 == (40, 10, Self.system) } == true)
        Self.expect(map, [(0, 40, Self.system), (40, 10, Self.document), (50, 50, Self.system)], "après la coupe")
    }

    /// Le cas du défragmenteur qui tasse : une écriture recouvre plusieurs
    /// fichiers d'un coup, et chacun doit être rendu pour sa part exacte.
    @Test("Une mutation qui recouvre plusieurs plages les rend toutes")
    func coveringWholeRuns() {
        var map = ClusterRunMap(clusterCount: 100, occupied: [
            MapRun(start: 10, count: 10, category: Self.system),
            MapRun(start: 20, count: 10, category: Self.document),
            MapRun(start: 30, count: 10, category: Self.churn),
        ])
        var replaced: [(Int, Int, UInt8)] = []
        map.replace(start: 15, count: 20, category: Self.document) {
            replaced.append((Int($0.start), Int($0.count), $0.category))
        }

        #expect(replaced.count == 3)
        #expect(replaced.reduce(0) { $0 + $1.1 } == 20, "la somme des morceaux rendus vaut la mutation")
        #expect(replaced[0] == (15, 5, Self.system))
        #expect(replaced[1] == (20, 10, Self.document))
        #expect(replaced[2] == (30, 5, Self.churn))
        // La plage neuve absorbe le voisin de même catégorie qu'elle prolonge.
        Self.expect(map, [(0, 10, Self.free), (10, 5, Self.system), (15, 20, Self.document),
                          (35, 5, Self.churn), (40, 60, Self.free)], "après le recouvrement")
    }

    /// Sans fusion, une passe qui écrit fichier par fichier laisserait autant de
    /// plages que d'écritures dans une zone d'une seule couleur — et la carte
    /// grossirait jusqu'à coûter plus cher que celle qu'on remplace.
    @Test("Deux mutations adjacentes de même catégorie n'en font qu'une")
    func adjacentMutationsMerge() {
        var map = ClusterRunMap(clusterCount: 100, occupied: [])
        for start in stride(from: 0, to: 50, by: 10) {
            map.replace(start: start, count: 10, category: Self.document) { _ in }
        }
        Self.expect(map, [(0, 50, Self.document), (50, 50, Self.free)], "cinq écritures bout à bout")
        #expect(map.runCount == 2, "et pas cinq plages là où il n'y a qu'une couleur")

        // Y compris à rebours : la deuxième écriture précède la première.
        var backwards = ClusterRunMap(clusterCount: 100, occupied: [])
        backwards.replace(start: 20, count: 10, category: Self.churn) { _ in }
        backwards.replace(start: 10, count: 10, category: Self.churn) { _ in }
        Self.expect(backwards, [(0, 10, Self.free), (10, 20, Self.churn), (30, 70, Self.free)], "à rebours")
    }

    /// Le dernier cluster est celui qu'on oublie : une mutation qui déborde doit
    /// être rognée, et surtout pas allonger la carte.
    @Test("Une mutation à cheval sur le dernier cluster est rognée")
    func mutationPastTheEnd() {
        var map = ClusterRunMap(clusterCount: 100,
                                occupied: [MapRun(start: 90, count: 10, category: Self.system)])
        var replaced: [(Int, Int, UInt8)] = []
        map.replace(start: 95, count: 20, category: Self.churn) {
            replaced.append((Int($0.start), Int($0.count), $0.category))
        }
        #expect(replaced.count == 1)
        #expect(replaced.first.map { $0 == (95, 5, Self.system) } == true)
        Self.expect(map, [(0, 90, Self.free), (90, 5, Self.system), (95, 5, Self.churn)], "rognée à la fin")

        // Et une mutation entièrement hors du volume ne fait rien du tout.
        map.replace(start: 120, count: 10, category: Self.document) { _ in
            Issue.record("une mutation hors volume ne recouvre rien")
        }
        Self.expect(map, [(0, 90, Self.free), (90, 5, Self.system), (95, 5, Self.churn)], "hors volume")
    }

    /// Les plages ne s'arrêtent pas aux frontières de blocs, mais la structure,
    /// elle, les y coupe. Une mutation qui traverse plusieurs blocs doit rendre
    /// la même chose qu'une mutation qui tient dans un seul.
    @Test("Une mutation qui traverse les blocs reste une seule plage")
    func mutationAcrossBlocks() {
        // Les blocs font au moins 1 024 clusters : celle-ci en traverse trois.
        var map = ClusterRunMap(clusterCount: 40_000,
                                occupied: [MapRun(start: 0, count: 40_000, category: Self.system)])
        var covered = 0
        map.replace(start: 1_000, count: 3_000, category: Self.document) { covered += Int($0.count) }
        #expect(covered == 3_000)
        Self.expect(map, [(0, 1_000, Self.system), (1_000, 3_000, Self.document), (4_000, 36_000, Self.system)],
                    "à travers trois blocs")
    }
}

/// Ce que la palette doit au rendu par pixels.
///
/// La carte n'est plus dessinée cellule par cellule : elle est une image dont
/// chaque pixel vient de cette table. Une couleur mal encodée ne se voit pas
/// comme un bogue — elle se voit comme une carte fausse, et seulement à l'œil.
@Suite("Palette de la carte")
struct ClusterPaletteTests {

    /// L'encodage attendu par `CGImage`, composante par composante : R, G, B, A
    /// du poids fort au poids faible, et alpha opaque.
    @Test("Un pixel est du RGBA opaque")
    func pixelLayout() {
        let pixel = ClusterColor(red: 0, green: 0.5, blue: 1).pixel
        #expect(pixel >> 24 == 0)
        #expect((pixel >> 16) & 0xFF == 127)
        #expect((pixel >> 8) & 0xFF == 255)
        #expect(pixel & 0xFF == 255)
    }

    /// Le blanc plein doit atteindre 255 : c'est la raison d'être de l'arrondi
    /// par 255,999, et un simple facteur 255 le rendait indistinguable du
    /// presque-blanc.
    @Test("Les extrêmes tombent juste")
    func extremes() {
        #expect(ClusterColor(white: 1).pixel == 0xFFFFFFFF)
        #expect(ClusterColor(white: 0).pixel == 0x000000FF)
    }

    /// Deux catégories de même couleur, et la carte ment sans que rien ne le
    /// signale : on ne verrait qu'un bloc d'apparence libre là où il y a des
    /// données.
    @Test("Chaque catégorie a sa teinte")
    func distinctCategories() {
        let pixels = Set(ClusterCategory.allCases.map { ClusterPalette.color($0).pixel })
        #expect(pixels.count == ClusterCategory.allCases.count)
    }

    /// Le buffer suit la carte cellule pour cellule, dans l'ordre : c'est lui
    /// qui devient l'image, ligne par ligne.
    @Test("Le buffer suit la carte cellule pour cellule")
    func bufferFollowsCells() {
        let cells: [UInt8] = [ClusterCategory.free.rawValue,
                              ClusterCategory.swap.rawValue,
                              ClusterCategory.document.rawValue]
        let buffer = ClusterPalette.pixelBuffer(cells)
        #expect(buffer.count == cells.count)
        #expect(buffer[1] == ClusterPalette.color(.swap).pixel)
        #expect(buffer[2] == ClusterPalette.color(.document).pixel)
    }

    /// La nuance des fichiers d'un seul tenant reste de la même famille, mais
    /// elle doit se distinguer — sauf là où il n'y a pas de fichier.
    @Test("Un fichier d'un seul tenant se voit, sans changer de famille")
    func contiguousShade() {
        for category in ClusterCategory.allCases {
            let plain = ClusterPalette.color(category, contiguous: false)
            let tidy = ClusterPalette.color(category, contiguous: true)
            if category == .free || category == .reserved {
                #expect(plain == tidy)
            } else {
                #expect(plain.pixel != tidy.pixel, "\(category)")
                #expect(tidy.red <= plain.red && tidy.green <= plain.green && tidy.blue <= plain.blue)
            }
        }
        let shades = [ClusterShade(category: ClusterCategory.document.rawValue, fill: 255),
                      ClusterShade(category: ClusterCategory.document.rawValue, fill: 255,
                                   contiguous: true)]
        #expect(ClusterPalette.flatPixelBuffer(shades)
                == [ClusterPalette.color(.document).pixel,
                    ClusterPalette.color(.document, contiguous: true).pixel])
        #expect(ClusterPalette.shadedColor(shades[1]) == ClusterPalette.color(.document, contiguous: true))
    }

    /// Un octet hors palette vient forcément du rejeu ; il doit se voir à
    /// l'écran, pas faire tomber l'application.
    @Test("Une catégorie inconnue retombe sur « libre »")
    func unknownCategory() {
        #expect(ClusterPalette.pixelBuffer([200]) == [ClusterPalette.color(.free).pixel])
    }
}

/// Ce que la grille doit à la surface dont elle dispose.
///
/// Le plein écran ne fige plus 192 × 108 : cette grille est du 16:9, un iPhone
/// en paysage du 19,5:9, et un iPad du 4:3. La dérivation est de la géométrie
/// d'affichage — testable, donc, et c'est bien le moins pour un calcul dont le
/// résultat indexe un décompte de vingt mille entrées.
@Suite("Grille dérivée de la surface")
struct MapGridFittingTests {

    /// Les quatre surfaces qui comptent, prises sur du matériel réel.
    private static let surfaces: [(String, Double, Double)] = [
        ("iPhone 17 Pro Max paysage", 956, 440),
        ("iPhone 17 Pro Max portrait", 440, 956),
        ("iPad carré", 820, 820),
        ("vignette minuscule", 9, 4),
    ]

    @Test("La grille couvre la surface au côté de cellule demandé")
    func fillsTheSurface() {
        for (name, width, height) in Self.surfaces {
            let grid = MapGrid.fitting(width: width, height: height, side: 5)

            // La cellule n'est jamais plus petite que demandée : c'est elle qui
            // fixe la lisibilité, et le plafond ne peut que la faire grossir.
            #expect(width / Double(grid.columns) >= 5 || grid.columns == 1,
                    "\(name) : cellules trop étroites")
            #expect(height / Double(grid.rows) >= 5 || grid.rows == 1,
                    "\(name) : cellules trop basses")

            // Et la grille prend presque toute la place qu'elle a le droit de
            // prendre : ce que le côté visé permet, ou ce que le plafond
            // autorise, à quelques cellules près. C'est cela, « remplir
            // l'écran » — et c'est ce qui manque à une grille figée en 16:9 sur
            // un écran qui ne l'est pas.
            let roomy = min(MapGrid.cellLimit, Int(width / 5) * Int(height / 5))
            #expect(grid.cellCount >= Int(Double(roomy) * 0.95),
                    "\(name) : \(grid.cellCount) cellules pour \(roomy) possibles")
        }
    }

    /// C'est le chiffre du cahier des charges, mesuré sur l'appareil visé :
    /// 191 × 88 sur un 956 × 440, et non les 192 × 108 d'un 16:9 qui y
    /// laisserait deux bandes noires.
    @Test("Un iPhone en paysage donne une grille de son propre format")
    func landscapeIsNotSixteenNine() {
        let grid = MapGrid.fitting(width: 956, height: 440, side: 5)
        #expect(grid.columns == 191)
        #expect(grid.rows == 88)
        #expect(grid.cellCount == 16_808)
    }

    /// Le plafond n'est pas décoratif : le décompte alloue huit compteurs par
    /// bloc et se reconstruit à chaque changement de grille.
    @Test("Le plafond de cellules est respecté, quelle que soit la surface")
    func honoursTheCellLimit() {
        for (name, width, height) in Self.surfaces + [("mur d'images", 8_000, 5_000)] {
            // Un côté d'un point demanderait quarante millions de cellules sur
            // le mur d'images : c'est exactement le cas que le plafond existe
            // pour couper.
            let grid = MapGrid.fitting(width: width, height: height, side: 1)
            #expect(grid.cellCount <= MapGrid.cellLimit,
                    "\(name) : \(grid.columns)×\(grid.rows)")
            // Et il reste proche du plafond : rabattre à cent cellules
            // respecterait la borne en gâchant l'écran.
            if width * height > Double(MapGrid.cellLimit) {
                #expect(grid.cellCount > MapGrid.cellLimit / 2, "\(name) : trop rabotée")
            }
        }
    }

    /// Une grille vide ferait diviser par zéro le rejeu et ne peindrait rien.
    /// Une surface nulle arrive pour de bon : SwiftUI propose zéro avant la
    /// première mise en page.
    @Test("Jamais zéro colonne ni zéro ligne")
    func neverEmpty() {
        for (width, height) in [(0.0, 0.0), (1.0, 1_000.0), (1_000.0, 1.0), (-40.0, 30.0)] {
            let grid = MapGrid.fitting(width: width, height: height)
            #expect(grid.columns >= 1 && grid.rows >= 1, "\(width)×\(height)")
            #expect(grid.cellCount >= 1)
        }
    }

    /// Le format de la grille suit celui de la surface : une carte en portrait
    /// doit être plus haute que large, sans quoi elle laisserait la moitié de
    /// l'écran noire.
    @Test("La grille suit l'orientation de la surface")
    func followsOrientation() {
        let landscape = MapGrid.fitting(width: 956, height: 440)
        let portrait = MapGrid.fitting(width: 440, height: 956)
        #expect(landscape.columns > landscape.rows)
        #expect(portrait.rows > portrait.columns)
        // Et une rotation d'écran donne bien la grille transposée.
        #expect(landscape.columns == portrait.rows)
        #expect(landscape.rows == portrait.columns)
    }
}

/// Ce que la teinte proportionnelle doit montrer.
///
/// Le seul argument de son existence est qu'un bloc à moitié rempli n'ait pas
/// l'air plein. Les trois bornes le disent : vide, plein, et entre les deux.
@Suite("Teinte proportionnelle")
struct ClusterShadingTests {

    @Test("Un bloc entièrement libre garde exactement la couleur « libre »")
    func emptyBlockIsFree() {
        let free = ClusterPalette.color(.free)
        #expect(ClusterPalette.shadedColor(.empty) == free)
        // Y compris quand une catégorie traîne sur un bloc vidé : c'est le
        // taux, et lui seul, qui décide qu'il n'y a plus rien.
        #expect(ClusterPalette.shadedColor(ClusterShade(category: ClusterCategory.swap.rawValue,
                                                        fill: 0)) == free)
    }

    @Test("Un bloc entièrement plein rend exactement la couleur de sa catégorie")
    func fullBlockIsItsCategory() {
        for category in ClusterCategory.allCases where category != .free {
            let shade = ClusterShade(category: category.rawValue, fill: 255)
            #expect(ClusterPalette.shadedColor(shade) == ClusterPalette.color(category),
                    "\(category.label)")
        }
    }

    /// Entre les deux, et strictement : la couleur d'un bloc à moitié plein ne
    /// doit se confondre ni avec le fond ni avec la couleur pleine, sinon la
    /// modulation ne dit rien.
    @Test("Un bloc à moitié rempli tombe entre le libre et le plein")
    func halfBlockIsBetween() {
        let free = ClusterPalette.color(.free)
        for category in ClusterCategory.allCases where category != .free {
            let full = ClusterPalette.color(category)
            let half = ClusterPalette.shadedColor(ClusterShade(category: category.rawValue,
                                                               fill: 127))
            for (component, bounds) in [(half.red, (free.red, full.red)),
                                        (half.green, (free.green, full.green)),
                                        (half.blue, (free.blue, full.blue))] {
                let low = min(bounds.0, bounds.1)
                let high = max(bounds.0, bounds.1)
                #expect(component >= low - 1e-9 && component <= high + 1e-9, "\(category.label)")
            }
            #expect(half != full, "\(category.label) : à moitié plein ne doit pas paraître plein")
            #expect(half != free, "\(category.label) : à moitié plein ne doit pas paraître vide")
        }
    }

    /// La luminosité doit croître avec l'occupation, sinon on lit la carte à
    /// l'envers. On la prend sur la composante dominante de la catégorie.
    @Test("Plus un bloc est rempli, plus il est lumineux")
    func monotonic() {
        let category = ClusterCategory.document
        var previous = -1.0
        for fill in stride(from: 0, through: 255, by: 15) {
            let color = ClusterPalette.shadedColor(ClusterShade(category: category.rawValue,
                                                                fill: UInt8(fill)))
            #expect(color.green > previous, "à \(fill)")
            previous = color.green
        }
    }

    /// Le cas qui justifie le plancher : sur un volume de 320 Go un bloc vaut
    /// quatre mille clusters, et une écriture isolée en occupe huit. Un mélange
    /// strictement linéaire la rendrait invisible.
    @Test("Une poignée de clusters dans un bloc immense se voit")
    func isolatedWriteStaysVisible() {
        let free = ClusterPalette.color(.free)
        let shade = ClusterShade(category: ClusterCategory.churn.rawValue,
                                 fill: UInt8(255 * 8 / 4_000))       // vaut 0
        let color = ClusterPalette.shadedColor(shade)
        #expect(shade.fill == 0, "huit clusters sur quatre mille ne pèsent pas un 255e")
        // Un taux arrondi à zéro rend bien le fond : c'est au décompte de ne
        // pas perdre la présence, et il ne la perd pas — un cluster occupé
        // donne un `fill` d'au moins un dès que le bloc est plus petit.
        #expect(color == free)

        let barely = ClusterPalette.shadedColor(ClusterShade(category: ClusterCategory.churn.rawValue,
                                                             fill: 1))
        let full = ClusterPalette.color(.churn)
        // Et dès le premier niveau, la teinte a déjà franchi le quart du chemin
        // vers la couleur pleine : c'est le plancher, et c'est ce qui rend une
        // présence infime visible.
        let progress = (barely.red - free.red) / (full.red - free.red)
        #expect(progress > 0.2 && progress < 0.35)
    }
}

/// Ce que la rémanence des accès doit montrer.
///
/// Le liseré unique supposait un seul accès visible à la fois ; à cinq points
/// de côté, un accès isolé est un point qui clignote une image. La trace qui le
/// remplace se fond **sur l'âge et non sur le rang** — décision du chantier 5,
/// reprise telle quelle, et c'est justement ce que ces tests vérifient.
@Suite("Rémanence des accès")
struct MapTrailTests {

    private static func access(_ time: Double, cluster: Int, isWrite: Bool = true) -> ClusterActivity {
        ClusterActivity(start: time, end: time, cluster: cluster, isWrite: isWrite)
    }

    @Test("Un accès s'éteint sur la fenêtre, puis disparaît")
    func fadesWithAge() {
        let activity = [Self.access(1, cluster: 100)]
        let fresh = MapTrail.points(in: activity, at: 1, cell: { $0 })
        #expect(fresh.count == 1)
        #expect(fresh[0].intensity == 1)
        #expect(fresh[0].cell == 100)

        let half = MapTrail.points(in: activity, at: 1 + MapTrail.window / 2, cell: { $0 })
        #expect(half.count == 1)
        #expect(abs(half[0].intensity - 0.5) < 1e-9)

        #expect(MapTrail.points(in: activity, at: 1 + MapTrail.window * 1.01, cell: { $0 }).isEmpty)
        // Et rien avant le premier accès.
        #expect(MapTrail.points(in: activity, at: 0.5, cell: { $0 }).isEmpty)
    }

    /// Le piège que le chantier 5 a rencontré sur la traînée du plateau : un
    /// train dense où le fondu se ferait sur le rang écraserait tout le dégradé
    /// sur quelques millisecondes, et deux accès distants d'un quart de seconde
    /// s'afficheraient à la même opacité.
    @Test("Deux accès distants ne s'affichent pas à la même opacité")
    func fadeFollowsTimeNotRank() {
        // Mille accès en dix millisecondes, puis un seul, bien plus tard.
        var activity = (0..<1_000).map { Self.access(1 + Double($0) * 1e-5, cluster: $0) }
        activity.append(Self.access(1.25, cluster: 5_000))

        let points = MapTrail.points(in: activity, at: 1.25, cell: { $0 })
        let recent = points.last
        let old = points.first
        #expect(recent?.cell == 5_000)
        #expect(recent?.intensity == 1)
        // Le train est vieux d'un quart de seconde sur une fenêtre de 0,34 :
        // il est très largement éteint, alors qu'un fondu sur le rang
        // l'afficherait à pleine opacité, mille accès occupant tout le dégradé.
        #expect((old?.intensity ?? 1) < 0.3)
    }

    /// Le plafond est une borne de dessin : il coupe la queue de la liste, et
    /// surtout pas le fondu de ce qui reste.
    @Test("Le plafond coupe les plus vieux, pas le dégradé")
    func limitKeepsTheNewest() {
        let activity = (0..<(MapTrail.limit * 3)).map {
            Self.access(1 + Double($0) * 1e-4, cluster: $0)
        }
        let time = activity.last!.start
        let points = MapTrail.points(in: activity, at: time, cell: { $0 })
        #expect(points.count == MapTrail.limit)
        #expect(points.last?.cell == activity.count - 1, "le plus récent est là")
        #expect(points.last?.intensity == 1)
        // Les points restent rangés du plus ancien au plus récent : c'est
        // l'ordre dans lequel la vue les peint, et le plus récent doit couvrir
        // les autres.
        #expect(points.first!.intensity < points.last!.intensity)
    }

    /// La projection sur la grille est celle du rejeu : un même cluster ne
    /// tombe pas dans le même bloc selon la finesse de la carte.
    @Test("La traînée est projetée sur la grille courante")
    func usesTheCurrentGrid() {
        let activity = [Self.access(1, cluster: 4_000, isWrite: false)]
        let coarse = MapTrail.points(in: activity, at: 1, cell: { $0 / 1_000 })
        let fine = MapTrail.points(in: activity, at: 1, cell: { $0 / 10 })
        #expect(coarse[0].cell == 4)
        #expect(fine[0].cell == 400)
        #expect(coarse[0].isWrite == false)
    }
}
