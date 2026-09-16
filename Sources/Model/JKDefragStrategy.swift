import Foundation
import DiskCore

/// La passe par défaut de **JkDefrag 3.36** — le mode 2, « défragmenter et
/// optimiser rapidement » (`JkDefrag.cpp:267`, `OptimizeMode = 2`).
///
/// Comme UltraDefrag, elle n'est pas là pour l'époque : JkDefrag est de 2008, et
/// ne s'obtient que sur demande. Elle est là parce que c'est **le seul des
/// quatre outils qui range le volume sans évacuer personne**. Windows 95 range,
/// mais au prix d'un va-et-vient permanent ; XP et UltraDefrag n'évacuent
/// personne, mais ne rangent rien — ils réparent des fichiers. JkDefrag fait les
/// deux, et c'est ce qui fait sa signature.
///
/// Le mode 2 enchaîne quatre passes (`DefragOnePath`, `JkDefragLib.cpp:5417`) :
///
/// 1. **`Defragment`** — chaque fichier cassé, dans l'ordre du disque, est
///    recopié dans le premier trou à sa taille ; faute de mieux, **par tranches**
///    dans le plus grand trou du moment ;
/// 2. **`Fixup`** — chaque fichier est remis dans sa **zone**. Le volume est
///    découpé en trois bandes contiguës : répertoires, fichiers ordinaires, et
///    *space hogs* — les gros, les archives, les installateurs — relégués au
///    fond. Un fichier ordinaire sous le début de sa zone, ou un space hog sous
///    la sienne, est déplacé ;
/// 3. **`OptimizeVolume`** — les trous sont balayés de bas en haut, et chacun
///    est comblé par des fichiers situés **au-dessus** de lui. D'abord une
///    combinaison qui le remplit au cluster près (`FindBestItem`), sinon le
///    fichier le plus haut du disque qui y tient (`FindHighestItem`) ;
/// 4. **`Fixup`** encore, l'optimisation ayant pu déplacer des fichiers hors de
///    leur zone.
///
/// Ce qu'on devrait entendre : pas une frontière qui avance comme en 1995, mais
/// des allers-retours entre le fond du volume, où l'on prend, et le trou en
/// cours, où l'on pose — un trou après l'autre, en remontant.
///
/// Ce qui n'est **pas** transposé, et pourquoi :
///
/// - **les répertoires.** La galerie ne leur alloue aucun cluster : la zone 0
///   est vide, et le volume commence par la réserve d'espace libre qui la suit ;
/// - **le critère du dernier accès.** Un fichier non lu depuis trente jours
///   est un space hog (`JkDefragLib.cpp:3714`), sauf si le registre désactive la
///   mise à jour des dates d'accès — ce que Vista fait par défaut, et XP non. Le
///   catalogue ne connaît pas les dates d'accès : le critère est inactif, comme
///   sous Vista ;
/// - **les échecs de verrouillage.** Aucun fichier n'est tenu ouvert par une
///   application, aucun trou n'attend un point de contrôle NTFS : un
///   déplacement n'échoue que si sa destination est **occupée** — ce qui
///   arrive, voir `Pass.fixup`. La garde des quinze minutes, elle, n'a rien à
///   garder ;
/// - **`SlowDown`.** La vitesse par défaut est 100 %, qui n'endort rien.
///
/// Les autres modes de la ligne de commande sont là aussi, un par valeur de
/// `mode` : les deux tassements (`-a 5`, `-a 6`) et les cinq tris complets
/// (`-a 7` à `-a 11`). Ils sont décrits avec leur code, dans
/// `JKDefragFullOptimize.swift`.
struct JKDefragStrategy: DefragStrategy {

    /// Ce que fait la passe — l'option `-a` de la ligne de commande, moins un
    /// (`JkDefrag.cpp:340`), aiguillée par `DefragOnePath`
    /// (`JkDefragLib.cpp:5412-5459`).
    enum Mode: Sendable, Equatable {
        /// `-a 3`, le mode par défaut : défragmenter, mettre en zone,
        /// optimiser rapidement, remettre en zone.
        case fastOptimize
        /// `-a 5`, `ForcedFill` : chaque trou rempli par la fin du fragment le
        /// plus haut du volume, jusqu'à ce qu'il n'y ait plus rien au-dessus.
        case forcedFill
        /// `-a 6`, `OptimizeUp` : chaque trou, du fond vers le début, rempli
        /// par les fichiers pris **sous** lui. Le début du volume se vide.
        case moveUp
        /// `-a 7` à `-a 11`, `OptimizeSort` : chaque zone reconstruite dans
        /// l'ordre demandé, en évacuant ce qui gêne.
        case sort(SortField)
    }

    /// Le critère d'`OptimizeSort` — le `SortField` de `CompareItems`
    /// (`JkDefragLib.cpp:4436`).
    enum SortField: Int, Sendable, CaseIterable {
        case name = 0, size, lastAccess, lastChange, creation
    }

    var mode: Mode = .fastOptimize

    var id: String {
        switch mode {
        case .fastOptimize:           return "jkDefrag"
        case .forcedFill:             return "jkDefragForcedFill"
        case .moveUp:                 return "jkDefragMoveUp"
        case .sort(.name):            return "jkDefragSortName"
        case .sort(.size):            return "jkDefragSortSize"
        case .sort(.lastAccess):      return "jkDefragSortAccess"
        case .sort(.lastChange):      return "jkDefragSortChange"
        case .sort(.creation):        return "jkDefragSortCreation"
        }
    }

    var label: String {
        switch mode {
        case .fastOptimize:           return "JkDefrag 3.36"
        case .forcedFill:             return "JkDefrag 3.36, comblement forcé"
        case .moveUp:                 return "JkDefrag 3.36, vers la fin du volume"
        case .sort(.name):            return "JkDefrag 3.36, tri par nom"
        case .sort(.size):            return "JkDefrag 3.36, tri par taille"
        case .sort(.lastAccess):      return "JkDefrag 3.36, tri par dernier accès"
        case .sort(.lastChange):      return "JkDefrag 3.36, tri par dernière modification"
        case .sort(.creation):        return "JkDefrag 3.36, tri par création"
        }
    }

    /// L'espace libre réservé après la zone des répertoires et après celle des
    /// fichiers ordinaires, en pourcentage du volume — l'option `-f`, qui vaut
    /// 1 par défaut (`JkDefrag.cpp:268`).
    ///
    /// C'est ce qui laisse de la place à un fichier qui grandit sans l'envoyer
    /// au fond du disque. Sur un volume plein à 93 %, deux fois 1 % de réserve
    /// pèsent déjà plus du quart de l'espace libre.
    var freeSpacePercent = 1.0

    /// Au-delà de cette taille, un fichier est un space hog quel que soit son
    /// nom : 50 Mo (`JkDefragLib.cpp:3710`).
    var spaceHogBytes = 50 * 1024 * 1024

    /// Taille d'un bloc de déplacement.
    ///
    /// JkDefrag, comme le défragmenteur de XP, ne copie rien lui-même : il
    /// appelle `FSCTL_MOVE_FILE` et laisse le système de fichiers déplacer. Les
    /// tranches de 1 Gio de `MoveItem` (`JkDefragLib.cpp:2504`) découpent les
    /// appels, pas la copie. Le grain est donc celui qu'a retenu
    /// `WindowsXPStrategy`, et pour la même raison.
    var bufferBytes = 4 * 1024 * 1024

    /// Combien d'éléments `FindBestItem` peut visiter avant de renoncer à une
    /// combinaison exacte.
    ///
    /// L'original n'a pas de borne combinatoire : il s'arrête au bout d'**une
    /// demi-seconde de temps réel** (`JkDefragLib.cpp:2667`), la seule chose
    /// qui l'empêche de tourner en O(n²) sur un gros trou. Transposée telle
    /// quelle, cette borne rendrait le plan dépendant de la machine qui le
    /// calcule — deux passes sur le même volume ne donneraient plus le même son.
    /// La borne est donc comptée en **visites**, et c'est assumé : là où
    /// l'original manque de temps, le plan diverge de ce qu'il aurait fait.
    ///
    /// Deux millions, c'est une demi-seconde à 250 ns la visite — un défaut de
    /// cache par nœud d'un arbre chaîné, sur une machine de 2008. Estimation
    /// pessimiste, et elle ne décide de rien : sur les vingt volumes de la
    /// galerie, la recherche la plus longue en fait 166 176.
    var perfectFitVisits = 2_000_000

    /// Les masques de space hogs que `RunJkDefrag` installe par défaut
    /// (`JkDefragLib.cpp:5763-5818`), recopiés dans l'ordre. `?:` désigne la
    /// lettre du volume, `*` n'importe quelle suite de caractères.
    static let defaultSpaceHogMasks: [String] = [
        "?:\\$RECYCLE.BIN\\*", "?:\\RECYCLED\\*", "?:\\RECYCLER\\*",
        "?:\\WINDOWS\\$*", "?:\\WINDOWS\\Downloaded Installations\\*",
        "?:\\WINDOWS\\Ehome\\*", "?:\\WINDOWS\\Fonts\\*", "?:\\WINDOWS\\Help\\*",
        "?:\\WINDOWS\\I386\\*", "?:\\WINDOWS\\IME\\*", "?:\\WINDOWS\\Installer\\*",
        "?:\\WINDOWS\\ServicePackFiles\\*", "?:\\WINDOWS\\SoftwareDistribution\\*",
        "?:\\WINDOWS\\Speech\\*", "?:\\WINDOWS\\Symbols\\*", "?:\\WINDOWS\\ie7updates\\*",
        "?:\\WINDOWS\\system32\\dllcache\\*",
        "?:\\WINNT\\$*", "?:\\WINNT\\Downloaded Installations\\*", "?:\\WINNT\\I386\\*",
        "?:\\WINNT\\Installer\\*", "?:\\WINNT\\ServicePackFiles\\*",
        "?:\\WINNT\\SoftwareDistribution\\*", "?:\\WINNT\\ie7updates\\*",
        "?:\\*\\Installshield Installation Information\\*", "?:\\I386\\*",
        "?:\\System Volume Information\\*", "?:\\windows.old\\*",
        "*.7z", "*.arj", "*.avi", "*.bak", "*.bup", "*.bz2", "*.cab", "*.chm",
        "*.dvr-ms", "*.gz", "*.ifo", "*.log", "*.lzh", "*.mp3", "*.msi", "*.old",
        "*.pdf", "*.rar", "*.rpm", "*.tar", "*.wmv", "*.vob", "*.z", "*.zip",
    ]

    var phases: [PhaseDescriptor] {
        switch mode {
        case .fastOptimize: return Self.fastOptimizePhases
        case .forcedFill:   return Self.phases(named: "forcedFill", "Comblement forcé",
                                               "Chaque trou rempli par la fin du fragment le plus haut du volume")
        case .moveUp:       return Self.phases(named: "moveUp", "Vers la fin du volume",
                                               "Chaque trou, du fond vers le début, rempli par les fichiers pris dessous")
        case .sort(let field):
            return [Self.analysis,
                    PhaseDescriptor(id: "sortRegular", label: "Tri \(field.phrase)",
                                    detail: "Les fichiers ordinaires reposés un à un, en évacuant ce qui gêne"),
                    PhaseDescriptor(id: "sortSpaceHogs", label: "Tri \(field.phrase)",
                                    detail: "Les gros fichiers et les archives, au fond du volume"),
                    Self.commit, Self.done]
        }
    }

    private static let analysis = PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                                                  detail: "Les fichiers, leur zone, et les trois bandes du volume")
    private static let commit = PhaseDescriptor(id: "commit", label: "Écriture des métadonnées",
                                                detail: "Les tables du volume, une dernière fois")
    private static let done = PhaseDescriptor(id: "done", label: "Terminé",
                                              detail: "La passe demandée est allée au bout")

    private static func phases(named id: String, _ label: String, _ detail: String) -> [PhaseDescriptor] {
        [analysis, PhaseDescriptor(id: id, label: label, detail: detail), commit, done]
    }

    /// Les étapes du mode 2, dans l'ordre où l'écran de JkDefrag les annonçait.
    /// Les trois zones de `OptimizeVolume` n'en font qu'une : la zone des
    /// répertoires est vide dans la galerie, et découper le reste n'apprendrait
    /// rien à l'écran.
    private static let fastOptimizePhases: [PhaseDescriptor] = [
        PhaseDescriptor(id: "analyse", label: "Analyse du volume",
                        detail: "Les fichiers, leur zone, et les trois bandes du volume"),
        PhaseDescriptor(id: "defrag", label: "Défragmentation",
                        detail: "Chaque fichier cassé recopié d'un tenant, ou par tranches dans les plus grands trous"),
        PhaseDescriptor(id: "fixup", label: "Mise en zone",
                        detail: "Les gros fichiers et les archives renvoyés au fond du volume"),
        PhaseDescriptor(id: "optimize", label: "Optimisation rapide",
                        detail: "Chaque trou comblé par des fichiers pris plus haut, au cluster près si possible"),
        PhaseDescriptor(id: "refixup", label: "Mise en zone",
                        detail: "Ce que l'optimisation a laissé hors de sa zone"),
        PhaseDescriptor(id: "commit", label: "Écriture des métadonnées",
                        detail: "Les tables du volume, une dernière fois"),
        PhaseDescriptor(id: "done", label: "Terminé",
                        detail: "Le volume est rangé en trois bandes, sans trou sous les fichiers déplacés"),
    ]

    // MARK: - Planification

    func plan(volume: DefragVolume, into sink: OperationSink) -> DefragPlan {
        run(volume: volume, into: sink).plan
    }

    /// Le plan complet, opérations comprises, et ce que la passe sait
    /// d'elle-même au-delà des compteurs communs : c'est là que se lit le
    /// travail de `FindBestItem`.
    func run(volume: DefragVolume) -> (plan: DefragPlan, report: Report) {
        let sink = OperationSink()
        let (plan, report) = run(volume: volume, into: sink)
        return (plan.with(operations: sink.operations, mutations: sink.mutations), report)
    }

    func run(volume input: DefragVolume, into sink: OperationSink) -> (plan: DefragPlan, report: Report) {
        let before = input.stats
        let initialRuns = input.categoryRuns()

        var pass = Pass(strategy: self, volume: input, sink: sink)

        DefragOperations.analysis(partition: input.partition,
                                  directoryCount: DefragOperations.directoryCount(of: input),
                                  into: sink)

        switch mode {
        case .fastOptimize:
            pass.report.moves = [0, 0, 0, 0]
            pass.defragment(phase: 1)
            pass.fixup(phase: 2)
            pass.optimize(phase: 3)
            pass.fixup(phase: 4)
        case .forcedFill:
            pass.report.moves = [0]
            pass.forcedFill(phase: 1)
        case .moveUp:
            pass.report.moves = [0]
            pass.optimizeUp(phase: 1)
        case .sort(let field):
            // Une case pour les fichiers posés à leur rang, une pour les
            // fragments que `Vacate` a évacués.
            pass.report.moves = [0, 0]
            pass.optimizeSort(field: field, phases: [1, 1, 2])
        }

        sink.progress = 1
        DefragOperations.final(partition: input.partition, phase: phases.count - 2, into: sink)

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
            filesAlreadyInPlace: pass.order.count - pass.touched.count,
            // Personne n'est délogé hors des tris : `Vacate` n'est appelé que
            // par eux. Ailleurs, une destination est toujours un trou.
            evacuations: pass.report.evacuations
        )
        return (plan, pass.report)
    }

    /// Ce que les compteurs de `DefragPlan` ne disent pas.
    struct Report {
        /// Les bornes des zones, en clusters : début des fichiers ordinaires,
        /// début des space hogs, fin des space hogs.
        var zones: (regular: UInt32, spaceHogs: UInt32, end: UInt32) = (0, 0, 0)
        var spaceHogs = 0
        var movedClusters = 0
        /// Déplacements par passe. Mode 2 : `Defragment`, `Fixup`,
        /// `OptimizeVolume`, second `Fixup`. Tri : fichiers posés, fragments
        /// évacués. Tassements : une seule case.
        var moves: [Int] = []
        /// Tranches supplémentaires de `Defragment`, au-delà de la première,
        /// pour les fichiers qu'aucun trou ne pouvait recevoir d'un tenant.
        var slices = 0
        /// Tranches qui, faute d'avoir été recalculées après les morceaux
        /// sautés, débordaient de la fin du fichier — et que le système a donc
        /// refusées.
        var overrunSlices = 0
        /// Fichiers que `Fixup` voulait déplacer sans trouver de trou à leur
        /// taille dans leur zone.
        var fixupFailures = 0
        /// Déplacements refusés parce que la destination était déjà prise, et
        /// dont le fichier est devenu immobile pour le reste de la passe.
        var failedMoves = 0
        var gapsVisited = 0
        var gapsSkipped = 0
        /// Trous relus après un déplacement refusé, au lieu d'être sautés
        /// (`Retry`, jusqu'à cinq essais par trou).
        var gapRetries = 0
        var perfectFitSearches = 0
        var perfectFitsFound = 0
        /// Recherches abandonnées faute de visites — là où l'original manquait
        /// de temps. Si ce nombre n'est pas nul, le plan diverge de celui
        /// qu'aurait produit JkDefrag sur une machine assez rapide.
        var perfectFitsExhausted = 0
        /// La recherche la plus longue de la passe, en visites. C'est ce
        /// chiffre, rapporté à `perfectFitVisits`, qui dit si la borne a mordu.
        var perfectFitPeakVisits = 0
        var highestFits = 0

        // Les tris complets.

        /// Fragments que `Vacate` a déplacés vers le haut pour faire de la
        /// place. Un fichier évacué plusieurs fois compte plusieurs fois.
        var evacuations = 0
        var vacateCalls = 0
        /// `Vacate` arrêté par sa garde anti-ver : une évacuation a atterri
        /// sous l'endroit à libérer, la poursuivre ferait tourner le volume en
        /// rond.
        var wormStops = 0
        /// Fichiers posés en plusieurs morceaux, faute d'un trou assez grand à
        /// leur rang — un tri **refragmente** ce qu'il ne peut pas loger.
        var splitPlacements = 0
        /// Recherches de trou sous une borne, qui ne sauraient se faire en
        /// avançant (`FindGap` avec `FindHighestGap`).
        var highestGapSearches = 0
    }

    // MARK: - Ce que les compteurs veulent dire

    /// Ce qui distingue cette passe des trois autres : elle range le volume, et
    /// pourtant n'évacue personne.
    func summary(of plan: DefragPlan) -> String {
        switch mode {
        case .fastOptimize: break
        case .forcedFill:
            return String(format: "La passe tasse le volume contre son début : %d fichiers déplacés, "
                          + "chacun pris par la fin de son fragment le plus haut. Elle ne répare rien, "
                          + "et peut en casser : %d fichiers fragmentés à l'arrivée contre %d au départ.",
                          plan.filesMoved, plan.after.fragmentedFiles, plan.before.fragmentedFiles)
        case .moveUp:
            return String(format: "La passe vide le début du volume : %d fichiers remontés vers la fin, "
                          + "chaque trou comblé par les fichiers pris dessous.",
                          plan.filesMoved)
        case .sort(let field):
            return "La passe repose \(plan.filesMoved) fichiers un à un, \(field.phrase), et évacue "
                + "\(plan.evacuations) fragments pour leur faire de la place — dont certains "
                + "reviendront à leur tour."
        }
        let repaired = plan.before.fragmentedFiles - plan.after.fragmentedFiles
        var text = String(format: "La passe déplace %d fichiers et n'évacue personne : chaque trou "
                          + "est comblé par des fichiers pris plus haut, et les gros sont "
                          + "renvoyés au fond du volume.",
                          plan.filesMoved)
        if plan.before.fragmentedFiles > 0 {
            text += String(format: " Elle répare %d fichiers cassés sur %d.",
                           repaired, plan.before.fragmentedFiles)
        }
        return text
    }

    // MARK: - Space hogs

    /// `MatchMask`, pour les seuls jokers de JkDefrag : `*` et `?`, sans
    /// distinction de casse. Le chemin du catalogue n'a pas de lettre de
    /// volume ; on lui prête celle que les masques attendent.
    static func matches(path: String, mask: String) -> Bool {
        let text = Array(("C:" + path).lowercased().unicodeScalars)
        let pattern = Array(mask.lowercased().unicodeScalars)
        // Programmation dynamique classique : `reachable[j]` dit si les `j`
        // premiers caractères du texte peuvent être consommés par ce qui a été
        // lu du masque.
        var reachable = [Bool](repeating: false, count: text.count + 1)
        reachable[0] = true
        for symbol in pattern {
            var next = [Bool](repeating: false, count: text.count + 1)
            if symbol == "*" {
                var seen = false
                for j in 0...text.count {
                    seen = seen || reachable[j]
                    next[j] = seen
                }
            } else {
                for j in 0..<text.count where reachable[j] {
                    if symbol == "?" || symbol == text[j] { next[j + 1] = true }
                }
            }
            reachable = next
        }
        return reachable[text.count]
    }

    func isSpaceHog(_ file: DefragFile, clusterBytes: Int) -> Bool {
        // La taille de l'original est la taille logique ; celle-ci est la
        // taille allouée, plus grande d'au plus un cluster. L'écart ne fait
        // basculer que les fichiers à un cluster près des 50 Mo.
        if Int(file.clusterCount) * clusterBytes > spaceHogBytes { return true }
        return Self.defaultSpaceHogMasks.contains { Self.matches(path: file.path, mask: $0) }
    }
}

// MARK: - La passe

extension JKDefragStrategy {

    /// Un élément de l'arbre de JkDefrag : un fichier, repéré par le premier
    /// cluster de son premier extent.
    struct Item {
        var lcn: UInt32
        let clusters: UInt32
        let zone: UInt8
        let position: Int32
    }

    /// L'arbre `ItemTree`, trié sur `GetItemLcn`.
    ///
    /// L'original est un arbre binaire écrit à la main ; ici un tableau trié
    /// suffit. Les fichiers se comptent en milliers, un déplacement coûte un
    /// décalage de mémoire, et les parcours — qui sont l'essentiel du travail de
    /// `FindBestItem` — restent contigus en cache.
    struct ItemOrder {
        private(set) var items: [Item] = []
        /// Position dans le volume → LCN courant, pour retrouver un élément ;
        /// `.max` pour un fichier qui n'est pas dans l'arbre.
        private var lcnOf: [UInt32]

        init(_ items: [Item], fileCount: Int) {
            self.items = items.sorted { $0.lcn < $1.lcn }
            lcnOf = Array(repeating: .max, count: fileCount)
            for item in self.items { lcnOf[Int(item.position)] = item.lcn }
        }

        var count: Int { items.count }

        /// Premier indice dont le LCN est au moins `lcn`.
        func lowerBound(_ lcn: UInt32) -> Int {
            var low = 0, high = items.count
            while low < high {
                let middle = (low + high) / 2
                if items[middle].lcn < lcn { low = middle + 1 } else { high = middle }
            }
            return low
        }

        func index(of position: Int32) -> Int? {
            let lcn = lcnOf[Int(position)]
            guard lcn != .max else { return nil }
            let index = lowerBound(lcn)
            return index < items.count && items[index].position == position ? index : nil
        }

        /// `TreeNext` : l'élément qui suit celui-ci sur le disque.
        func successor(of position: Int32) -> Int32? {
            guard let index = index(of: position), index + 1 < items.count else { return nil }
            return items[index + 1].position
        }

        func contains(_ position: Int32) -> Bool { lcnOf[Int(position)] != .max }

        /// `Item->Unmovable = YES` : l'élément reste sur le disque, mais aucun
        /// parcours ne le propose plus.
        mutating func remove(_ position: Int32) {
            guard let index = index(of: position) else { return }
            items.remove(at: index)
            lcnOf[Int(position)] = .max
        }

        mutating func move(_ position: Int32, to lcn: UInt32) {
            guard let from = index(of: position) else { return }
            var item = items.remove(at: from)
            item.lcn = lcn
            items.insert(item, at: lowerBound(lcn))
            lcnOf[Int(position)] = lcn
        }
    }

    struct Pass {
        let strategy: JKDefragStrategy
        var volume: DefragVolume
        var order: ItemOrder
        /// Début des zones 0, 1 et 2, puis fin de la zone 2 — `Data->Zones`.
        var zones: [UInt32]
        /// Où partent les opérations. Une référence et non un tableau : la
        /// passe est une valeur qu'on recopie volontiers, pas le flux qu'elle
        /// alimente.
        let sink: OperationSink
        var touched = Set<Int32>()
        var report = Report()

        init(strategy: JKDefragStrategy, volume: DefragVolume, sink: OperationSink) {
            self.strategy = strategy
            self.volume = volume
            self.sink = sink

            let clusterBytes = volume.partition.clusterBytes
            var items: [Item] = []
            var hogs = 0
            for (position, file) in volume.files.enumerated() where Self.isMovable(file) {
                let hog = strategy.isSpaceHog(file, clusterBytes: clusterBytes)
                if hog { hogs += 1 }
                items.append(Item(lcn: file.extents[0].start, clusters: file.clusterCount,
                                  zone: hog ? 2 : 1, position: Int32(position)))
            }
            self.order = ItemOrder(items, fileCount: volume.files.count)
            self.zones = Self.calculateZones(volume: volume, order: order,
                                             freeSpacePercent: strategy.freeSpacePercent)
            report.zones = (zones[1], zones[2], zones[3])
            report.spaceHogs = hogs
        }

        /// Ce que JkDefrag a le droit de déplacer. Le fichier d'échange est
        /// ouvert par Windows : `MoveItem` y échouerait, et le marquerait
        /// `Unmovable`. On le sait d'avance, on s'épargne l'échec.
        static func isMovable(_ file: DefragFile) -> Bool {
            file.isMovable && file.category != .reserved && file.clusterCount > 0
        }

        // MARK: Zones

        /// `CalculateZones` (`JkDefragLib.cpp:1914`).
        ///
        /// La taille des zones est celle de ce qu'elles doivent contenir, plus
        /// la réserve d'espace libre, plus ce qui y est **immobile** — et c'est
        /// là que le calcul tourne en rond : compter un morceau immobile dans
        /// une zone la rallonge, ce qui peut faire basculer un autre morceau
        /// immobile dans la zone précédente. D'où l'itération jusqu'à point
        /// fixe, plafonnée à dix tours.
        static func calculateZones(volume: DefragVolume, order: ItemOrder,
                                   freeSpacePercent: Double) -> [UInt32] {
            let total = UInt64(volume.partition.clusterCount)
            let reserve = UInt64(Double(total) * freeSpacePercent / 100)

            var movable: [UInt64] = [0, 0, 0]
            for item in order.items { movable[Int(item.zone)] += UInt64(item.clusters) }

            var unmovable: [UInt64] = [0, 0, 0]
            var previous: [UInt64] = [0, 0, 0]
            var ends: [UInt64] = [0, 0, 0]

            for _ in 1...10 {
                ends[0] = movable[0] + unmovable[0] + reserve
                ends[1] = ends[0] + movable[1] + unmovable[1] + reserve
                ends[2] = ends[1] + movable[2] + unmovable[2]
                if ends == previous { break }
                previous = ends

                func zone(of lcn: UInt64) -> Int? {
                    if lcn < ends[0] { return 0 }
                    if lcn < ends[1] { return 1 }
                    if lcn < ends[2] { return 2 }
                    return nil
                }

                unmovable = [0, 0, 0]
                if let mft = volume.mftZone, let z = zone(of: UInt64(mft.lowerBound)) {
                    unmovable[z] += UInt64(mft.count)
                }
                // La MFT et sa copie sont les deux autres `MftExcludes` de
                // l'original. Ce qui en est déjà dans la zone MFT y est compté.
                for extent in volume.systemExtents where !extent.isEmpty {
                    if let mft = volume.mftZone, mft.contains(extent.start) { continue }
                    if let z = zone(of: UInt64(extent.start)) {
                        unmovable[z] += UInt64(extent.length)
                    }
                }
                for (position, file) in volume.files.enumerated()
                where !order.contains(Int32(position)) {
                    for extent in file.extents where !extent.isEmpty {
                        // Les morceaux posés dans la zone MFT sont déjà comptés
                        // avec elle.
                        if let mft = volume.mftZone, mft.contains(extent.start) { continue }
                        if let z = zone(of: UInt64(extent.start)) {
                            unmovable[z] += UInt64(extent.length)
                        }
                    }
                }
            }
            return [0] + ends.map { UInt32(min($0, total)) }
        }

        // MARK: Trous

        /// `FindGap` (`JkDefragLib.cpp:1688`), sans `MaximumLcn` ni
        /// `FindHighestGap`, que le mode 2 n'utilise pas.
        ///
        /// Le trou rendu est **entier** : ni tronqué à la taille cherchée, ni
        /// commencé ailleurs qu'à `from` si `from` tombe dans un trou. La zone
        /// MFT compte pour occupée. Si `mustFit` est faux et qu'aucun trou n'est
        /// assez grand, c'est le plus grand trou au-dessus de `from` qui revient.
        func gap(from: UInt32, size: UInt32, mustFit: Bool) -> Extent? {
            let total = UInt32(volume.partition.clusterCount)
            var cursor = from
            var largest: Extent?
            while cursor < total {
                guard let run = volume.bitmap.nextFreeRun(from: cursor) else { break }
                cursor = run.end
                for piece in outsideMFT(run) {
                    if piece.length >= size, piece.length > 0 { return piece }
                    if largest == nil || piece.length > largest!.length { largest = piece }
                }
            }
            return mustFit ? nil : largest
        }

        func outsideMFT(_ run: Extent) -> [Extent] {
            guard let zone = volume.mftZone,
                  run.start < zone.upperBound, run.end > zone.lowerBound else { return [run] }
            var pieces: [Extent] = []
            if run.start < zone.lowerBound {
                pieces.append(Extent(start: run.start, length: zone.lowerBound - run.start))
            }
            if run.end > zone.upperBound {
                pieces.append(Extent(start: zone.upperBound, length: run.end - zone.upperBound))
            }
            return pieces
        }

        // MARK: Déplacements

        /// Déplace une tranche d'un fichier — ou le fichier entier — vers `lcn`,
        /// et tient l'arbre à jour comme le fait `MoveItem3`.
        ///
        /// Rend `false` si la destination n'est pas libre. `FSCTL_MOVE_FILE`
        /// refuse alors l'appel sans rien copier, et `MoveItem` en tire une
        /// conclusion plus lourde qu'il n'y paraît (`JkDefragLib.cpp:2542`) : le
        /// fichier est déclaré **immobile** pour le reste de la passe, et les
        /// zones sont recalculées autour de lui. Il n'y a pas de seconde chance.
        @discardableResult
        mutating func move(_ position: Int32, vcn: UInt32, length: UInt32,
                           to lcn: UInt32, phase: Int, pass: Int) -> Bool {
            let index = Int(position)
            let file = volume.files[index]
            let target = Extent(start: lcn, length: length)

            let insideMFT = volume.mftZone.map { lcn < $0.upperBound && target.end > $0.lowerBound } ?? false
            guard !insideMFT, volume.bitmap.isFree(target) else {
                report.failedMoves += 1
                order.remove(position)
                zones = Self.calculateZones(volume: volume, order: order,
                                            freeSpacePercent: strategy.freeSpacePercent)
                return false
            }

            let (source, result) = DefragOperations.relocation(of: file.extents, vcn: vcn,
                                                              length: length, to: target)
            DefragOperations.move(source: source, destination: [target],
                                  category: file.category, phase: phase,
                                  partition: volume.partition,
                                  bufferBytes: strategy.bufferBytes,
                                  into: sink)
            DefragOperations.commit(cluster: Int(lcn), fileIndex: index, phase: phase,
                                    partition: volume.partition, into: sink)
            let extents = result.coalesced()
            volume.relocateChanges(index, to: extents)
            order.move(position, to: extents[0].start)
            touched.insert(position)
            report.movedClusters += Int(length)
            report.moves[pass] += 1
            return true
        }

        /// Les éléments, dans l'ordre du disque, en tolérant qu'ils bougent
        /// pendant le parcours : le suivant est désigné **avant** de traiter le
        /// courant (`NextItem = TreeNext(Item)`), puisque le déplacer change sa
        /// place dans l'arbre. Un fichier déplacé plus haut sera donc revisité,
        /// exactement comme dans l'original.
        mutating func walk(_ body: (inout Pass, Int32) -> Bool) {
            var next = order.items.first?.position
            let total = Double(max(volume.partition.clusterCount, 1))
            while let current = next {
                next = order.successor(of: current)
                // L'avancement de JkDefrag est une position sur le disque, pas
                // un compte de fichiers : c'est ce que dessinait son écran.
                if let index = order.index(of: current) {
                    sink.progress = Double(order.items[index].lcn) / total
                }
                guard body(&self, current) else { return }
            }
        }

        // MARK: Phase 2 — `Defragment`

        /// `Defragment` (`JkDefragLib.cpp:3973`).
        mutating func defragment(phase: Int) {
            walk { pass, position in
                let file = pass.volume.files[Int(position)]
                guard !file.isContiguous else { return true }
                let zone = pass.order.items[pass.order.index(of: position)!].zone
                let total = file.clusterCount

                // Un trou à la taille dans sa zone, sinon le plus grand ; puis
                // la même chose depuis le début du volume. Rien du tout : le
                // disque est plein, et l'original arrête la passe entière.
                guard let first = pass.gap(from: pass.zones[Int(zone)], size: total, mustFit: false)
                        ?? pass.gap(from: 0, size: total, mustFit: false) else { return false }

                if first.length >= total {
                    pass.move(position, vcn: 0, length: total, to: first.start,
                              phase: phase, pass: 0)
                    return true
                }

                // Par tranches, chacune dans le plus grand trou du moment.
                var gap = first
                var done: UInt32 = 0
                var slices = 0
                repeat {
                    let clusters = min(gap.length, total - done)

                    // Une tranche qui ne dépasse pas le premier morceau qu'elle
                    // emporterait ne recollerait rien : elle ne ferait que le
                    // découper. Ces morceaux-là sont laissés en place.
                    var vcn: UInt32 = 0
                    for extent in pass.volume.files[Int(position)].extents {
                        if vcn >= done {
                            if clusters > extent.length { break }
                            done = vcn + extent.length
                        }
                        vcn += extent.length
                    }
                    if done >= total { break }

                    // L'original ne recalcule pas la tranche après avoir sauté
                    // des morceaux : elle peut déborder de la fin du fichier.
                    // `FSCTL_MOVE_FILE` refuse une plage qui sort du fichier,
                    // rien n'est copié — et comme `ClustersDone` avance quand
                    // même, la boucle s'arrête là. C'est une lecture de l'API et
                    // non une mesure ; la borner à la fin du fichier aurait
                    // inventé un déplacement que personne n'a demandé.
                    if clusters > total - done {
                        pass.report.overrunSlices += 1
                        break
                    }
                    guard pass.move(position, vcn: done, length: clusters, to: gap.start,
                                    phase: phase, pass: 0) else { break }
                    slices += 1
                    done += clusters

                    if done < total {
                        guard let next = pass.gap(from: pass.zones[Int(zone)],
                                                  size: total - done, mustFit: false) else { break }
                        gap = next
                    }
                } while done < total
                pass.report.slices += max(slices - 1, 0)
                return true
            }
        }

        // MARK: Phases 3 et 5 — `Fixup`

        /// `Fixup` (`JkDefragLib.cpp:3781`).
        ///
        /// Un trou courant par zone : tant qu'un fichier y tient, on le pose à
        /// la suite du précédent sans relire le bitmap. C'est ce qui donne à
        /// cette passe son allure — une file de fichiers déposés côte à côte au
        /// fond du volume.
        mutating func fixup(phase: Int) {
            var gaps: [Extent] = Array(repeating: Extent(start: 0, length: 0), count: 3)
            let pass = phase == 2 ? 1 : 3
            walk { this, position in
                let index = this.order.index(of: position)!
                let item = this.order.items[index]
                let file = this.volume.files[Int(position)]
                let zone = Int(item.zone)

                var moveMe = !file.isContiguous
                if !moveMe, let mft = this.volume.mftZone, mft.contains(item.lcn) { moveMe = true }
                if !moveMe, zone == 1, item.lcn < this.zones[1] { moveMe = true }
                if !moveMe, zone == 2, item.lcn < this.zones[2] { moveMe = true }
                guard moveMe else { return true }

                if item.clusters > gaps[zone].length {
                    guard let found = this.gap(from: this.zones[zone], size: item.clusters,
                                               mustFit: true) else {
                        this.report.fixupFailures += 1
                        gaps[zone] = Extent(start: gaps[zone].start, length: 0)
                        return true
                    }
                    gaps[zone] = found
                }

                // Le trou mémorisé n'est pas relu. Or chaque zone a le sien, et
                // rien n'empêche deux zones de viser le même : un fichier
                // ordinaire envoyé au-delà du début des space hogs trouve un trou
                // que la zone 2 est peut-être déjà en train de remplir. L'original
                // a exactement ce défaut, et le paie par un déplacement refusé.
                let target = gaps[zone].start
                if this.move(position, vcn: 0, length: item.clusters, to: target,
                             phase: phase, pass: pass) {
                    gaps[zone] = Extent(start: target + item.clusters,
                                        length: gaps[zone].length - item.clusters)
                } else {
                    gaps[zone] = Extent(start: target, length: 0)
                }
                return true
            }
        }

        // MARK: Phase 4 — `OptimizeVolume`

        /// `OptimizeVolume` (`JkDefragLib.cpp:4818`).
        mutating func optimize(phase: Int) {
            let total = UInt32(volume.partition.clusterCount)
            for zone in UInt8(0)...2 {
                var begin = zones[Int(zone)]
                var retry = 0
                while begin < total {
                    // Le trou suivant, où qu'il soit : la recherche n'est pas
                    // bornée à la zone, seuls les fichiers le sont.
                    guard let found = gap(from: begin, size: 0, mustFit: true) else { break }
                    begin = found.start
                    sink.progress = Double(begin) / Double(total)
                    var end = found.end
                    report.gapsVisited += 1

                    // Tout ce qui pourrait venir combler ce trou : les fichiers
                    // de la zone situés au-dessus. Plus rien, et la zone est
                    // finie.
                    var above: UInt64 = 0
                    for item in order.items[order.lowerBound(end)...] where item.zone == zone {
                        above += UInt64(item.clusters)
                    }
                    if above == 0 { break }

                    // Chercher une combinaison exacte n'a de sens que s'il y a
                    // assez de fichiers au-dessus pour remplir le trou.
                    var perfectFit = UInt64(end - begin) <= above

                    while begin < end && retry < 5 {
                        var chosen: Int32?
                        if perfectFit {
                            chosen = findBestItem(start: begin, end: end, zone: zone)
                            if chosen == nil {
                                perfectFit = false
                                chosen = findHighestItem(start: begin, end: end, zone: zone)
                            }
                        } else {
                            chosen = findHighestItem(start: begin, end: end, zone: zone)
                        }
                        guard let position = chosen else { break }

                        let clusters = volume.files[Int(position)].clusterCount
                        if move(position, vcn: 0, length: clusters, to: begin,
                                phase: phase, pass: 2) {
                            begin += clusters
                            retry = 0
                        } else {
                            // `GapEnd = GapBegin` : le même trou sera relu au
                            // tour suivant, avec un essai de moins. Le fichier
                            // refusé est devenu immobile, un autre sera choisi.
                            end = begin
                            retry += 1
                            report.gapRetries += 1
                        }
                    }

                    // Un trou qu'on n'a pas pu remplir est sauté.
                    if begin < end {
                        report.gapsSkipped += 1
                        begin = end
                        retry = 0
                    }
                }
            }
        }

        /// `FindHighestItem` (`JkDefragLib.cpp:2565`) : en partant du fond du
        /// disque, le premier fichier de la zone qui tient dans le trou.
        ///
        /// Le **plus haut** qui tient, et non le plus gros — la lecture de
        /// `ALGO.md` §6.4 dit « le plus gros qui rentre », et c'est inexact :
        /// le parcours s'arrête au premier qui convient en descendant. Ce qui
        /// vide le disque par le fond, et c'est cela qu'on entend.
        mutating func findHighestItem(start: UInt32, end: UInt32, zone: UInt8) -> Int32? {
            report.highestFits += 1
            let size = end - start
            var index = order.count - 1
            while index >= 0 {
                let item = order.items[index]
                if item.lcn < end { return nil }
                if item.zone == zone, item.clusters <= size { return item.position }
                index -= 1
            }
            return nil
        }

        /// `FindBestItem` (`JkDefragLib.cpp:2637`) : le premier fichier d'une
        /// combinaison qui remplit le trou au cluster près.
        ///
        /// Un glouton qui rembobine : en descendant depuis le fond du disque,
        /// on retient chaque fichier qui tient dans ce qui reste du trou. Si l'un
        /// tombe pile, la combinaison est trouvée et on rend **le premier**
        /// retenu — les autres seront retrouvés aux appels suivants, sur un trou
        /// plus petit. Arrivé sous le trou sans succès, on repart du fichier qui
        /// suit le premier retenu, et on recommence.
        ///
        /// Deux sorties anticipées : tout ce qui reste au-dessus ne suffirait
        /// pas à remplir le trou, ou le budget de visites est épuisé.
        mutating func findBestItem(start: UInt32, end: UInt32, zone: UInt8) -> Int32? {
            report.perfectFitSearches += 1
            let full = end - start
            var remaining = full
            var sum: UInt64 = 0
            var firstIndex: Int?
            var visits = 0
            var index = order.count - 1

            while index >= 0 {
                let item = order.items[index]
                visits += 1

                if item.lcn < end {
                    // Passé sous le trou.
                    report.perfectFitPeakVisits = max(report.perfectFitPeakVisits, visits)
                    guard let first = firstIndex else { return nil }
                    if sum < UInt64(full) { return nil }
                    if visits > strategy.perfectFitVisits {
                        report.perfectFitsExhausted += 1
                        return nil
                    }
                    // `Item = FirstItem ; continue` : la boucle reprend sur
                    // l'élément qui suit le premier retenu.
                    index = first - 1
                    firstIndex = nil
                    remaining = full
                    sum = 0
                    continue
                }

                index -= 1
                guard item.zone == zone else { continue }
                if item.clusters < full { sum += UInt64(item.clusters) }
                if item.clusters > remaining { continue }
                if item.clusters == remaining {
                    report.perfectFitPeakVisits = max(report.perfectFitPeakVisits, visits)
                    report.perfectFitsFound += 1
                    return firstIndex.map { order.items[$0].position } ?? item.position
                }
                remaining -= item.clusters
                if firstIndex == nil { firstIndex = index + 1 }
            }
            return nil
        }
    }
}
