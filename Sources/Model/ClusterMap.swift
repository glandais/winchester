import Foundation
import DiskCore

/// Taille de la grille d'affichage de la carte des clusters.
///
/// Elle vaut par le modèle et non par la vue : c'est le modèle qui agrège les
/// clusters en blocs, et il lui faut ce compte avant que quoi que ce soit ne
/// soit dessiné. Elle est portée par une instance et non par des `static`
/// parce que le plein écran la dérive de la surface disponible — une grille
/// figée à la compilation ne saurait pas s'y adapter.
///
/// `Sendable` : la galerie la capture pour agréger son volume hors du fil
/// principal, et une valeur immuable traverse les frontières d'isolation sans
/// rien coûter.
struct MapGrid: Equatable, Sendable {

    let columns: Int
    let rows: Int

    var cellCount: Int { columns * rows }

    /// La grille historique, celle du défragmenteur de Windows 95 tel qu'on
    /// l'a reproduit : 48 × 26 blocs. Elle reste la valeur par défaut partout,
    /// de sorte qu'une vue qui ne demande rien de particulier voit exactement
    /// ce qu'elle voyait.
    static let standard = MapGrid(columns: 48, rows: 26)

    /// Une grille vide n'a pas de sens — le rejeu diviserait par zéro et la
    /// vue n'aurait rien à peindre. On ramène donc chaque dimension à un.
    init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    /// Côté de cellule visé en plein écran, en points.
    ///
    /// Cinq points : au-dessous, un bloc ne se distingue plus de son voisin sur
    /// un écran à trois pixels par point, et le liseré d'activité n'aurait plus
    /// où se poser.
    static let fullScreenCellSide: Double = 5

    /// Plafond du nombre de blocs.
    ///
    /// Vingt-quatre mille, soit un peu plus que les 20 736 du cahier des
    /// charges et que les 16 808 d'un iPhone 17 Pro Max en paysage. Ce n'est
    /// pas le rendu qui l'impose — une grille de vingt mille cellules coûte
    /// 0,2 ms par image — mais la reconstruction du décompte, qui alloue
    /// `cellCount × 16` compteurs — huit catégories, fragmentées ou non — et se refait à chaque changement de grille.
    static let cellLimit = 24_000

    /// Dérive une grille de la surface disponible.
    ///
    /// Le repliement en lignes n'a **aucune signification physique** : la carte
    /// est une suite linéaire de clusters, et l'endroit où elle revient à la
    /// ligne est arbitraire. N'importe quel couple convient donc, et on prend
    /// celui qui remplit l'écran — 192 × 108 figé laisserait des bandes noires
    /// sur un 19,5:9, qui n'est pas du 16:9.
    ///
    /// - Parameter side: côté de cellule visé, en points. Il n'est qu'un vœu :
    ///   si la surface demande plus de blocs que le plafond, la cellule
    ///   grossit d'autant qu'il faut — en √, puisque c'est une surface.
    static func fitting(width: Double, height: Double,
                        side: Double = MapGrid.fullScreenCellSide,
                        limit: Int = MapGrid.cellLimit) -> MapGrid {
        let w = max(width, 0)
        let h = max(height, 0)
        // Le plafond est une contrainte de **surface** : à trente mille cellules
        // demandées pour vingt-quatre mille permises, c'est le côté qui grossit
        // de la racine du rapport, pas chaque dimension du rapport entier.
        let capped = limit > 0 ? (w * h / Double(limit)).squareRoot() : 0
        let usable = max(max(side, 1), capped)

        var columns = max(Int(w / usable), 1)
        var rows = max(Int(h / usable), 1)

        // Deux troncatures se sont perdues en route, une par dimension, et sur
        // une grande surface elles valent plusieurs centaines de cellules. On
        // rend ce qui peut l'être — une cellule ne descend jamais sous le côté
        // visé, et le total ne franchit jamais le plafond — en servant à chaque
        // tour la dimension la plus à l'étroit.
        while true {
            let columnFits = w / Double(columns + 1) >= usable && (columns + 1) * rows <= limit
            let rowFits = h / Double(rows + 1) >= usable && columns * (rows + 1) <= limit
            guard columnFits || rowFits else { break }
            let columnSlack = w / Double(columns) - usable
            let rowSlack = h / Double(rows) - usable
            if columnFits && (!rowFits || columnSlack >= rowSlack) { columns += 1 } else { rows += 1 }
        }

        return MapGrid(columns: columns, rows: rows)
    }
}

/// Un bloc d'affichage : sa couleur, et ce qu'il en reste de rempli.
///
/// Les deux vont ensemble parce qu'ils sortent du même décompte et qu'aucune
/// des deux moitiés ne se suffit : la catégorie seule fait passer pour plein un
/// bloc rempli au quart — sans conséquence à 48 × 26, où un bloc vaut quelques
/// dizaines de clusters, mais faux à 17 000 blocs sur un volume de 320 Go, où
/// il en vaut des milliers.
struct ClusterShade: Equatable, Sendable {

    /// Catégorie la plus représentée parmi les clusters **occupés**.
    var category: UInt8
    /// Part de clusters occupés du bloc, de 0 (vide) à 255 (plein). Un octet
    /// et non un `Double` : on en garde un par bloc, vingt mille fois.
    var fill: UInt8
    /// Vrai quand la plupart des clusters de la catégorie dominante
    /// appartiennent à des fichiers d'un seul tenant. La carte les montre d'une
    /// teinte légèrement plus sombre : on voit ce qui est rangé et ce qui reste
    /// à recoller.
    var contiguous: Bool = false

    /// Part occupée, en fraction.
    var fraction: Double { Double(fill) / 255 }

    static let empty = ClusterShade(category: ClusterCategory.free.rawValue, fill: 0)
}

/// Une plage de clusters d'une même catégorie.
///
/// C'est la brique de tout ce qui suit : la carte n'est plus une valeur par
/// cluster mais une suite de ces plages. `UInt32` et non `Int` pour la même
/// raison qu'`Extent` — on en garde des centaines de milliers, et 2³² clusters
/// de 4 Ko font déjà 16 To. La catégorie est un `UInt8` brut et non un
/// `ClusterCategory` parce que c'est sous cette forme que le décompte l'indexe,
/// et qu'une conversion par plage se paierait à chaque mutation.
struct MapRun: Equatable, Sendable {

    var start: UInt32
    var count: UInt32
    var category: UInt8
    /// Le fichier qui la porte est d'un seul tenant. Sans effet sur la
    /// mémoire : la plage fait douze octets avec ou sans lui.
    var contiguous: Bool = false

    /// Premier cluster **après** la plage.
    var end: UInt32 { start &+ count }

    /// Les deux plages n'en font qu'une : même contenu, et bout à bout.
    func continues(into next: MapRun) -> Bool {
        category == next.category && contiguous == next.contiguous && end == next.start
    }
}

/// Carte des catégories tenue par intervalles.
///
/// Elle remplace le tableau d'un octet par cluster, qui pesait 78 Mo sur le
/// NTFS de 320 Go de la galerie — deux fois, puisque le rejeu en gardait une
/// copie — et coûtait 194 ms à parcourir au moindre retour en arrière. Ici la
/// mémoire suit le nombre d'extents (178 000 sur ce volume) et non la capacité.
///
/// Deux questions, et deux seulement, lui sont posées : *quelles plages porte
/// la carte* (pour reconstruire le décompte par blocs), et *qui occupait ces
/// clusters-là* (pour décrémenter la bonne catégorie quand une mutation les
/// recouvre). Les deux se répondent sur une suite de plages triées, à condition
/// de savoir la découper et la refusionner.
///
/// Le volume est découpé en blocs de taille fixe, chacun portant ses plages
/// **rognées à ses bornes** — le même découpage, et pour la même raison, que
/// l'`ExtentIndex` du défragmenteur. Sans lui, insérer une plage au milieu d'un
/// tableau de 356 000 entrées déplacerait la moitié du tableau à chaque
/// mutation : le coût d'une écriture dépendrait de la taille du volume, ce
/// qu'on cherche précisément à quitter. Avec lui, une mutation ne touche que
/// les blocs qu'elle recouvre, soit une centaine de plages.
///
/// Le prix de ce découpage est que deux plages de même catégorie qui se
/// touchent de part et d'autre d'une frontière de bloc restent deux plages.
/// Cela ne change ni le décompte ni ce qu'on lit ; cela borne simplement le
/// nombre de plages par en dessous, à un par bloc.
struct ClusterRunMap {

    /// Nombre de blocs visé. Celui de l'`ExtentIndex`, pour la même raison :
    /// c'est le compromis entre le nombre de listes et leur longueur.
    private static let targetBlocks = 4_096
    /// Un bloc ne descend jamais sous mille clusters : sur un petit volume,
    /// viser 4 096 blocs donnerait des blocs de huit clusters, donc une plage
    /// par bloc et une carte plus grosse que celle qu'on remplace.
    private static let minimumShift: UInt32 = 10

    let clusterCount: Int
    private let blockShift: UInt32
    private var blocks: [[MapRun]]

    /// - Parameter occupied: les plages occupées, triées par cluster de début.
    ///   Ce qui manque est libre ; ce qui déborde du volume est rogné.
    init(clusterCount: Int, occupied: [MapRun]) {
        self.clusterCount = max(clusterCount, 0)
        let total = UInt32(self.clusterCount)
        var shift = Self.minimumShift
        while (total >> shift) > UInt32(Self.targetBlocks) && shift < 31 { shift += 1 }
        self.blockShift = shift
        self.blocks = [[MapRun]](repeating: [], count: Int(total >> shift) + 1)

        let free = ClusterCategory.free.rawValue
        var frontier: UInt32 = 0
        for run in occupied {
            // Un recouvrement ne devrait pas arriver — deux fichiers ne se
            // partagent jamais un cluster, et un test du planificateur y veille
            // — mais le rogner vaut mieux que de produire une carte dont les
            // plages se chevauchent, où plus aucun décompte ne tomberait juste.
            let start = max(run.start, frontier)
            let end = min(run.end, total)
            guard start < end else { continue }
            if start > frontier {
                append(MapRun(start: frontier, count: start - frontier, category: free))
            }
            append(MapRun(start: start, count: end - start, category: run.category,
                          contiguous: run.contiguous))
            frontier = end
        }
        if frontier < total {
            append(MapRun(start: frontier, count: total - frontier, category: free))
        }
    }

    private func block(of cluster: UInt32) -> Int {
        min(Int(cluster >> blockShift), blocks.count - 1)
    }

    /// Ajoute une plage à la fin de la carte, rognée bloc par bloc.
    private mutating func append(_ run: MapRun) {
        guard run.count > 0 else { return }
        var cursor = run.start
        while cursor < run.end {
            let index = block(of: cursor)
            let boundary = min(UInt32(index + 1) << blockShift, run.end)
            let piece = MapRun(start: cursor, count: boundary - cursor, category: run.category,
                               contiguous: run.contiguous)
            if var last = blocks[index].last, last.continues(into: piece) {
                last.count += piece.count
                blocks[index][blocks[index].count - 1] = last
            } else {
                blocks[index].append(piece)
            }
            cursor = boundary
        }
    }

    /// Toutes les plages de la carte, dans l'ordre des clusters.
    ///
    /// C'est par là que passe la reconstruction du décompte : elle ne voit
    /// jamais un cluster, seulement des plages.
    func forEachRun(_ body: (MapRun) -> Void) {
        for block in blocks {
            for run in block { body(run) }
        }
    }

    /// Les plages telles qu'on les lirait sans le découpage en blocs : celles
    /// qui se touchent de part et d'autre d'une frontière sont refusionnées.
    /// Rien n'en dépend à l'exécution — c'est la lecture dont les tests ont
    /// besoin pour vérifier les découpes et les fusions.
    func runs() -> [MapRun] {
        var result: [MapRun] = []
        forEachRun { run in
            if var last = result.last, last.continues(into: run) {
                last.count += run.count
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    var runCount: Int { blocks.reduce(0) { $0 + $1.count } }

    /// Passe une plage de clusters dans une nouvelle catégorie.
    ///
    /// - Parameter replaced: appelé pour chaque morceau recouvert, avec la
    ///   catégorie qu'il portait. C'est la seule raison pour laquelle la carte
    ///   existe : sans elle, le rejeu ne saurait pas quel compteur décrémenter.
    mutating func replace(start: Int, count: Int, category: UInt8, contiguous: Bool = false,
                          replaced: (MapRun) -> Void) {
        let low = UInt32(max(start, 0))
        let high = UInt32(min(start + count, clusterCount))
        guard low < high else { return }

        var cursor = low
        while cursor < high {
            let index = block(of: cursor)
            let boundary = min(UInt32(index + 1) << blockShift, high)
            replace(inBlock: index, from: cursor, to: boundary,
                    category: category, contiguous: contiguous, replaced: replaced)
            cursor = boundary
        }
    }

    private mutating func replace(inBlock index: Int, from low: UInt32, to high: UInt32,
                                  category: UInt8, contiguous: Bool,
                                  replaced: (MapRun) -> Void) {
        var runs = blocks[index]
        blocks[index] = []          // pas deux copies du tableau le temps du remaniement

        // Première plage qui déborde sur la gauche de la mutation.
        var first = 0
        var upper = runs.count
        while first < upper {
            let middle = (first + upper) / 2
            if runs[middle].end <= low { first = middle + 1 } else { upper = middle }
        }

        var last = first
        var replacement: [MapRun] = []
        while last < runs.count && runs[last].start < high {
            let run = runs[last]
            if run.start < low {
                replacement.append(MapRun(start: run.start, count: low - run.start,
                                          category: run.category, contiguous: run.contiguous))
            }
            replaced(MapRun(start: max(run.start, low),
                            count: min(run.end, high) - max(run.start, low),
                            category: run.category, contiguous: run.contiguous))
            if run.end > high {
                replacement.append(MapRun(start: high, count: run.end - high,
                                          category: run.category, contiguous: run.contiguous))
            }
            last += 1
        }
        // La plage neuve s'insère après l'éventuel reste de gauche.
        let insertion = replacement.isEmpty || replacement[0].start >= low ? 0 : 1
        replacement.insert(MapRun(start: low, count: high - low, category: category,
                                  contiguous: contiguous),
                           at: insertion)
        runs.replaceSubrange(first..<last, with: replacement)

        // Refusionner autour de la greffe : sans cela, une passe qui tasse le
        // volume fichier par fichier laisserait autant de plages que d'écritures
        // là où il n'y a qu'une seule zone d'une seule couleur.
        var position = max(first - 1, 0)
        let limit = min(first + replacement.count, runs.count - 1)
        while position < limit && position + 1 < runs.count {
            if runs[position].continues(into: runs[position + 1]) {
                runs[position].count += runs[position + 1].count
                runs.remove(at: position + 1)
            } else {
                position += 1
            }
        }
        blocks[index] = runs
    }
}

/// Cluster touché à un instant donné, pour surligner la carte.
///
/// Il vit ici, et non dans le compilateur de scénarios qui le fabrique, parce
/// que la rémanence qui le dessine est de la géométrie d'affichage : elle se
/// teste, et `Scenario.swift` n'entre pas dans `DefragKit`.
struct ClusterActivity: Sendable {
    let start: Double
    let end: Double
    let cluster: Int
    let isWrite: Bool
}

/// Un accès encore visible sur la carte, et ce qu'il en reste.
struct MapTrailPoint: Equatable, Sendable {
    let cell: Int
    let isWrite: Bool
    /// 1 à l'instant de l'accès, 0 quand la fenêtre est écoulée.
    let intensity: Double
}

/// La rémanence des accès sur la carte.
///
/// Le liseré unique de la carte en pouce supposait un seul accès visible à la
/// fois : à 48 × 26 un bloc fait quinze points de côté et reste à l'écran le
/// temps qu'on le voie. En plein écran un bloc fait cinq points, un accès
/// isolé dure moins d'une image, et sans trace il ne reste qu'un scintillement.
///
/// **Le fondu se calcule sur l'âge, pas sur le rang** — c'est la décision du
/// chantier 5 pour la traînée du plateau, et elle vaut mot pour mot ici : un
/// train dense d'écritures écraserait sinon tout le dégradé sur quelques
/// millisecondes, et deux accès distants d'une demi-seconde s'afficheraient
/// presque à la même opacité. Le plafond de points, lui, reste un plafond de
/// dessin : il coupe la queue de la liste sans toucher au fondu de ce qui reste.
enum MapTrail {

    /// Durée de la rémanence.
    ///
    /// Un tiers de seconde, soit vingt images : assez pour qu'une écriture qui
    /// dure un millième de seconde laisse une trace qu'on suit du regard, assez
    /// court pour que la tête de la traînée reste l'accès courant et non un
    /// amas de tout ce qui s'est passé dans la dernière seconde.
    static let window: Double = 0.34

    /// Nombre maximal de points dessinés, pour la même raison que la traînée du
    /// plateau : une passe dense produit des centaines d'accès par fenêtre,
    /// dont l'écran ne montrerait de toute façon qu'un aplat.
    static let limit = 512

    /// Les accès encore visibles, du plus ancien au plus récent.
    ///
    /// - Parameter cell: projection d'un cluster sur la grille — elle dépend de
    ///   la grille courante, que la trace ne connaît pas.
    static func points(in activity: [ClusterActivity], at time: Double,
                       window: Double = MapTrail.window,
                       cell: (Int) -> Int) -> [MapTrailPoint] {
        guard !activity.isEmpty, let last = index(in: activity, at: time) else { return [] }

        var points: [MapTrailPoint] = []
        points.reserveCapacity(min(limit, last + 1))
        var position = last
        while position >= 0 && points.count < limit {
            let access = activity[position]
            // L'âge se compte depuis la **fin** du transfert : tant qu'il dure,
            // le bloc est à pleine intensité.
            let age = time - max(access.end, access.start)
            guard age < window else { break }
            let intensity = 1 - max(age, 0) / window
            points.append(MapTrailPoint(cell: cell(access.cluster),
                                        isWrite: access.isWrite,
                                        intensity: intensity))
            position -= 1
        }
        return points.reversed()
    }

    /// Dernier accès commencé à cet instant.
    private static func index(in activity: [ClusterActivity], at time: Double) -> Int? {
        guard activity[0].start <= time else { return nil }
        var low = 0
        var high = activity.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if activity[middle].start <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// Mutation de la carte des clusters, datée par la simulation.
struct TimedMutation: Sendable {
    let time: Double
    let start: Int
    let count: Int
    let category: UInt8
    var contiguous: Bool = false
}

/// Une passe entière, telle que les tests la fabriquent à la main : l'état de
/// départ, et toutes les mutations d'un coup.
///
/// Le rejeu n'en a plus besoin — il reçoit ses mutations au fil de l'eau —
/// mais c'est la forme la plus commode pour décrire une passe hors application.
struct ClusterMapTimeline {
    /// Nombre de clusters de la partition. C'est lui, et non la longueur de la
    /// carte, qui fixe la taille d'un bloc : les deux coïncident sur les
    /// volumes où la carte est matérialisée, mais c'est la partition qui fait
    /// foi.
    let clusterCount: Int
    /// L'état de départ, décrit par ses plages occupées et non cluster par
    /// cluster : c'est ce qui permet de charger un volume de 320 Go sans
    /// allouer les 78 Mo de sa carte. Ce qui n'y figure pas est libre.
    let initialRuns: [MapRun]
    let mutations: [TimedMutation]
}

/// Rejoue la carte des clusters à mesure que la passe avance.
///
/// Les mutations arrivent datées, par paquets, un peu en avance sur l'écoute ;
/// elles attendent leur instant puis sont appliquées dans l'ordre, et oubliées.
/// Le rejeu **ne revient jamais en arrière** : il ne garde ni la carte de
/// départ ni les mutations passées, et c'est ce qui borne sa mémoire à l'état
/// courant du volume, quelle que soit la durée de la passe. Demander un instant
/// antérieur rend simplement la carte telle qu'elle est.
final class ClusterMapPlayer {

    private static let categoryCount = ClusterCategory.allCases.count
    /// Chaque catégorie compte deux fois dans le décompte : les clusters des
    /// fichiers fragmentés, puis ceux des fichiers d'un seul tenant.
    private static let slotCount = categoryCount * 2

    /// Grille courante. Elle se change en cours de route — le plein écran en
    /// demande une plus fine que la vue en pouce — et le décompte par bloc est
    /// alors reconstruit sans toucher à l'avancement du rejeu.
    private(set) var grid: MapGrid

    private var isLoaded = false
    /// Nombre de clusters de la partition, tenu à part de la carte : c'est lui
    /// qui fixe la taille d'un bloc, et on le lit pendant que la carte se
    /// remanie.
    private var clusterCount = 0
    /// L'état courant de la carte, par plages.
    ///
    /// Il ne sert qu'à une chose : savoir **quelle catégorie occupait** les
    /// clusters qu'une mutation recouvre, pour décrémenter le bon compteur. Un
    /// octet par cluster y répondait aussi, en pesant le volume ; celui-ci pèse
    /// le nombre d'extents.
    private var map = ClusterRunMap(clusterCount: 0, occupied: [])
    /// Combien de clusters de chaque catégorie porte chaque bloc.
    ///
    /// C'est ce décompte qui rend la carte tenable sur un gros volume : sans
    /// lui, afficher une image demandait de reparcourir tous les clusters —
    /// 1,6 million sur un FAT32 de 1999, soixante fois par seconde. Ici une
    /// image ne coûte que les blocs affichés, et une mutation que les clusters
    /// qu'elle touche.
    private var tally: [UInt32] = []
    /// Mutations reçues et pas encore appliquées, dans l'ordre chronologique.
    private var pending: [TimedMutation] = []
    private var pendingHead = 0
    private var time: Double = 0
    /// Change à chaque fois que le décompte change : une mutation appliquée, une
    /// grille changée, un volume chargé. Tant qu'il ne bouge pas, la carte non
    /// plus.
    ///
    /// C'est la plupart des images : une passe applique quelques dizaines de
    /// mutations par seconde, et l'écran en demande soixante. Sans cela, chaque
    /// image refaisait la réduction de tous les blocs puis le `CGImage` qui en
    /// sort, pour retrouver la carte de l'image d'avant.
    private(set) var revision = 0
    /// La dernière réduction, et le décompte dont elle sort.
    private var cachedShades: [ClusterShade] = []
    private var cachedRevision = -1
    /// Les blocs dont le décompte a bougé depuis la dernière réduction.
    ///
    /// Une liste et non un intervalle : un déplacement écrit au début du volume
    /// et libère à la fin, et l'intervalle qui couvrirait les deux serait la
    /// carte entière. Une mutation ne touche en général qu'un ou deux blocs ;
    /// c'est ce qu'une image doit recalculer, pas les seize mille autres.
    private var dirtyCells: [Int] = []
    private var isDirty: [Bool] = []

    init(grid: MapGrid = .standard) {
        self.grid = grid
    }

    /// Le partage courant des clusters entre les blocs.
    var partition: CellPartition {
        CellPartition(clusterCount: isLoaded ? clusterCount : 0, cellCount: grid.cellCount)
    }

    var clustersPerCell: Double { isLoaded ? partition.clustersPerCell : 1 }

    /// Repart d'un volume dans l'état donné, sans aucune mutation en attente.
    func load(clusterCount: Int, initialRuns: [MapRun]) {
        isLoaded = true
        self.clusterCount = clusterCount
        map = ClusterRunMap(clusterCount: clusterCount, occupied: initialRuns)
        pending = []
        pendingHead = 0
        time = 0
        rebuildTally()
    }

    /// Une passe entière d'un coup — ou aucune.
    func load(_ timeline: ClusterMapTimeline?) {
        guard let timeline else {
            isLoaded = false
            map = ClusterRunMap(clusterCount: 0, occupied: [])
            pending = []
            pendingHead = 0
            tally = []
            revision += 1
            return
        }
        load(clusterCount: timeline.clusterCount, initialRuns: timeline.initialRuns)
        enqueue(timeline.mutations)
    }

    /// Des mutations de plus, postérieures à toutes celles déjà reçues.
    func enqueue(_ mutations: [TimedMutation]) {
        guard isLoaded, !mutations.isEmpty else { return }
        // Ce qui a déjà été appliqué ne sert plus : on s'en débarrasse quand
        // il pèse plus que ce qui attend, pour que le tableau suive la passe
        // sans jamais la contenir.
        if pendingHead > 4_096 && pendingHead * 2 > pending.count {
            pending.removeFirst(pendingHead)
            pendingHead = 0
        }
        pending.append(contentsOf: mutations)
    }

    /// Nombre de mutations reçues, pas encore appliquées.
    var pendingCount: Int { pending.count - pendingHead }

    /// Change la grille sans perdre le fil du rejeu.
    ///
    /// Seule l'agrégation dépend de la grille : la carte par cluster, elle, est
    /// déjà à l'instant demandé. On la re-agrège donc telle quelle — sans quoi
    /// passer en plein écran au milieu d'une passe rejouerait toutes les
    /// mutations écoulées, qu'on n'a d'ailleurs plus.
    func setGrid(_ grid: MapGrid) {
        guard grid != self.grid else { return }
        self.grid = grid
        rebuildTally()
    }

    /// Reconstruit le décompte depuis l'état courant.
    ///
    /// Le parcours est celui des plages, jamais celui des clusters : sur le
    /// NTFS de 320 Go, cent soixante-dix-huit mille plages au lieu de
    /// soixante-dix-huit millions de clusters. C'est ce chemin-là qu'emprunte
    /// le changement de grille, le seul endroit où le décompte se refait en
    /// entier.
    private func rebuildTally() {
        revision += 1
        tally = [UInt32](repeating: 0, count: grid.cellCount * Self.slotCount)
        // Toute la réduction est à refaire : on repart d'une carte vide plutôt
        // que de marquer chaque bloc.
        cachedShades = []
        dirtyCells = []
        isDirty = [Bool](repeating: false, count: grid.cellCount)
        map.forEachRun { run in
            add(start: Int(run.start), count: Int(run.count),
                category: Int(run.category), contiguous: run.contiguous, delta: 1)
        }
    }

    /// Porte une plage au crédit — ou au débit — de sa catégorie, bloc par bloc.
    ///
    /// Une plage tombe en général dans un seul bloc d'affichage, et le cas
    /// général ne coûte alors qu'une addition ; quand elle en traverse
    /// plusieurs, chacun ne reçoit que la part qui lui revient. C'est la même
    /// agrégation que `GeneratedDisk.cells`, appliquée au fil de l'eau.
    private func add(start: Int, count: Int, category: Int, contiguous: Bool, delta: Int) {
        guard count > 0, category < Self.categoryCount else { return }
        let partition = self.partition
        let end = start + count
        let firstCell = partition.cell(ofCluster: start)
        let finalCell = partition.cell(ofCluster: end - 1)
        for cell in firstCell...finalCell {
            let clusters = partition.clusters(ofCell: cell)
            let share = min(clusters.upperBound, end) - max(clusters.lowerBound, start)
            guard share > 0 else { continue }
            let slot = cell * Self.slotCount + category + (contiguous ? Self.categoryCount : 0)
            tally[slot] = UInt32(Int(tally[slot]) + delta * share)
            if !isDirty[cell] {
                isDirty[cell] = true
                dirtyCells.append(cell)
            }
        }
    }

    /// Carte agrégée en blocs d'affichage. Un bloc prend la couleur de la
    /// catégorie la plus représentée parmi ses clusters occupés : un bloc qui
    /// contient ne serait-ce qu'un fichier n'a pas l'air vide.
    func cells(at requestedTime: Double) -> [UInt8] {
        shades(at: requestedTime).map(\.category)
    }

    /// La même carte, avec le taux d'occupation de chaque bloc.
    ///
    /// C'est la réduction complète, et `cells(at:)` n'en est que la moitié :
    /// les deux sortent du même décompte, dans la même boucle, celle qui coûte
    /// 0,1 ms par image. La teinte proportionnelle est donc gratuite — ce qui
    /// se paye, c'est de ne pas l'avoir : à 17 000 blocs sur un volume de
    /// 320 Go, un bloc vaut quatre mille clusters et « la catégorie dominante »
    /// affiche plein un bloc où il reste les trois quarts de la place.
    ///
    /// Tant que rien n'a changé depuis l'appel précédent, c'est **le même
    /// tableau** qui revient, et pas seulement un tableau égal : deux tableaux
    /// qui partagent leur stockage se comparent sans être parcourus, et c'est
    /// cette comparaison-là qui permet à la vue de ne pas redessiner sa carte.
    func shades(at requestedTime: Double) -> [ClusterShade] {
        guard isLoaded else { return [] }
        advance(to: requestedTime)
        if cachedRevision == revision { return cachedShades }

        if cachedShades.count != grid.cellCount {
            cachedShades = [ClusterShade](repeating: .empty, count: grid.cellCount)
            for cell in 0..<grid.cellCount { cachedShades[cell] = shade(ofCell: cell) }
        } else {
            for cell in dirtyCells { cachedShades[cell] = shade(ofCell: cell) }
        }
        for cell in dirtyCells { isDirty[cell] = false }
        dirtyCells.removeAll(keepingCapacity: true)
        cachedRevision = revision
        return cachedShades
    }

    /// La couleur d'un bloc, tirée de son décompte.
    private func shade(ofCell cell: Int) -> ClusterShade {
        let capacity = partition.clusters(ofCell: cell).count
        let base = cell * Self.slotCount
        var best = 0
        var bestCount: UInt32 = 0
        var bestContiguous: UInt32 = 0
        var occupied: UInt32 = 0
        // La catégorie « libre » est l'indice zéro : elle ne concourt pas
        // pour la couleur, mais c'est son complément qui donne le taux.
        for category in 1..<Self.categoryCount {
            let contiguous = tally[base + Self.categoryCount + category]
            let count = tally[base + category] + contiguous
            occupied += count
            if count > bestCount {
                best = category
                bestCount = count
                bestContiguous = contiguous
            }
        }
        // Un bloc au-delà d'un volume plus petit que la grille ne porte rien.
        let ratio = capacity > 0 ? min(Double(occupied) / Double(capacity), 1) : 0
        return ClusterShade(category: UInt8(best), fill: UInt8(ratio * 255),
                            contiguous: bestCount > 0 && bestContiguous * 2 > bestCount)
    }

    /// Total du décompte, blocs et catégories confondus.
    ///
    /// Il vaut exactement le nombre de clusters de la carte, à tout instant :
    /// le décompte est une partition des clusters, et chaque mutation retire
    /// d'une catégorie ce qu'elle ajoute à une autre. C'est l'invariant dont
    /// dépend tout le reste — une décrémentation de travers laisserait un bloc
    /// figé sur une couleur périmée — et c'est le seul motif pour lequel ce
    /// détail interne sort d'ici.
    var tallyTotal: Int { tally.reduce(0) { $0 + Int($1) } }

    func cell(ofCluster cluster: Int) -> Int {
        partition.cell(ofCluster: cluster)
    }

    /// Applique ce qui est dû à cet instant. Un instant antérieur n'applique
    /// rien : la carte reste où elle en est.
    func advance(to requestedTime: Double) {
        guard requestedTime >= time else { return }
        time = requestedTime
        let appliedBefore = pendingHead
        while pendingHead < pending.count && pending[pendingHead].time <= requestedTime {
            let mutation = pending[pendingHead]
            // La carte rend ce que chaque morceau recouvert portait, et c'est
            // de cela seul que le décompte est décrémenté — le coût suit le
            // nombre de plages traversées, plus le nombre de clusters.
            map.replace(start: mutation.start, count: mutation.count,
                        category: mutation.category,
                        contiguous: mutation.contiguous) { [self] old in
                add(start: Int(old.start), count: Int(old.count),
                    category: Int(old.category), contiguous: old.contiguous, delta: -1)
            }
            let start = max(mutation.start, 0)
            let end = min(mutation.start + mutation.count, clusterCount)
            add(start: start, count: end - start,
                category: Int(mutation.category), contiguous: mutation.contiguous, delta: 1)
            pendingHead += 1
        }
        if pendingHead != appliedBefore { revision += 1 }
    }
}
