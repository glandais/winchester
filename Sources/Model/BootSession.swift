import Foundation
import DiskCore

/// Démarrer un disque de la galerie.
///
/// Le scénario de démarrage livré décrit le disque en **fractions** — « les
/// pilotes sont à 7,5 % du plateau, la base de registre à 12,5 % » — et ne peut
/// donc vivre que sur le disque pour lequel ces fractions ont été réglées à
/// l'oreille. Ici on ne décrit rien de tel : on nomme des **fichiers**, pris
/// dans le catalogue du volume généré, et ce sont les extents que l'allocateur
/// leur a donnés qui décident où va la tête.
///
/// Le bruit d'un démarrage devient alors un résidu de l'histoire du volume,
/// exactement comme la fragmentation en est un : on ne demande jamais « un
/// démarrage qui crépite », on dit « charge les pilotes », et ce qu'on entend
/// dépend de l'endroit où deux ans d'usage les ont laissés.
///
/// Et, contrairement à la défragmentation, cela ne demande rien au format : là
/// où ranger un volume a demandé deux outils — celui de 95 sur FAT, celui de XP
/// sur NTFS — parce que le format datait l'outil, un démarrage n'en demande
/// aucun. Il ouvre des fichiers, et les vingt profils y ont droit.
enum BootSession {}

// MARK: - Ce que la machine fait quand elle ne lit pas

/// Un démarrage n'est pas une suite de lectures collées les unes aux autres :
/// entre deux fichiers, le processeur décompresse, relocalise, initialise. Le
/// disque attend pendant ce temps, et le temps de démarrage est la somme des
/// deux.
///
/// Les deux constantes sont **calées pour que le total tombe sur les durées de
/// l'époque** — une trentaine de secondes pour un Windows 95, une bonne minute
/// pour un Vista — sur un volume fraîchement installé. Elles ne prétendent pas
/// mesurer un processeur : ce qu'elles fixent, c'est le plancher sous lequel un
/// démarrage ne descend pas même avec un disque parfait. Tout ce qui dépasse ce
/// plancher est du disque, et c'est cela qu'on écoute.
struct ThinkModel: Sendable {

    /// Secondes de calcul par fichier ouvert : décider de l'ouvrir, résoudre
    /// ses imports, l'enregistrer.
    var perFile: Double
    /// Secondes de calcul par mégaoctet lu : décompression et relocalisation.
    var perMegabyte: Double

    func seconds(bytes: Int) -> Double {
        perFile + perMegabyte * Double(bytes) / 1_048_576
    }
}

// MARK: - Ce qu'un acte du démarrage va chercher

/// Comment les fichiers d'un acte sont choisis parmi les candidats.
enum BootOrder: Sendable {
    /// L'ordre du parcours de l'arborescence — celui dans lequel l'installeur
    /// les a écrits. C'est ce que suit un chargeur qui lit un répertoire.
    case walk
    /// Un ordre décidé ailleurs qu'au disque : la base de registre, la liste
    /// de services, les dépendances d'un exécutable. Il n'a aucune raison de
    /// suivre le répertoire, et c'est **lui** qui fait crépiter un démarrage
    /// même sur une installation fraîche.
    case declared
    /// Les plus gros d'abord : le noyau et sa couche d'abstraction.
    case largestFirst
    /// Dans l'ordre du disque. C'est ce que fait le préchargeur de Windows XP,
    /// puis SuperFetch : il retient ce qu'un démarrage a lu la fois d'avant, le
    /// range par position et le relit d'une seule course du bras. Les systèmes
    /// d'avant ne le faisaient pas — d'où le crépitement de 1995 et le
    /// ronronnement de 2003 sur la même étape.
    case byPosition
}

/// Le filtre d'un acte : ce qu'il accepte de lire, et combien.
struct BootQuery: Sendable {

    var categories: Set<FileCategory>
    /// Extensions acceptées, en minuscules, sans le point. Vide = toutes.
    var extensions: Set<String> = []
    /// Restreint aux fichiers d'une application donnée, par préfixes de chemin.
    var directories: [String] = []
    var order: BootOrder = .walk
    /// Part des candidats retenue, avant plafonds.
    var fraction: Double = 1
    var fileCap: Int
    var byteCap: Int
    /// Ce qu'on lit au plus d'un seul fichier. Un fichier d'échange de deux
    /// gigaoctets n'est pas relu de bout en bout au démarrage : on en touche
    /// quelques pages.
    var bytesPerFile: Int = .max
    /// Part des fichiers retenus qui sont réécrits après lecture — journaux,
    /// fichiers de préchargement, ruches de registre.
    var writeBack: Double = 0

    func accepts(_ record: FileRecord, path: @autoclosure () -> String) -> Bool {
        guard categories.contains(record.category) else { return false }
        if !extensions.isEmpty {
            guard let dot = record.name.lastIndex(of: "."),
                  extensions.contains(record.name[record.name.index(after: dot)...].lowercased())
            else { return false }
        }
        if !directories.isEmpty {
            let lowered = path().lowercased()
            guard directories.contains(where: { lowered.hasPrefix($0) }) else { return false }
        }
        return true
    }
}

/// Une étape du démarrage : ce qu'elle raconte, et ce qu'elle lit.
struct BootAct: Sendable {

    enum Source: Sendable {
        /// Rien n'est lu. Le POST d'une machine d'époque comptait la mémoire et
        /// interrogeait les contrôleurs pendant que le plateau montait en
        /// régime : l'acte n'existe que pour que cette attente porte un nom.
        case idle
        /// Ce que le système lit avant de savoir lire un fichier : secteur
        /// d'amorçage, tables d'allocation, racine.
        case mount
        case files(BootQuery)
    }

    let id: String
    let label: String
    let detail: String
    let source: Source

    var descriptor: PhaseDescriptor {
        PhaseDescriptor(id: id, label: label, detail: detail)
    }
}

// MARK: - Le démarrage d'une époque

/// Ce que la machine fait au démarrage, tel que son système d'exploitation le
/// décidait.
struct BootScript: Sendable {

    let osName: String
    /// Durée du POST : comptage mémoire, détection des disques. Le plateau
    /// monte en régime pendant ce temps et rien n'est encore lu.
    let post: Double
    let think: ThinkModel
    let acts: [BootAct]
    /// Silence final, une fois la machine posée.
    let tail: Double = 4.0

    var phases: [PhaseDescriptor] { acts.map(\.descriptor) }
}

extension BootScript {

    /// Le démarrage que décrit un profil.
    ///
    /// L'époque entre par deux portes : le **volume** de ce qui est chargé —
    /// vingt fichiers pour MS-DOS, quinze cents pour Vista — et les **noms**
    /// des étapes, qui ne sont pas les mêmes d'un système à l'autre. Le reste
    /// de la mécanique est commun : on ouvre des fichiers, on les lit, on
    /// calcule entre deux.
    static func forProfile(_ spec: ProfileSpec, launching app: AppManifest?) -> BootScript {
        let era = Era.matching(spec)
        return BootScript(osName: era.osName,
                          post: era.post,
                          think: era.think,
                          acts: era.acts(launching: app))
    }

    /// Les budgets d'une époque, et rien d'autre. Tout ce qui varie d'un
    /// système à l'autre est ici, en un seul endroit lisible.
    struct Era: Sendable {

        let os: String
        let osName: String
        let post: Double
        let think: ThinkModel
        /// Fichiers du noyau, chargés en premier et les plus gros.
        let kernelFiles: Int
        /// Pilotes et bibliothèques système, dans l'ordre de la base de
        /// registre. C'est le gros de la passe, et le gros du bruit.
        let driverFiles: Int
        /// Services, ruches, journaux : petits fichiers, et des écritures.
        let serviceFiles: Int
        /// Ouverture de session : polices, aide, caches.
        let shellFiles: Int
        /// Plafond d'octets pour le lancement de l'application. C'est lui qui
        /// empêche un jeu de 2007 de faire durer le lancement une demi-heure —
        /// on charge un niveau, pas le disque entier.
        let appBytes: Int
        /// Dans quel ordre le système lit ce qu'il a décidé de lire.
        ///
        /// Jusqu'à Windows 98 il n'y avait rien : les fichiers partaient dans
        /// l'ordre du registre, et le bras suivait. Windows XP a introduit le
        /// préchargeur de démarrage, qui garde la trace des six derniers
        /// démarrages, range la liste par position sur le disque et la relit
        /// d'une seule course ; Vista a poussé la même idée avec SuperFetch.
        /// C'est la différence la plus audible entre deux époques, et elle ne
        /// tient pas au matériel.
        let prefetch: BootOrder
        /// Étiquettes des huit actes, dans l'ordre.
        let labels: [(String, String, String)]

        static let all: [Era] = [

            // 1993 — la machine démarre en deux temps : MS-DOS, puis `WIN`.
            // La machine démarre en deux temps, et les deux ne chargent pas du
            // tout la même chose : une poignée de pilotes résidents au premier,
            // puis tout le noyau graphique au second. Les budgets suivent, ce
            // qui met l'acte le plus chargé sur `WIN` et non sur `CONFIG.SYS`.
            Era(os: "msdos-6.22+win31",
                osName: "MS-DOS 6.22 et Windows 3.1",
                post: 8.0,
                think: ThinkModel(perFile: 0.045, perMegabyte: 0.60),
                kernelFiles: 5, driverFiles: 16, serviceFiles: 14,
                shellFiles: 220, appBytes: 6_000_000,
                prefetch: .declared,
                labels: [
                    ("post", "POST BIOS",
                     "Comptage mémoire, détection des disques — le plateau monte en régime"),
                    ("mount", "Secteur d'amorçage",
                     "MBR, secteur de démarrage, table d'allocation"),
                    ("kernel", "IO.SYS et MSDOS.SYS",
                     "Le noyau DOS, lu d'un trait"),
                    ("drivers", "CONFIG.SYS et AUTOEXEC.BAT",
                     "HIMEM, EMM386, le pilote de CD-ROM, SMARTDRV — un fichier à la fois"),
                    ("services", "Invite de commandes",
                     "COMMAND.COM, l'environnement réécrit à chaque démarrage"),
                    ("shell", "WIN : chargement de Windows 3.1",
                     "Le noyau graphique, les pilotes d'écran, les polices — le gros du démarrage"),
                    ("app", "Lancement de l'application",
                     "Exécutable et bibliothèques, là où l'installeur les a laissés"),
                    ("settle", "Machine posée",
                     "Le fichier d'échange, quelques traînards"),
                ]),

            Era(os: "win95-osr1",
                osName: "Windows 95",
                post: 7.0,
                think: ThinkModel(perFile: 0.022, perMegabyte: 0.34),
                kernelFiles: 8, driverFiles: 260, serviceFiles: 40,
                shellFiles: 70, appBytes: 14_000_000,
                prefetch: .declared,
                labels: [
                    ("post", "POST BIOS",
                     "Comptage mémoire, détection des disques — le plateau monte en régime"),
                    ("mount", "Secteur d'amorçage",
                     "MBR, secteur de démarrage, table d'allocation"),
                    ("kernel", "Noyau",
                     "IO.SYS puis les trois grands exécutables du système"),
                    ("drivers", "Chargement des pilotes",
                     "Les VxD dans l'ordre du registre — le crépitement caractéristique"),
                    ("services", "Registre et services",
                     "Petites lectures entrecoupées d'écritures de journaux"),
                    ("shell", "Ouverture de session",
                     "Explorateur, polices, icônes — accès très dispersés"),
                    ("app", "Lancement de l'application",
                     "Exécutable et bibliothèques, là où l'installeur les a laissés"),
                    ("settle", "Bureau au repos",
                     "Fichier d'échange, traînards"),
                ]),

            Era(os: "win98se",
                osName: "Windows 98 SE",
                post: 6.0,
                think: ThinkModel(perFile: 0.015, perMegabyte: 0.22),
                kernelFiles: 8, driverFiles: 380, serviceFiles: 60,
                shellFiles: 110, appBytes: 40_000_000,
                prefetch: .declared,
                labels: [
                    ("post", "POST BIOS",
                     "Comptage mémoire, détection des disques — le plateau monte en régime"),
                    ("mount", "Secteur d'amorçage",
                     "MBR, secteur de démarrage, table d'allocation"),
                    ("kernel", "Noyau",
                     "Le noyau et sa couche d'abstraction, lus d'un trait"),
                    ("drivers", "Chargement des pilotes",
                     "VxD et pilotes WDM dans l'ordre du registre"),
                    ("services", "Registre et services",
                     "Ruches, journaux d'application — lectures et écritures mêlées"),
                    ("shell", "Ouverture de session",
                     "Explorateur, polices, aide — accès très dispersés"),
                    ("app", "Lancement de l'application",
                     "Exécutable et bibliothèques, là où l'installeur les a laissés"),
                    ("settle", "Bureau au repos",
                     "Fichier d'échange, traînards"),
                ]),

            Era(os: "winxp-sp1",
                osName: "Windows XP",
                post: 5.0,
                think: ThinkModel(perFile: 0.009, perMegabyte: 0.13),
                kernelFiles: 10, driverFiles: 600, serviceFiles: 110,
                shellFiles: 180, appBytes: 120_000_000,
                prefetch: .byPosition,
                labels: [
                    ("post", "POST BIOS",
                     "Comptage mémoire, détection des disques — le plateau monte en régime"),
                    ("mount", "Secteur d'amorçage",
                     "MBR, secteur de démarrage, métadonnées du volume"),
                    ("kernel", "Noyau et HAL",
                     "NTLDR, le noyau, la couche d'abstraction"),
                    ("drivers", "Chargement des pilotes",
                     "Les pilotes dans l'ordre du registre — le crépitement caractéristique"),
                    ("services", "Registre et services",
                     "Ruches SYSTEM et SOFTWARE, journaux — lectures et écritures mêlées"),
                    ("shell", "Ouverture de session",
                     "Explorateur, polices, préchargement — accès très dispersés"),
                    ("app", "Lancement de l'application",
                     "Exécutable et bibliothèques, là où l'installeur les a laissés"),
                    ("settle", "Bureau au repos",
                     "Préchargement réécrit, fichier d'échange, traînards"),
                ]),

            Era(os: "vista",
                osName: "Windows Vista",
                post: 6.0,
                think: ThinkModel(perFile: 0.009, perMegabyte: 0.09),
                kernelFiles: 10, driverFiles: 1_200, serviceFiles: 220,
                shellFiles: 400, appBytes: 340_000_000,
                prefetch: .byPosition,
                labels: [
                    ("post", "POST BIOS",
                     "Comptage mémoire, détection des disques — le plateau monte en régime"),
                    ("mount", "Secteur d'amorçage",
                     "MBR, secteur de démarrage, métadonnées du volume"),
                    ("kernel", "Noyau et HAL",
                     "Le gestionnaire de démarrage, le noyau, la couche d'abstraction"),
                    ("drivers", "Chargement des pilotes",
                     "Pilotes et assemblages côte à côte, dans l'ordre du registre"),
                    ("services", "Registre et services",
                     "Ruches, journaux d'événements — lectures et écritures mêlées"),
                    ("shell", "Ouverture de session",
                     "Bureau, polices, SuperFetch — accès très dispersés"),
                    ("app", "Lancement de l'application",
                     "Exécutable et bibliothèques, là où l'installeur les a laissés"),
                    ("settle", "Bureau au repos",
                     "SuperFetch réécrit, fichier d'échange, traînards"),
                ]),
        ]

        /// L'époque d'un profil, par son système, et à défaut par son année :
        /// une fiche peut nommer un système que cette table ne connaît pas, et
        /// il vaut mieux un démarrage approché qu'un refus.
        static func matching(_ spec: ProfileSpec) -> Era {
            if let exact = all.first(where: { $0.os == spec.os }) { return exact }
            let year = spec.timeline.start.year
            switch year {
            case ..<1995: return all[0]
            case ..<1998: return all[1]
            case ..<2001: return all[2]
            case ..<2005: return all[3]
            default:      return all[4]
            }
        }

        private func label(_ index: Int) -> (String, String, String) { labels[index] }

        func acts(launching app: AppManifest?) -> [BootAct] {

            func act(_ index: Int, _ source: BootAct.Source) -> BootAct {
                let (id, label, detail) = self.label(index)
                return BootAct(id: id, label: label, detail: detail, source: source)
            }

            var acts = [
                act(0, .idle),
                act(1, .mount),
                act(2, .files(BootQuery(categories: [.systemCore],
                                        extensions: ["exe", "com", "sys"],
                                        order: .largestFirst,
                                        fileCap: kernelFiles,
                                        byteCap: 24_000_000))),
                act(3, .files(BootQuery(categories: [.systemCore],
                                        extensions: ["dll", "vxd", "drv", "sys", "386", "exe"],
                                        order: prefetch,
                                        fraction: 0.35,
                                        fileCap: driverFiles,
                                        byteCap: 220_000_000,
                                        bytesPerFile: 192 * 1_024))),
                act(4, .files(BootQuery(categories: [.systemCore, .cache],
                                        order: .declared,
                                        fraction: 0.10,
                                        fileCap: serviceFiles,
                                        byteCap: 60_000_000,
                                        bytesPerFile: 96 * 1_024,
                                        writeBack: 0.30))),
                act(5, .files(BootQuery(categories: [.archive, .cache, .systemCore],
                                        order: prefetch,
                                        fraction: 0.18,
                                        fileCap: shellFiles,
                                        byteCap: 120_000_000,
                                        bytesPerFile: 192 * 1_024,
                                        writeBack: 0.12))),
            ]

            if let app {
                // Un lancement lit des exécutables, des bibliothèques et les
                // données que le programme a besoin d'avoir en mémoire — pas
                // les six cents images d'illustration livrées avec la suite.
                acts.append(act(6, .files(BootQuery(categories: [.application, .gameAsset],
                                                    directories: app.groups
                                                        .map { $0.directory.lowercased() },
                                                    order: prefetch,
                                                    fraction: 0.70,
                                                    fileCap: 900,
                                                    byteCap: appBytes,
                                                    bytesPerFile: appBytes / 3))))
            }

            acts.append(act(7, .files(BootQuery(categories: [.swap, .cache, .temporary],
                                                order: .declared,
                                                fraction: 0.08,
                                                fileCap: 24,
                                                byteCap: 12_000_000,
                                                bytesPerFile: 512 * 1_024,
                                                writeBack: 0.70))))
            return acts
        }
    }
}

// MARK: - Le plan d'un démarrage

/// Ce qu'un démarrage a lu, et ce qu'il en a coûté avant même de simuler le
/// disque : le plancher processeur, auquel s'ajoutera tout ce que le disque
/// fera attendre.
struct BootPlan {
    let partition: PartitionGeometry
    let osName: String
    let appName: String?
    let phases: [PhaseDescriptor]
    let requests: [BlockRequest]
    let filesRead: Int
    let bytesRead: Int
    let bytesWritten: Int
    let residentFiles: Int
    /// Somme des temps de calcul : la durée qu'aurait le démarrage si le disque
    /// répondait instantanément.
    let thinkSeconds: Double
    let post: Double
    let tail: Double
}

enum BootPlanner {

    /// Taille maximale d'une requête. Les pilotes de l'époque découpaient les
    /// lectures en tampons de quelques dizaines de kilo-octets ; ce qui compte
    /// ici, c'est que le découpage soit fin devant un extent, sinon un fichier
    /// contigu et un fichier haché produiraient le même nombre de requêtes.
    private static let maxRequestSectors = 128

    static func plan(disk: GeneratedDisk) -> BootPlan {

        let partition = GeneratedVolumeBridge.partition(of: disk)
        let app = launchedApplication(of: disk.spec)
        let script = BootScript.forProfile(disk.spec, launching: app)

        var builder = Builder(partition: partition,
                              think: script.think,
                              seed: disk.spec.seed &* 0x9E37_79B9)
        let walk = disk.catalog.directoryWalkOrder()
        // Le chemin d'un fichier se reconstruit en remontant l'arborescence :
        // on ne le demande qu'une fois, et seulement aux actes qui filtrent
        // par répertoire.
        var pathCache: [UInt32: String] = [:]

        for (index, act) in script.acts.enumerated() {
            switch act.source {
            case .idle:
                break
            case .mount:
                builder.emitMount(phase: index)
            case let .files(query):
                let chosen = select(query, from: walk, catalog: disk.catalog,
                                    consumed: &builder.consumed, paths: &pathCache,
                                    seed: disk.spec.seed &+ UInt64(index))
                builder.emit(files: chosen, query: query, phase: index)
            }
        }

        return BootPlan(partition: partition,
                        osName: script.osName,
                        appName: app?.displayName,
                        phases: script.phases,
                        requests: builder.requests,
                        filesRead: builder.filesRead,
                        bytesRead: builder.bytesRead,
                        bytesWritten: builder.bytesWritten,
                        residentFiles: builder.residentFiles,
                        thinkSeconds: builder.thinkSeconds,
                        post: script.post,
                        tail: script.tail)
    }

    /// L'application qu'on lance après l'ouverture de session : la première
    /// installée qui ne soit pas le système.
    ///
    /// C'est le choix le plus simple, et il tombe juste : le développeur lance
    /// son compilateur, la secrétaire sa suite bureautique, le joueur son jeu.
    /// Un profil qui n'a rien installé d'autre que son système — un poste de
    /// 1993 réduit à MS-DOS et Windows — saute simplement cet acte.
    static func launchedApplication(of spec: ProfileSpec) -> AppManifest? {
        for id in spec.installs where !systemManifests.contains(id) {
            if let manifest = AppLibrary.manifest(id: id) { return manifest }
        }
        return nil
    }

    /// Les manifestes qui **sont** le système, et qu'on ne « lance » donc pas :
    /// ils sont déjà chargés par les actes précédents. Liste explicite plutôt
    /// que déduite de la présence de fichiers système — Internet Explorer 5 en
    /// posait autant qu'un pilote, et reste une application qu'on lance.
    private static let systemManifests: Set<String> = [
        "msdos-6", "win31", "win95", "win98se", "winxp", "vista",
    ]

    // MARK: - Choix des fichiers

    private static func select(_ query: BootQuery,
                               from walk: [FileRecord],
                               catalog: FileCatalog,
                               consumed: inout Set<UInt32>,
                               paths: inout [UInt32: String],
                               seed: UInt64) -> [FileRecord] {

        guard query.fileCap > 0, !query.categories.isEmpty else { return [] }

        var candidates = walk.filter { record in
            guard !consumed.contains(record.id) else { return false }
            return query.accepts(record, path: {
                if let cached = paths[record.id] { return cached }
                let path = catalog.path(of: record).lowercased()
                paths[record.id] = path
                return path
            }())
        }
        guard !candidates.isEmpty else { return [] }

        switch query.order {
        case .walk:
            break
        case .declared:
            var rng = SeededGenerator(seed: seed)
            rng.shuffle(&candidates)
        case .largestFirst:
            // Tri stable : à taille égale, l'ordre du parcours tranche, sinon
            // deux exécutions pourraient ne pas donner le même noyau.
            candidates = candidates.enumerated()
                .sorted { ($0.element.logicalSize, UInt64($1.offset))
                        > ($1.element.logicalSize, UInt64($0.offset)) }
                .map(\.element)
        case .byPosition:
            // Le tirage reste celui du système ; le rangement par position se
            // fait une fois les fichiers retenus.
            var rng = SeededGenerator(seed: seed)
            rng.shuffle(&candidates)
        }

        let wanted = min(query.fileCap,
                         max(Int(Double(candidates.count) * query.fraction), 1))
        var chosen: [FileRecord] = []
        var bytes = 0
        for record in candidates {
            guard chosen.count < wanted, bytes < query.byteCap else { break }
            chosen.append(record)
            consumed.insert(record.id)
            bytes += Int(record.logicalSize)
        }

        // Le préchargeur ne choisit pas *quoi* lire — c'est le système qui le
        // décide — il choisit l'*ordre*. Le tri par position vient donc après
        // le tirage, sinon on ne retiendrait que le début du volume.
        if query.order == .byPosition {
            chosen = chosen.enumerated()
                .sorted { ($0.element.extents.first?.start ?? 0, UInt32($0.offset))
                        < ($1.element.extents.first?.start ?? 0, UInt32($1.offset)) }
                .map(\.element)
        }
        return chosen
    }

    // MARK: - Émission des requêtes

    /// Traduit une suite de fichiers en requêtes bloc, en tenant le compte du
    /// temps de calcul qui s'intercale entre elles.
    private struct Builder {

        let partition: PartitionGeometry
        let think: ThinkModel

        var requests: [BlockRequest] = []
        var consumed: Set<UInt32> = []
        var filesRead = 0
        var bytesRead = 0
        var bytesWritten = 0
        var residentFiles = 0
        var thinkSeconds: Double = 0

        /// Répertoires dont l'entrée a déjà été lue : sur FAT, on ne relit pas
        /// un répertoire pour chaque fichier qu'il contient.
        private var openedDirectories: Set<UInt32> = []
        /// Temps de calcul dû au fichier précédent, à placer devant le suivant.
        private var pending: Double = 0
        private var rng: SeededGenerator
        /// Rang du fichier, qui désigne son enregistrement dans la MFT.
        private var fileIndex = 0

        init(partition: PartitionGeometry, think: ThinkModel, seed: UInt64) {
            self.partition = partition
            self.think = think
            self.rng = SeededGenerator(seed: seed)
        }

        /// Ce que lit le système avant de savoir lire un fichier.
        mutating func emitMount(phase: Int) {
            for access in partition.scanAccesses {
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
            // Monter un volume, c'est aussi décider qu'il est propre : sur FAT
            // l'octet d'état de la table est réécrit, sur NTFS le journal.
            append(lba: partition.format.isFAT ? partition.fat1LBA : partition.dataStartLBA,
                   sectors: 1, isWrite: true, phase: phase)
            bytesWritten += DriveGeometry.bytesPerSector
            pending += think.perFile * 4
        }

        mutating func emit(files: [FileRecord], query: BootQuery, phase: Int) {
            // Un acte préchargé lit ses métadonnées d'un bloc.
            //
            // Le préchargeur ne retient pas que la liste des fichiers : il
            // retient aussi les enregistrements de MFT qui les décrivent, et
            // les lit d'une traite avant d'aller chercher la moindre donnée.
            // Sans cela, chaque ouverture ferait un aller-retour entre la MFT,
            // en tête du volume, et un fichier posé trois cents gigaoctets plus
            // loin — deux courses complètes du bras par fichier, et un
            // démarrage qui ne ressemble à rien de ce qu'on a entendu.
            let bulk = query.order == .byPosition && !partition.format.isFAT
            if bulk, !files.isEmpty {
                let sectors = files.count * partition.mftRecordSectors
                append(lba: partition.dataStartLBA + fileIndex * partition.mftRecordSectors,
                       sectors: sectors, isWrite: false, phase: phase)
                bytesRead += sectors * DriveGeometry.bytesPerSector
            }

            for record in files {
                if !bulk { open(record, phase: phase) }

                // Ce qu'on lit vraiment, et non ce que pèse le fichier : un
                // système à mémoire virtuelle ne charge pas une bibliothèque de
                // trois mégaoctets pour en appeler deux fonctions, il en pagine
                // ce qu'il touche. C'est cette taille-là qui coûte, au disque
                // comme au processeur.
                var touched = 0
                if record.isResident {
                    // Un petit fichier NTFS tient dans son enregistrement de
                    // MFT : il est déjà lu, il n'y a pas de données à chercher.
                    residentFiles += 1
                } else {
                    touched = min(Int(record.logicalSize), query.bytesPerFile)
                    emitData(record.extents, limit: touched, isWrite: false, phase: phase)
                    bytesRead += touched
                    if rng.unitInterval() < query.writeBack {
                        emitData(record.extents, limit: touched, isWrite: true, phase: phase)
                        bytesWritten += touched
                    }
                }

                filesRead += 1
                fileIndex += 1
                let cost = think.seconds(bytes: touched)
                pending += cost
                thinkSeconds += cost
            }
        }

        /// L'ouverture d'un fichier, avant toute donnée.
        private mutating func open(_ record: FileRecord, phase: Int) {
            let firstCluster = record.extents.first?.start
            let directory = openedDirectories.insert(record.directory).inserted
                ? firstCluster
                : nil
            for access in partition.openAccesses(fileIndex: fileIndex,
                                                 directoryFirstCluster: directory) {
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
        }

        /// Les extents d'un fichier, découpés en requêtes de taille bornée et
        /// arrêtés au bout de `limit` octets.
        private mutating func emitData(_ extents: [Extent], limit: Int,
                                       isWrite: Bool, phase: Int) {
            let perRequest = UInt32(max(maxRequestSectors / partition.clusterSectors, 1))
            var remaining = partition.clusters(forBytes: max(limit, 1))
            for extent in extents {
                var offset: UInt32 = 0
                while offset < extent.length && remaining > 0 {
                    let clusters = min(extent.length - offset, perRequest, UInt32(remaining))
                    append(lba: partition.lba(ofCluster: Int(extent.start + offset)),
                           sectors: Int(clusters) * partition.clusterSectors,
                           isWrite: isWrite,
                           phase: phase)
                    offset += clusters
                    remaining -= Int(clusters)
                }
                if remaining == 0 { break }
            }
        }

        private mutating func append(lba: Int, sectors: Int, isWrite: Bool, phase: Int) {
            requests.append(BlockRequest(issueTime: 0,
                                         lba: lba,
                                         sectorCount: sectors,
                                         isWrite: isWrite,
                                         phaseIndex: phase,
                                         thinkTime: pending))
            pending = 0
        }
    }
}

// MARK: - Le témoin

extension GeneratedDisk {

    /// Le même contenu, posé comme au premier jour : chaque fichier d'un seul
    /// tenant, tassé contre le début du volume dans l'ordre du parcours de
    /// l'arborescence.
    ///
    /// Ce n'est pas un disque qu'on afficherait — il n'a pas d'histoire, et
    /// aucun allocateur ne l'a produit. C'est le **témoin** : mêmes fichiers,
    /// mêmes tailles, même ordre de lecture, seule la place change. Ce qu'un
    /// démarrage y gagne est donc exactement ce que le vieillissement du volume
    /// lui coûte, et rien d'autre. Sans ce point de comparaison, une durée de
    /// démarrage ne veut rien dire : on ne saurait pas ce qui, dedans, vient du
    /// disque.
    func freshlyInstalled() -> GeneratedDisk {
        var copy = self
        // Sur NTFS, le début du volume n'est pas disponible : la zone que
        // l'allocateur réserve à la croissance de la MFT y est libre sans être
        // ouverte. Un témoin qui écrirait par-dessus se donnerait un avantage
        // que le vrai volume n'a jamais eu, et la comparaison serait faussée.
        var cursor = mftZone?.upperBound ?? 0
        for record in catalog.directoryWalkOrder() where !record.isResident {
            let length = record.extents.clusterCount
            guard length > 0 else { continue }
            var updated = record
            updated.entry.extents = [Extent(start: cursor, length: length)]
            cursor &+= length
            copy.catalog[record.id] = updated
        }
        return copy
    }
}
