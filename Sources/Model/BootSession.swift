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
/// Les deux constantes sont **calées pour que le total tombe sur des durées
/// cibles** (`boot(_:)`, la seule table où elles le sont). Elles ne prétendent
/// pas mesurer un processeur : ce qu'elles fixent, c'est le plancher sous lequel
/// un démarrage ne descend pas même avec un disque parfait. Tout ce qui dépasse
/// ce plancher est du disque, et c'est cela qu'on écoute.
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

extension ThinkModel {

    /// Le plancher processeur d'un démarrage, par système.
    ///
    /// **C'est le seul endroit où une durée de démarrage est calée**, et les
    /// cibles ne sont **pas des mesures d'époque** : ce sont les vingt durées
    /// que le modèle donnait avant la relecture des experts (`BOOT_TARGETS`,
    /// `Tools/Measure/bilan.py`). Caler dessus revient à demander au modèle
    /// corrigé de retomber sur les durées du modèle d'avant ; ce qui défend une
    /// constante, c'est la forme de l'ajustement, pas le niveau qu'il atteint.
    ///
    /// `perMegabyte` seul bouge d'un calage à l'autre, pour une raison
    /// physique : ce que les corrections du disque ont déplacé — le tour de
    /// plateau perdu, la table lue deux fois, les caches, les enregistrements
    /// de MFT épars — est un coût de lecture, au mégaoctet. Les résidus, eux,
    /// ne départagent plus les deux constantes : avec quatre profils par
    /// époque, fichiers et mégaoctets sont colinéaires (`fit-think.py`).
    ///
    /// Le niveau de 2003 et 2007 — 0,185 et 0,146 s par mégaoctet, un Vista à
    /// peine sous un XP sur des processeurs trois ou quatre fois plus rapides —
    /// n'est justifié par rien dans la description : c'est la question des
    /// cibles, que seules des mesures d'époque trancheraient. Le 0,93 de 1993
    /// dit la même chose autrement : quand la fiche du Conner a rendu au
    /// disque ses 79 secteurs par piste (chantier 40), le démarrage a gagné
    /// quatre secondes que la cible n'accorde pas, et c'est le processeur qui
    /// les reprend. L'histoire des calages est dans `LEDGER.md` (chantiers 22,
    /// 26, 29 et 41).
    ///
    /// **Windows 7 n'a pas de cible** : le modèle d'avant la relecture ne
    /// connaissait pas 2012. Ses deux constantes sont celles de Vista divisées
    /// par 1,5 — un processeur de 2012 exécute un fil à peu près deux fois plus
    /// vite qu'un Core 2 de 2007, et Windows 7 en fait un peu plus au
    /// démarrage. **Une hypothèse**, que rien ne recoupe (chantier 34).
    static func boot(_ os: String) -> ThinkModel {
        switch os {
        case "msdos-6.22+win31": ThinkModel(perFile: 0.045, perMegabyte: 0.93)
        case "win95-osr1":       ThinkModel(perFile: 0.022, perMegabyte: 0.41)
        case "win98se":          ThinkModel(perFile: 0.015, perMegabyte: 0.24)
        case "winxp-sp1":        ThinkModel(perFile: 0.009, perMegabyte: 0.185)
        case "win7-sp1":         ThinkModel(perFile: 0.006, perMegabyte: 0.10)
        default:                 ThinkModel(perFile: 0.009, perMegabyte: 0.146)  // Vista
        }
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
    /// Dans l'ordre du disque : le préchargement de Vista (SuperFetch) et de
    /// Windows 7 (ReadyBoot), tel que le modèle le suppose — il retient ce
    /// qu'un démarrage a lu la fois d'avant, le range par position et le
    /// relit d'une seule course du bras. **Sans source** : le code de XP ne
    /// dit rien de ces deux systèmes, et le préchargeur de XP, lui, ne trie
    /// pas par position (`firstAccess`).
    case byPosition
    /// Le préchargeur de Windows XP, d'après son code : la trace des
    /// démarrages précédents, rangée par **premier accès**
    /// (`PfSvSortSectionNodesByFirstAccess`, `pfsvc.c:2631-2635`), relue
    /// fichier après fichier par lots que le noyau émet d'un bloc
    /// (`prefetch.c:5281`). Le balayage qu'on entend ne vient pas d'un tri :
    /// c'est la file d'`atapi` qui sert chaque lot par LBA (`AtapiQueue`).
    /// Le tirage est celui du système, comme pour `byPosition` ; seul l'ordre
    /// diffère. Les systèmes d'avant n'avaient rien de tel — d'où le
    /// crépitement de 1995 et le ronronnement de 2003 sur la même étape.
    case firstAccess
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

    let os: String
    let osName: String
    /// Durée du POST : comptage mémoire, détection des disques. Le plateau
    /// monte en régime pendant ce temps et rien n'est encore lu.
    let post: Double
    let think: ThinkModel
    /// Granularité d'une lecture de données, en octets (`Era.readGranularity`).
    let readGranularity: Int
    /// Chaque lecture met-elle à jour la date de dernier accès
    /// (`Era.stampsAccess`) ?
    let stampsAccess: Bool
    /// Intervalle entre deux vidages des métadonnées salies, en secondes : le
    /// même cache que pendant une installation (`InstallEra.flush`).
    let metadataFlushSeconds: Double
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
        let flush: Double = switch InstallEra.matching(spec).flush {
        case .everyFile: 0
        case let .every(seconds): seconds
        }
        return BootScript(os: era.os,
                          osName: era.osName,
                          post: era.post,
                          think: era.think,
                          readGranularity: era.readGranularity,
                          stampsAccess: era.stampsAccess,
                          metadataFlushSeconds: flush,
                          acts: era.acts(launching: app))
    }

    /// Les budgets d'une époque, et rien d'autre. Tout ce qui varie d'un
    /// système à l'autre est ici, en un seul endroit lisible.
    struct Era: Sendable {

        let os: String
        let osName: String
        let post: Double
        /// Le plancher processeur de l'époque, pris dans la seule table où
        /// une durée de démarrage est calée (`ThinkModel.boot`).
        var think: ThinkModel { ThinkModel.boot(os) }
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
        /// préchargeur de démarrage. Il garde pour chaque page l'usage des
        /// **huit** derniers démarrages (`PF_PAGE_HISTORY_SIZE`,
        /// `public/internal/base/inc/prefetch.h:180`) et ne précharge que ce
        /// qui a servi au moins deux fois — sa sensibilité ne descend jamais
        /// sous 2 pour le démarrage (`pfsvc.c:4301-4311`) ; il relit la trace
        /// par lots, dans l'ordre du premier accès, et la file d'`atapi` les
        /// sert par position (`BootOrder.firstAccess`). Le modèle n'a pas
        /// d'historique : il suppose une machine qui démarre chaque jour de
        /// la même façon, dont la trace est donc celle du démarrage joué.
        /// Vista et 7 ont poussé l'idée (SuperFetch, ReadyBoot) ; ils gardent
        /// le tri par position du modèle, sans source (`byPosition`). C'est la
        /// différence la plus audible entre deux époques, et elle ne tient pas
        /// au matériel.
        let prefetch: BootOrder
        /// Étiquettes des huit actes, dans l'ordre.
        let labels: [(String, String, String)]

        /// Ce que le système lit au moins quand il lit un fichier, en octets.
        ///
        /// Pas un cluster : le cluster est l'unité d'**allocation**, pas de
        /// lecture. MS-DOS lisait les secteurs qu'on lui demandait. À partir de
        /// Windows 95, les lectures passent par le cache, qui travaille par
        /// **pages de 4 Ko** — sur un volume de 1996 en clusters de 32 Ko, lire
        /// les 2 Ko d'un `.ini` ne coûte donc que 4 Ko, et non 32.
        var readGranularity: Int {
            os == "msdos-6.22+win31" ? DriveGeometry.bytesPerSector : 4_096
        }

        /// Lire un fichier met-il à jour sa date de dernier accès ?
        ///
        /// Sous NT, et jusqu'à XP inclus, **toute lecture** réécrit
        /// `LastAccessTime` dans l'enregistrement de MFT du fichier ; Vista
        /// l'a désactivé par défaut (`NtfsDisableLastAccessUpdate`), et
        /// Windows 7 l'a gardé désactivé. VFAT a le
        /// même mécanisme depuis Windows 95 — une date de dernier accès dans
        /// l'entrée de répertoire, que MS-DOS n'avait pas. Les deux ne
        /// réécrivent la date que si elle a changé — NTFS ne descend pas sous
        /// l'heure, FAT ne note que le jour —, ce qui est toujours le cas au
        /// premier démarrage de la journée, et jamais à un redémarrage
        /// d'installation.
        ///
        /// C'est l'écart d'époque le plus net entre 2003 et 2007, et il ne tient
        /// à aucun matériel : des centaines d'écritures de métadonnées,
        /// différées et groupées, **ailleurs** que là où l'on vient de lire.
        var stampsAccess: Bool {
            !["msdos-6.22+win31", "vista", "win7-sp1"].contains(os)
        }

        static let all: [Era] = [

            // 1993 — la machine démarre en deux temps : MS-DOS, puis `WIN`.
            // La machine démarre en deux temps, et les deux ne chargent pas du
            // tout la même chose : une poignée de pilotes résidents au premier,
            // puis tout le noyau graphique au second. Les budgets suivent, ce
            // qui met l'acte le plus chargé sur `WIN` et non sur `CONFIG.SYS`.
            Era(os: "msdos-6.22+win31",
                // Le seul nom de système qui contienne un mot à traduire, et
                // il ne l'est pas : `Tools/Measure/readme-tables.py` le recopie
                // tel quel dans la table des démarrages du `README.md`, qui est
                // française. Un « and » ici y ferait un diff à chaque mesure.
                osName: "MS-DOS 6 et Windows 3.1",
                post: 8.0,
                kernelFiles: 5, driverFiles: 16, serviceFiles: 14,
                shellFiles: 220, appBytes: 6_000_000,
                prefetch: .declared,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.fat.detail", defaultValue: "MBR, boot sector, allocation table")),
                    ("kernel", String(localized: "boot.dosKernel", defaultValue: "IO.SYS and MSDOS.SYS"),
                     String(localized: "boot.dosKernel.detail", defaultValue: "The DOS kernel, read in one sweep")),
                    ("drivers", String(localized: "boot.dosConfig", defaultValue: "CONFIG.SYS and AUTOEXEC.BAT"),
                     String(localized: "boot.dosConfig.detail", defaultValue: "HIMEM, EMM386, the CD-ROM driver, SMARTDRV — one file at a time")),
                    ("services", String(localized: "boot.prompt", defaultValue: "Command prompt"),
                     String(localized: "boot.prompt.detail", defaultValue: "COMMAND.COM, the environment rewritten at every boot")),
                    ("shell", String(localized: "boot.win31", defaultValue: "WIN: loading Windows 3.1"),
                     String(localized: "boot.win31.detail", defaultValue: "The graphics kernel, the display drivers, the fonts — the bulk of the boot")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.settled", defaultValue: "Machine settled"),
                     String(localized: "boot.settled.win31.detail", defaultValue: "The page file, a few stragglers")),
                ]),

            Era(os: "win95-osr1",
                osName: "Windows 95",
                post: 7.0,
                kernelFiles: 8, driverFiles: 260, serviceFiles: 40,
                shellFiles: 70, appBytes: 14_000_000,
                prefetch: .declared,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.fat.detail", defaultValue: "MBR, boot sector, allocation table")),
                    ("kernel", String(localized: "boot.kernel", defaultValue: "Kernel"),
                     String(localized: "boot.kernel.win9x.detail", defaultValue: "IO.SYS then the three big system executables")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.vxd.detail", defaultValue: "The VxDs in registry order — the characteristic crackle")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.win95.detail", defaultValue: "Small reads interspersed with log writes")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.win95.detail", defaultValue: "Explorer, fonts, icons — very scattered accesses")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.desktop", defaultValue: "Desktop at rest"),
                     String(localized: "boot.settled.detail", defaultValue: "Page file, stragglers")),
                ]),

            Era(os: "win98se",
                osName: "Windows 98 SE",
                post: 6.0,
                kernelFiles: 8, driverFiles: 380, serviceFiles: 60,
                shellFiles: 110, appBytes: 40_000_000,
                prefetch: .declared,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.fat.detail", defaultValue: "MBR, boot sector, allocation table")),
                    ("kernel", String(localized: "boot.kernel", defaultValue: "Kernel"),
                     String(localized: "boot.kernel.win98.detail", defaultValue: "The kernel and its abstraction layer, read in one sweep")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.wdm.detail", defaultValue: "VxD and WDM drivers in registry order")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.win98.detail", defaultValue: "Hives, application logs — reads and writes mixed")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.win98.detail", defaultValue: "Explorer, fonts, help — very scattered accesses")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.desktop", defaultValue: "Desktop at rest"),
                     String(localized: "boot.settled.detail", defaultValue: "Page file, stragglers")),
                ]),

            Era(os: "winxp-sp1",
                osName: "Windows XP",
                post: 5.0,
                kernelFiles: 10, driverFiles: 600, serviceFiles: 110,
                shellFiles: 180, appBytes: 120_000_000,
                prefetch: .firstAccess,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.ntfs.detail", defaultValue: "MBR, boot sector, volume metadata")),
                    ("kernel", String(localized: "boot.kernelHAL", defaultValue: "Kernel and HAL"),
                     String(localized: "boot.kernelHAL.xp.detail", defaultValue: "NTLDR, the kernel, the abstraction layer")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.nt.detail", defaultValue: "The prefetcher's batches — MFT, directories, data, images — each in one sweep")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.xp.detail", defaultValue: "SMSS and services, on pages already prefetched — writes only")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.xp.detail", defaultValue: "Explorer and fonts, already prefetched — computing and writes")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.desktop", defaultValue: "Desktop at rest"),
                     String(localized: "boot.settled.xp.detail", defaultValue: "Prefetch rewritten, page file, stragglers")),
                ]),

            Era(os: "vista",
                osName: "Windows Vista",
                post: 6.0,
                kernelFiles: 10, driverFiles: 1_200, serviceFiles: 220,
                shellFiles: 400, appBytes: 340_000_000,
                prefetch: .byPosition,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.ntfs.detail", defaultValue: "MBR, boot sector, volume metadata")),
                    ("kernel", String(localized: "boot.kernelHAL", defaultValue: "Kernel and HAL"),
                     String(localized: "boot.kernelHAL.vista.detail", defaultValue: "The boot manager, the kernel, the abstraction layer")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.vista.detail", defaultValue: "Drivers and side-by-side assemblies, in registry order")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.vista.detail", defaultValue: "Hives, event logs — reads and writes mixed")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.vista.detail", defaultValue: "Desktop, fonts, SuperFetch — very scattered accesses")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.desktop", defaultValue: "Desktop at rest"),
                     String(localized: "boot.settled.vista.detail", defaultValue: "SuperFetch rewritten, page file, stragglers")),
                ]),

            // 2012 — la même mécanique que Vista, un peu plus de pilotes et de
            // services. ReadyBoot relit la trace des démarrages précédents ;
            // le modèle la range par position, comme pour Vista — une
            // hypothèse : le code de XP, le seul lu, ne trie pas, et c'est sa
            // file de port qui sert par position.
            Era(os: "win7-sp1",
                osName: "Windows 7",
                post: 5.0,
                kernelFiles: 10, driverFiles: 1_300, serviceFiles: 240,
                shellFiles: 450, appBytes: 500_000_000,
                prefetch: .byPosition,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.ntfs.detail", defaultValue: "MBR, boot sector, volume metadata")),
                    ("kernel", String(localized: "boot.kernelHAL", defaultValue: "Kernel and HAL"),
                     String(localized: "boot.kernelHAL.win7.detail", defaultValue: "The boot manager, winload, the kernel")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.win7.detail", defaultValue: "Drivers read back from the ReadyBoot trace, in disk order")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.vista.detail", defaultValue: "Hives, event logs — reads and writes mixed")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.win7.detail", defaultValue: "Desktop, taskbar, fonts — the last of the trace")),
                    ("app", String(localized: "boot.app", defaultValue: "Launching the application"),
                     String(localized: "boot.app.detail", defaultValue: "Executable and libraries, where the installer left them")),
                    ("settle", String(localized: "boot.desktop", defaultValue: "Desktop at rest"),
                     String(localized: "boot.settled.vista.detail", defaultValue: "SuperFetch rewritten, page file, stragglers")),
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
            case ..<2010: return all[4]
            default:      return all[5]
            }
        }

        /// La montée en régime d'une mise sous tension : le plateau est prêt
        /// un peu avant la fin du POST, qui l'attend. Le démarrage et la
        /// journée s'ouvrent tous deux par elle — c'est la même machine, le
        /// même matin — et la prennent ici pour ne pas se contredire.
        var spinUpDuration: Double { max(post - 0.6, 0.5) }

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
    /// Les fichiers ouverts, dans l'ordre où le démarrage les a lus : ce que
    /// le préchargeur de Windows XP écrit dans `Layout.ini` pour que le
    /// défragmenteur les range à la suite (`BootLayout`).
    let readOrder: [UInt32]
    let filesRead: Int
    let bytesRead: Int
    let bytesWritten: Int
    let residentFiles: Int
    /// Fichiers dont la date de dernier accès a été réécrite.
    let stampedFiles: Int
    /// Écritures de métadonnées qui les ont portées, une fois groupées.
    let stampWrites: Int
    /// Sous XP, les écritures du journal qui les précèdent.
    let stampLogWrites: Int
    /// Ce que le cache du système a fait, en une ligne de bilan : `SMARTDRV`
    /// en 1993, VCACHE et la table FAT32 en 1999. `nil` sans cache à décrire.
    let softwareCache: String?
    /// Somme des temps de calcul : la durée qu'aurait le démarrage si le disque
    /// répondait instantanément.
    let thinkSeconds: Double
    /// La file d'`atapi` à la fin du démarrage : sa clé, que la suite de la
    /// session reprend.
    var queue = AtapiQueue()
    let post: Double
    let tail: Double
}

enum BootPlanner {

    /// Taille maximale d'une requête. Les pilotes de l'époque découpaient les
    /// lectures en tampons de quelques dizaines de kilo-octets ; ce qui compte
    /// ici, c'est que le découpage soit fin devant un extent, sinon un fichier
    /// contigu et un fichier haché produiraient le même nombre de requêtes.
    private static let maxRequestSectors = 128

    /// Sous XP, la plus grande requête qui part au disque pour une lecture
    /// **hors cache** — celles du préchargeur, que `MmPrefetchPages` émet par
    /// suites de pages de n'importe quelle longueur : `classpnp` la découpe
    /// en paquets de `HwMaxXferLen`, le plus petit de la longueur maximale du
    /// port et de ses pages physiques moins une (`classpnp/xferpkt.c:60-74`).
    /// `atapi` annonce 128 Ko par SRB, en LBA48 comme sans
    /// (`MAX_TRANSFER_SIZE_PER_SRB`, `ide/inc/idep.h:31` ; `atapi/init.c:198-209`),
    /// et 32 pages — la HAL donne 33 registres à un maître PCI de 128 Ko
    /// (`halx86/i386/ixisasup.c:1006-1008`), `pciidex` en garde 32
    /// (`pciidex/bm.c:741`) : 31 pages, **124 Ko**. Ce qui passe par le
    /// cache, lui, reste à 64 Ko (`MAX_WRITE_BEHIND`, `MM_MAXIMUM_DISK_IO_SIZE`,
    /// `cache/cc.h:159, 175` ; une faute de vue du cache, 16 pages,
    /// `mm.h:62`) : `maxRequestSectors`.
    static let classPacketSectors = 248

    /// Sous XP, une faute de page dans une image hors préchargement lit la
    /// page fautive et au plus `MmCodeClusterSize` pages de plus — 7 sur une
    /// machine de plus de 19 Mo, soit 32 Ko (`mm/mminit.c:1511-1512`,
    /// `pagfault.c:2852-2870`). Les pages de données d'une image en lisent
    /// 16 Ko (`MmDataClusterSize`, 3) ; le modèle ne connaît pas les
    /// sections d'un exécutable, et lit tout comme du code.
    static let imageFaultSectors = 64

    /// - Parameters:
    ///   - launchesApplication: `false` pour un redémarrage en cours
    ///     d'installation, où l'on s'arrête au bureau ;
    ///   - firstOfTheDay: `false` pour ce même redémarrage : les fichiers qu'il
    ///     lit viennent d'être écrits ou lus, et leur date d'accès n'a pas à
    ///     changer.
    static func plan(disk: GeneratedDisk, launchesApplication: Bool = true,
                     firstOfTheDay: Bool = true) -> BootPlan {

        let partition = GeneratedVolumeBridge.partition(of: disk)
        let app = launchesApplication ? launchedApplication(of: disk.spec) : nil
        let script = BootScript.forProfile(disk.spec, launching: app)

        let numbering = partition.format.isFAT ? nil : MFTNumbering(disk: disk)
        var builder = Builder(partition: partition,
                              os: script.os,
                              think: script.think,
                              readGranularity: script.readGranularity,
                              stampsAccess: script.stampsAccess && firstOfTheDay,
                              flushSeconds: script.metadataFlushSeconds,
                              directories: DirectoryPlacement(disk: disk),
                              mftRecords: numbering?.files ?? [:],
                              directoryRecords: numbering?.directories ?? [:],
                              seed: disk.spec.seed &* 0x9E37_79B9)
        let walk = disk.catalog.directoryWalkOrder()
        // Le chemin d'un fichier se reconstruit en remontant l'arborescence :
        // on ne le demande qu'une fois, et seulement aux actes qui filtrent
        // par répertoire.
        var pathCache: [UInt32: String] = [:]
        // Ce que chaque acte lit, tiré d'abord : le tirage ne dépend que de ce
        // que les actes précédents ont déjà pris, pas de ce qu'ils émettent.
        var chosen: [Int: [FileRecord]] = [:]
        for (index, act) in script.acts.enumerated() {
            guard case let .files(query) = act.source else { continue }
            chosen[index] = select(query, from: walk, catalog: disk.catalog,
                                   consumed: &builder.consumed, paths: &pathCache,
                                   seed: disk.spec.seed &+ UInt64(index))
        }
        if builder.prefetchBursts, !partition.format.isFAT {
            emitWithXPPrefetcher(script: script, chosen: chosen, catalog: disk.catalog,
                                 builder: &builder)
        } else {
            for (index, act) in script.acts.enumerated() {
                switch act.source {
                case .idle:
                    break
                case .mount:
                    builder.emitMount(phase: index)
                case let .files(query):
                    builder.emit(files: chosen[index] ?? [], query: query, phase: index)
                }
            }
        }
        // Sous XP, le démarrage finit avec le silence final : ce que le lazy
        // writer n'a pas posé d'ici là part après lui.
        builder.flushStamps(phase: script.acts.count - 1, until: script.tail)

        return BootPlan(partition: partition,
                        osName: script.osName,
                        appName: app?.displayName,
                        phases: script.phases,
                        requests: builder.requests,
                        readOrder: builder.readOrder,
                        filesRead: builder.filesRead,
                        bytesRead: builder.bytesRead,
                        bytesWritten: builder.bytesWritten,
                        residentFiles: builder.residentFiles,
                        stampedFiles: builder.stampedFiles,
                        stampWrites: builder.stampWrites,
                        stampLogWrites: builder.stampLogWrites,
                        softwareCache: builder.softwareCacheReport,
                        thinkSeconds: builder.thinkSeconds,
                        queue: builder.queue,
                        post: script.post,
                        tail: script.tail)
    }

    /// Le démarrage de XP, tel que son préchargeur le joue
    /// (`base/ntos/cache/prefboot.c`, `CcPfBootWorker`).
    ///
    /// Le noyau, la HAL, les ruches et les pilotes de démarrage sont lus par
    /// NTLDR, avant que le préchargeur n'existe : l'acte du noyau garde son
    /// modèle. Puis le fil du préchargeur, sur la trace des démarrages
    /// précédents — le **scénario de démarrage**, rangé par ordre de premier
    /// accès (`PfSvSortSectionNodesByFirstAccess`, `pfsvc.c:2631-2635`) :
    ///
    /// 1. les métadonnées, une fois pour tout le démarrage
    ///    (`CcPfPrefetchMetadata`, `prefboot.c:722`) : les enregistrements de
    ///    MFT des fichiers et des répertoires, par pages, d'un lot
    ///    (`FSCTL_FILE_PREFETCH`, `ntfs/fsctrl.c:19228-19433`), puis le
    ///    contenu de chaque répertoire, les parents avant les enfants
    ///    (`prefetch.c:5455-5470`) ;
    /// 2. la phase des pilotes système : un lot de pages de **données** — les
    ///    pages d'en-tête des images y sont —, puis un lot de pages
    ///    d'**images** (`prefboot.c:482-490, 855-929` ; `prefetch.c:4660-4668,
    ///    4930-4960`). Le démarrage l'attend avant d'initialiser les pilotes ;
    /// 3. tout le reste avant `SMSS`, en un passage — « si la mémoire le
    ///    permet » (`prefboot.c:761-773`) : données, puis images. Les pilotes
    ///    s'initialisent **pendant** ce lot, et `SMSS` l'attend
    ///    (`PreSmssPrefetchingDone`, `prefboot.c:936-955`).
    ///
    /// Les services et l'ouverture de session se font ensuite sur des pages
    /// déjà en mémoire : du calcul, des écritures, pas de lectures.
    /// L'application lancée a son propre scénario, préchargé à son lancement
    /// de la même façon — métadonnées, données, images (`CcPfPrefetchScenario`,
    /// `prefetch.c:4605-4640`). Le dernier acte (fichier d'échange,
    /// temporaires) reste hors trace : le fichier d'échange n'est pas une
    /// section, et un temporaire n'est pas vu deux démarrages sur huit.
    ///
    /// Ce que le modèle ne joue pas, et le dit : la troncature par la mémoire
    /// disponible (`prefboot.c:522-538, 776-810`) — la machine est supposée en
    /// avoir assez pour un seul passage avant `SMSS` ; la phase parallèle à
    /// l'initialisation vidéo (`prefboot.c:651-690`), qui demande la durée
    /// mesurée au démarrage précédent ; la présence de l'application dans la
    /// trace du démarrage, si elle est lancée dans les trente secondes.
    private static func emitWithXPPrefetcher(script: BootScript, chosen: [Int: [FileRecord]],
                                             catalog: FileCatalog, builder: inout Builder) {
        var boot: [(files: [FileRecord], query: BootQuery, phase: Int)] = []
        var drivers: Int?
        for (index, act) in script.acts.enumerated() {
            guard case let .files(query) = act.source,
                  ["drivers", "services", "shell"].contains(act.id) else { continue }
            if act.id == "drivers" { drivers = index }
            boot.append((chosen[index] ?? [], query, index))
        }
        for (index, act) in script.acts.enumerated() {
            switch act.source {
            case .idle:
                break
            case .mount:
                builder.emitMount(phase: index)
            case let .files(query):
                let files = chosen[index] ?? []
                switch act.id {
                case "drivers":
                    // Toute la trace du démarrage, pendant l'acte des pilotes.
                    builder.prefetchMetadata(files: boot.flatMap(\.files), catalog: catalog,
                                             phase: index)
                    builder.prefetchLots(builder.touched(files, query), phase: index,
                                         flow: .foreground)
                    // Les pilotes s'initialisent pendant le lot suivant : leur
                    // calcul avance le fil de l'hôte sans retenir le disque.
                    let initialization = builder.runOnPrefetchedPages(files: files, query: query,
                                                                      phase: index, deferred: true)
                    let rest = boot.filter { $0.phase != drivers }
                        .flatMap { builder.touched($0.files, $0.query) }
                    if !builder.prefetchLots(rest, phase: index, flow: .background,
                                             think: initialization) {
                        builder.pendThink(initialization)
                    }
                    builder.awaitPrefetch()
                case "services", "shell":
                    builder.runOnPrefetchedPages(files: files, query: query, phase: index,
                                                 deferred: false)
                case "app":
                    builder.prefetchMetadata(files: files, catalog: catalog, phase: index)
                    builder.prefetchLots(builder.touched(files, query), phase: index,
                                         flow: .foreground)
                    builder.runOnPrefetchedPages(files: files, query: query, phase: index,
                                                 deferred: false)
                default:
                    // Le noyau est lu par NTLDR, avant Mm ; le dernier acte,
                    // par fautes de page.
                    builder.emit(files: files, query: query, phase: index,
                                 inLayout: act.id == "kernel", imageFaults: act.id != "kernel")
                }
            }
        }
    }

    /// L'application qu'on lance après l'ouverture de session : la première
    /// installée qui ne soit pas le système.
    ///
    /// C'est le choix le plus simple, et il tombe juste : le développeur lance
    /// son compilateur, la secrétaire sa suite bureautique, le joueur son jeu.
    /// Un profil qui n'a rien installé d'autre que son système — un poste de
    /// 1993 réduit à MS-DOS et Windows — saute simplement cet acte.
    static func launchedApplication(of spec: ProfileSpec) -> AppManifest? {
        for id in spec.installs where !SetupLibrary.systemManifests.contains(id) {
            if let manifest = AppLibrary.manifest(id: id) { return manifest }
        }
        return nil
    }

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
        case .byPosition, .firstAccess:
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

    // MARK: - Les répertoires

    /// Où sont les répertoires du volume, et où chaque nom y a son entrée.
    struct DirectoryPlacement {
        let directories: [DirectoryRecord]
        let format: DirectoryFormat
        let fileOffsets: [UInt32: UInt64]
        let directoryOffsets: [UInt64]

        /// `nil` pour un volume dont aucun répertoire n'existe sur le disque —
        /// un volume construit à la main, qui ne sait pas où ils seraient.
        init?(disk: GeneratedDisk) {
            guard disk.catalog.directories.contains(where: \.exists) else { return nil }
            directories = disk.catalog.directories
            format = DiskGenerator.directoryFormat(for: disk.spec)
            (fileOffsets, directoryOffsets) = disk.catalog.entryOffsets(format: format)
        }

        /// Le répertoire et ses ancêtres, de la racine vers lui.
        func chain(to directory: UInt32) -> [UInt32] {
            var chain: [UInt32] = []
            var current: UInt32? = directory
            while let id = current {
                chain.append(id)
                current = directories[Int(id)].parent
            }
            return chain.reversed()
        }
    }

    // MARK: - Émission des requêtes

    /// Traduit une suite de fichiers en requêtes bloc, en tenant le compte du
    /// temps de calcul qui s'intercale entre elles.
    private struct Builder {

        let partition: PartitionGeometry
        let think: ThinkModel
        let readGranularity: Int
        let stampsAccess: Bool
        let flushSeconds: Double
        /// Sous XP, un acte préchargé émet ses lectures d'un lot, et la file
        /// d'`atapi` les sert par LBA (`AtapiQueue`).
        let prefetchBursts: Bool
        /// La file d'`atapi`, sous XP : sa clé courante passe d'un lot à
        /// l'autre.
        var queue = AtapiQueue()

        var requests: [BlockRequest] = []
        var consumed: Set<UInt32> = []
        var filesRead = 0
        var bytesRead = 0
        var bytesWritten = 0
        var residentFiles = 0
        var stampedFiles = 0
        var stampWrites = 0
        /// Sous XP, les écritures de `$LogFile` qui les précèdent.
        var stampLogWrites = 0
        var thinkSeconds: Double = 0
        /// Les éléments du volume — fichiers, et répertoires qui ont des
        /// clusters (`FileCatalog.itemID`) — dans l'ordre où le démarrage en
        /// lit les données pour la première fois.
        var readOrder: [UInt32] = []
        private var readItems: Set<UInt32> = []

        /// Répertoires dont l'entrée a déjà été lue : sur FAT, on ne relit pas
        /// un répertoire pour chaque fichier qu'il contient.
        private var openedDirectories: Set<UInt32> = []
        /// Temps de calcul dû au fichier précédent, à placer devant le suivant.
        private var pending: Double = 0
        private var rng: SeededGenerator
        /// Rang du fichier dans l'ordre de lecture.
        private var fileIndex = 0
        /// L'enregistrement de MFT de chaque fichier vivant (`MFTNumbering`).
        /// Dans l'ordre de création, les fichiers qu'un démarrage lit sont
        /// épars dans la MFT, et le bras y sautille.
        let mftRecords: [UInt32: Int]
        /// Celui de chaque répertoire.
        let directoryRecords: [UInt32: Int]
        /// Sous XP, les pages de 4 Ko de `$MFT` — leur rang dans le fichier —
        /// que le préchargeur a amenées en mémoire.
        private var mftPagesResident: Set<Int> = []
        /// Sous XP, les répertoires dont le préchargeur a lu tout le contenu.
        private var enumerated: Set<UInt32> = []
        /// Sous XP, la prochaine requête du premier plan attend la fin du lot
        /// du préchargeur en cours (`RequestFlow.barrier`).
        private var barrierPending = false
        /// Ce que l'on lit entre dans `Layout.ini` (`readOrder`). Sous XP, ce
        /// que le dernier acte lit hors trace n'y entre pas.
        private var layoutOpen = true
        /// Où l'on a lu chaque répertoire sur FAT : c'est là que sa date
        /// d'accès se réécrit.
        private var directoryLBA: [UInt32: Int] = [:]
        /// Secteurs de métadonnées salis par les dates d'accès, pas encore
        /// écrits, et le temps écoulé depuis le dernier vidage.
        private var dirtyStamps: [Int: Int] = [:]
        private var sinceFlush: Double = 0
        /// Les pages de la table FAT32 que VCACHE tient, avec les données qui
        /// les poussent dehors ; et celles qui ont déjà été lues une fois.
        private var tableCache: PageLRU
        private var tablePagesSeen: Set<Int> = []
        private var tablePagesRead = 0
        private var tablePagesReread = 0
        /// `SMARTDRV`, sous MS-DOS.
        private var smartDrive: SmartDrive?
        private let vcachePages: Int?

        /// Les répertoires du volume, là où l'allocateur les a posés.
        let directories: DirectoryPlacement?
        /// Sur FAT, les clusters de chaque répertoire déjà parcourus : le
        /// pilote cherche un nom en lisant le répertoire depuis son début, et
        /// garde en cache ce qu'il a lu.
        private var directoryScanned: [UInt32: UInt32] = [:]
        /// Sur NTFS, les tampons d'index déjà lus : on descend l'arbre des
        /// noms jusqu'à la feuille qui porte le nom cherché, sans lire les
        /// autres.
        private var indexBuffersRead: Set<UInt64> = []
        /// Sur FAT, le secteur de répertoire qui porte l'entrée de chaque
        /// fichier ouvert : c'est là que sa date d'accès se réécrit.
        private var entrySector: [UInt32: Int] = [:]

        init(partition: PartitionGeometry, os: String = "", think: ThinkModel, readGranularity: Int,
             stampsAccess: Bool, flushSeconds: Double, directories: DirectoryPlacement? = nil,
             mftRecords: [UInt32: Int] = [:], directoryRecords: [UInt32: Int] = [:],
             seed: UInt64) {
            self.partition = partition
            self.mftRecords = mftRecords
            self.directoryRecords = directoryRecords
            // Le cache du système : ce qu'il tient de la table FAT32 cède sous
            // les données sur Windows 9x ; NT garde tout un démarrage.
            vcachePages = VCache.pages(os: os)
            tableCache = PageLRU(capacity: vcachePages ?? .max)
            // `SMARTDRV` est chargé par `AUTOEXEC.BAT`, à la fin de l'acte des
            // pilotes ; Windows démarre à l'acte suivant l'invite de commandes.
            smartDrive = os == "msdos-6.22+win31" ? SmartDrive(loadedFromAct: 4, windowsFromAct: 5) : nil
            self.directories = directories
            self.think = think
            self.readGranularity = readGranularity
            self.stampsAccess = stampsAccess
            self.flushSeconds = flushSeconds
            self.prefetchBursts = os == "winxp-sp1"
            self.rng = SeededGenerator(seed: seed)
        }

        /// L'enregistrement de MFT d'un fichier. Un fichier que le volume ne
        /// connaît pas — un test qui en fabrique — garde son rang de lecture.
        private func mftRecord(of record: FileRecord, readingRank: Int) -> Int {
            mftRecords[record.id] ?? 16 + readingRank
        }

        /// Ce que lit le système avant de savoir lire un fichier.
        mutating func emitMount(phase: Int) {
            for access in partition.mountAccesses {
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
            // Monter un volume, c'est aussi décider qu'il est en service : sur
            // FAT l'octet d'état de la table est réécrit, sur NTFS la zone de
            // redémarrage du journal.
            let mark = partition.mountWrite
            append(lba: mark.lba, sectors: mark.sectors, isWrite: true, phase: phase)
            bytesWritten += mark.sectors * DriveGeometry.bytesPerSector
            pending += think.perFile * 4
        }

        /// - Parameter imageFaults: sous XP, un acte hors préchargement lit
        ///   ses images par fautes de page (`imageFaultSectors`).
        mutating func emit(files: [FileRecord], query: BootQuery, phase: Int,
                           inLayout: Bool = true, imageFaults: Bool = false) {
            layoutOpen = inLayout
            defer { layoutOpen = true }
            // Un acte préchargé lit ses métadonnées d'un bloc — le modèle de
            // Vista et 7 (`BootOrder.byPosition`), sans source ; XP a son
            // préchargeur à la lettre (`emitWithXPPrefetcher`).
            //
            // Le préchargeur ne retient pas que la liste des fichiers : il
            // retient aussi les enregistrements de MFT qui les décrivent, et
            // les lit d'une traite avant d'aller chercher la moindre donnée.
            // Sans cela, chaque ouverture ferait un aller-retour entre la MFT,
            // en tête du volume, et un fichier posé trois cents gigaoctets plus
            // loin — deux courses complètes du bras par fichier, et un
            // démarrage qui ne ressemble à rien de ce qu'on a entendu.
            //
            // Les enregistrements sont lus dans l'ordre de la MFT, ceux qui se
            // suivent d'une seule requête : les fichiers d'un démarrage n'ont
            // pas été créés à la suite.
            let bulk = query.order == .byPosition && !partition.format.isFAT
            if bulk, !files.isEmpty {
                var index = fileIndex
                var numbers: [Int] = []
                numbers.reserveCapacity(files.count)
                for record in files {
                    numbers.append(mftRecord(of: record, readingRank: index))
                    index += 1
                }
                numbers.sort()
                var first = numbers[0]
                var last = first
                func readRun() {
                    // Une suite d'enregistrements n'est contiguë sur le
                    // plateau que dans un même extent de la MFT : la lecture
                    // se coupe là où elle se coupe.
                    var from = first
                    while from <= last {
                        let start = partition.mftRecordLBA(from)
                        var to = from
                        while to < last,
                              partition.mftRecordLBA(to + 1) == start + (to + 1 - from) * partition.mftRecordSectors {
                            to += 1
                        }
                        let sectors = (to - from + 1) * partition.mftRecordSectors
                        append(lba: start, sectors: sectors, isWrite: false, phase: phase)
                        bytesRead += sectors * DriveGeometry.bytesPerSector
                        from = to + 1
                    }
                }
                for number in numbers.dropFirst() where number != last {
                    if number == last + 1 {
                        last = number
                    } else {
                        readRun()
                        first = number
                        last = number
                    }
                }
                readRun()
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
                    if layoutOpen, readItems.insert(record.id).inserted { readOrder.append(record.id) }
                    emitData(record.extents, limit: touched, isWrite: false, phase: phase,
                             requestSectors: imageFaults && Self.isImage(record)
                                 ? BootPlanner.imageFaultSectors : maxRequestSectors)
                    bytesRead += touched
                    if rng.unitInterval() < query.writeBack {
                        writeBack(record, touched: touched, phase: phase)
                        bytesWritten += touched
                    }
                }

                if stampsAccess { stamp(record) }

                filesRead += 1
                fileIndex += 1
                let cost = think.seconds(bytes: touched)
                pending += cost
                thinkSeconds += cost
                sinceFlush += cost
                if sinceFlush >= flushSeconds { flushStamps(phase: phase) }
            }
        }

        /// Les requêtes d'un lot, dans l'ordre où la file d'`atapi` les sert.
        /// Le calcul en attente part avec la première.
        private mutating func issueBurst(_ accesses: [MetadataAccess], isWrite: Bool, phase: Int) {
            for access in queue.serve(burst: accesses, key: \.lba) {
                issue(lba: access.lba, sectors: access.sectors, isWrite: isWrite, phase: phase)
            }
        }

        /// Les extents d'un fichier en requêtes, sans les émettre : le même
        /// découpage que `emitData`, à partir de l'octet `skipping`.
        private func pieces(_ extents: [Extent], skipping: Int = 0, limit: Int,
                            packet: Int = maxRequestSectors) -> [MetadataAccess] {
            var result: [MetadataAccess] = []
            var remaining = PartitionGeometry.readSectors(forBytes: limit, granularity: readGranularity)
            var skip = skipping / DriveGeometry.bytesPerSector
            for extent in extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = min(skip, length)
                skip -= offset
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, packet, remaining)
                    result.append(MetadataAccess(lba: partition.lba(ofCluster: Int(extent.start)) + offset,
                                                 sectors: sectors))
                    offset += sectors
                    remaining -= sectors
                }
                if remaining == 0 { break }
            }
            return result
        }

        /// La date de dernier accès du fichier qu'on vient de lire : son
        /// enregistrement de MFT sur NTFS, son entrée de répertoire sur FAT.
        /// Rien n'est écrit tout de suite.
        private mutating func stamp(_ record: FileRecord) {
            let access: MetadataAccess
            if partition.format.isFAT {
                guard let lba = entrySector[record.id] ?? directoryLBA[record.directory] else { return }
                access = MetadataAccess(lba: lba, sectors: 1)
            } else {
                // `$MFT` passe par le gestionnaire de cache comme un fichier :
                // la date salit la **page** de 4 Ko qui porte l'enregistrement,
                // et c'est la page que le vidage réécrit. Quatre fichiers créés
                // à la suite partagent une page.
                let pageSectors = 4_096 / DriveGeometry.bytesPerSector
                let lba = partition.mftRecordLBA(mftRecord(of: record, readingRank: fileIndex))
                access = MetadataAccess(lba: lba / pageSectors * pageSectors,
                                        sectors: pageSectors)
            }
            if prefetchBursts, !partition.format.isFAT {
                stampXP(record, mftPage: access.lba)
            } else {
                dirtyStamps[access.lba] = max(dirtyStamps[access.lba] ?? 0, access.sectors)
            }
            stampedFiles += 1
        }

        /// Une date d'accès sous XP, à la fermeture du handle
        /// (`ntfs/cleanup.c:2282-2348`) : trois choses salies, et non une.
        ///
        /// - la page de MFT du fichier : `NtfsUpdateStandardInformation`
        ///   change la valeur résidente par `NtfsChangeAttributeValue`, qui
        ///   **journalise** un `UpdateResidentValue` (`attrsup.c:3398-3405`) ;
        /// - l'entrée `$FILE_NAME` du fichier dans l'index de son répertoire :
        ///   la date d'accès fait partie de l'information dupliquée
        ///   (`FCB_INFO_DUPLICATE_FLAGS`, `ntfsstru.h:2587-2594`), que
        ///   `NtfsUpdateDuplicateInfo` recopie dans l'index du parent
        ///   (`NtfsUpdateFileNameInIndex`, `attrsup.c:8172-8400`,
        ///   `indexsup.c:611-830`), journalisé lui aussi (`UpdateFileNameRoot`
        ///   ou `…Allocation`) — le tampon d'index qui porte l'entrée, ou
        ///   l'enregistrement du répertoire si son index y tient ;
        /// - le journal, que le *lazy writer* fait poser avant ces pages.
        ///
        /// Les fichiers système de NTFS en sont exclus (`FCB_STATE_SYSTEM_FILE`,
        /// `cleanup.c:2331-2340`) : aucun n'est dans le catalogue. Un fichier
        /// qui a aussi un nom court a deux entrées ; le modèle n'en connaît
        /// qu'une.
        private mutating func stampXP(_ record: FileRecord, mftPage: Int) {
            lazy.dirty(.mft, rank: mftPage, lba: mftPage, at: thinkSeconds)
            stampRecords += 2
            guard let placement = directories else { return }
            let directory = placement.directories[Int(record.directory)]
            let page = LazyWriter.pageSectors
            if directory.entry.clusterCount > 0 {
                let offset = placement.fileOffsets[record.id] ?? 0
                let cluster = min(placement.format.clusterIndex(ofEntryAt: offset),
                                  directory.entry.clusterCount - 1)
                guard let access = partition.directoryAccesses(directory.extents,
                                                               clusters: cluster..<(cluster + 1)).first
                else { return }
                let lba = access.lba + Int(offset % UInt64(partition.clusterBytes))
                    / DriveGeometry.bytesPerSector / page * page
                lazy.dirty(.index(record.directory), rank: lba, lba: lba, at: thinkSeconds)
            } else if let number = directoryRecords[record.directory] {
                let lba = partition.mftRecordLBA(number) / page * page
                lazy.dirty(.mft, rank: lba, lba: lba, at: thinkSeconds)
            }
        }

        /// Enregistrements de journal écrits par les dates d'accès — deux par
        /// date —, et ce qui en est déjà posé : seize par page de 4 Ko, huit
        /// validations de deux enregistrements, l'ordre de grandeur du modèle
        /// (`PartitionGeometry.validationsPerLogPage`).
        private var stampRecords = 0
        private var loggedStampRecords = 0

        /// Les pages de journal que les dates ont remplies depuis le dernier
        /// vidage, d'un trait tant qu'elles se suivent.
        private mutating func pendingStampLog() -> [LazyWriter.Write] {
            guard stampRecords > loggedStampRecords else { return [] }
            let perPage = 2 * PartitionGeometry.validationsPerLogPage
            // La page entamée au vidage précédent est réécrite.
            let first = loggedStampRecords / perPage
            let last = (stampRecords - 1) / perPage
            loggedStampRecords = stampRecords
            var writes: [LazyWriter.Write] = []
            for index in first...last {
                let access = partition.logPage(index)
                if let previous = writes.last, previous.lba + previous.sectors == access.lba {
                    writes[writes.count - 1] = LazyWriter.Write(lba: previous.lba,
                                                                sectors: previous.sectors + access.sectors,
                                                                stream: .other(0))
                } else {
                    writes.append(LazyWriter.Write(lba: access.lba, sectors: access.sectors,
                                                   stream: .other(0)))
                }
            }
            return writes
        }

        /// Sous XP, le *lazy writer* (`LazyWriter`) : son horloge est le
        /// temps de calcul, qui minore le temps réel.
        private var lazy = LazyWriter()
        /// Le temps de calcul à la dernière requête du premier plan.
        private var thinkAtForeground = 0.0

        /// Sous XP, les passages du *lazy writer* échus — en fin de démarrage,
        /// jusqu'à la fin du silence final : ils partent en arrière-plan, sans
        /// retenir le fil. Ce qui reste sale est écrit après la fenêtre.
        private mutating func runLazyWriter(phase: Int, until extra: Double) {
            for scan in lazy.due(at: thinkSeconds + extra) {
                // Le passage tombe tant de secondes de calcul après la
                // dernière requête du premier plan.
                let delay = max(min(scan.time, thinkSeconds) - thinkAtForeground, 0)
                let metadata = scan.streams.contains { $0.first?.stream.isMetadata ?? false }
                let log = metadata ? pendingStampLog() : []
                for write in LazyWriter.served(scan.streams, log: log, queue: &queue) {
                    issue(lba: write.lba, sectors: write.sectors, isWrite: true, phase: phase,
                          flow: .background, delay: delay)
                    // Les données sont comptées quand l'acte les réécrit.
                    if write.stream.isMetadata {
                        bytesWritten += write.sectors * DriveGeometry.bytesPerSector
                        if case .other = write.stream { stampLogWrites += 1 } else { stampWrites += 1 }
                    }
                }
            }
        }

        /// Le cache vide ce que les dates d'accès ont sali : dans l'ordre du
        /// disque, en fusionnant ce qui se touche.
        ///
        /// L'horloge est le temps de calcul, qui minore le temps réel — le
        /// disque attend aussi — : les vidages sont un peu plus espacés qu'ils
        /// ne l'étaient. Ce chemin-là est celui de VFAT, sans journal ; sous
        /// XP, une date salit aussi l'index du répertoire et elle est
        /// journalisée (`stampXP`) — l'hypothèse d'avant, « NTFS ne journalise
        /// pas une simple date », est contredite par `attrsup.c:3398-3405`.
        ///
        /// - Parameter until: sous XP, en fin de démarrage, les passages du
        ///   lazy writer jusqu'à la fin du silence final ; ailleurs, tout.
        mutating func flushStamps(phase: Int, until: Double? = nil) {
            sinceFlush = 0
            if prefetchBursts, !partition.format.isFAT {
                runLazyWriter(phase: phase, until: until ?? 0)
                return
            }
            guard !dirtyStamps.isEmpty else { return }
            var runs: [(lba: Int, sectors: Int)] = []
            for lba in dirtyStamps.keys.sorted() {
                let sectors = dirtyStamps[lba] ?? 1
                if let last = runs.last, lba <= last.lba + last.sectors {
                    runs[runs.count - 1].sectors = max(last.sectors, lba + sectors - last.lba)
                } else {
                    runs.append((lba, sectors))
                }
            }
            dirtyStamps.removeAll(keepingCapacity: true)
            for run in runs {
                append(lba: run.lba, sectors: run.sectors, isWrite: true, phase: phase)
                bytesWritten += run.sectors * DriveGeometry.bytesPerSector
                stampWrites += 1
            }
        }

        /// L'ouverture d'un fichier, avant toute donnée : le chemin, répertoire
        /// par répertoire depuis la racine, puis sur NTFS l'enregistrement du
        /// fichier.
        private mutating func open(_ record: FileRecord, phase: Int) {
            if let directories {
                readPath(to: record, in: directories, phase: phase)
            } else if partition.format.isFAT, openedDirectories.insert(record.directory).inserted,
                      let first = record.extents.first?.start {
                // Un volume qui ne sait pas où sont ses répertoires : on lit un
                // cluster près du fichier, comme le modèle le faisait avant de
                // les poser.
                let lba = partition.lba(ofCluster: Int(first))
                directoryLBA[record.directory] = lba
                append(lba: lba, sectors: partition.clusterSectors, isWrite: false, phase: phase)
                bytesRead += partition.clusterSectors * DriveGeometry.bytesPerSector
            }
            let number = mftRecord(of: record, readingRank: fileIndex)
            // Sous XP, la page de `$MFT` que le préchargeur a lue est en
            // mémoire.
            if mftPagesResident.contains(number / recordsPerMFTPage) { return }
            for access in partition.openAccesses(fileIndex: number) {
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
        }

        /// Enregistrements de MFT par page de 4 Ko.
        private var recordsPerMFTPage: Int {
            max(PartitionGeometry.logPageSectors / partition.mftRecordSectors, 1)
        }

        /// Trouver un nom, c'est lire chaque répertoire du chemin jusqu'à
        /// l'entrée de l'étape suivante.
        private mutating func readPath(to record: FileRecord, in placement: DirectoryPlacement,
                                       phase: Int) {
            let chain = placement.chain(to: record.directory)
            for (step, directory) in chain.enumerated() {
                let offset = step + 1 < chain.count
                    ? placement.directoryOffsets[Int(chain[step + 1])]
                    : placement.fileOffsets[record.id] ?? 0
                let sector = readDirectory(directory, upTo: offset, in: placement, phase: phase)
                if step + 1 == chain.count, let sector { entrySector[record.id] = sector }
            }
        }

        /// Lit ce qu'il faut d'un répertoire pour atteindre l'entrée à
        /// `offset`, et rend le secteur qui la porte.
        ///
        /// Sur FAT le répertoire est une liste : le pilote le lit depuis son
        /// début, cluster après cluster, en suivant sa chaîne — un répertoire
        /// en morceaux coûte un déplacement du bras par morceau. La racine d'un
        /// FAT16 a été lue entière au montage. Sur NTFS c'est un arbre : seul le
        /// tampon d'index qui porte le nom est lu, et un petit répertoire tient
        /// dans son enregistrement de MFT.
        private mutating func readDirectory(_ id: UInt32, upTo offset: UInt64,
                                            in placement: DirectoryPlacement, phase: Int) -> Int? {
            let directory = placement.directories[Int(id)]
            let sectorBytes = UInt64(DriveGeometry.bytesPerSector)
            guard directory.entry.clusterCount > 0 else {
                if partition.format.isFAT, directory.parent == nil, partition.rootSectorCount > 0 {
                    return partition.rootLBA + Int(offset / sectorBytes) % partition.rootSectorCount
                }
                return nil
            }
            let last = min(placement.format.clusterIndex(ofEntryAt: offset), directory.entry.clusterCount - 1)
            let range: Range<UInt32>
            if partition.format.isFAT {
                let scanned = directoryScanned[id] ?? 0
                range = scanned..<max(scanned, last + 1)
                directoryScanned[id] = max(scanned, last + 1)
            } else {
                range = indexBuffersRead.insert(UInt64(id) << 32 | UInt64(last)).inserted
                    ? last..<(last + 1) : last..<last
            }
            if !range.isEmpty, layoutOpen, readItems.insert(FileCatalog.itemID(ofDirectory: id)).inserted {
                readOrder.append(FileCatalog.itemID(ofDirectory: id))
            }
            for access in partition.directoryAccesses(directory.extents, clusters: range) {
                if partition.format.isFAT {
                    // Sur FAT32, suivre la chaîne d'un répertoire demande la
                    // table comme celle d'un fichier.
                    let first = (access.lba - partition.dataStartLBA) / partition.clusterSectors
                    followChain(from: first, through: first + access.sectors / partition.clusterSectors - 1,
                                phase: phase)
                }
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
                tableCache.fill(anonymous: pages(access.sectors))
            }
            let cluster = partition.directoryAccesses(directory.extents, clusters: last..<(last + 1)).first?.lba
            return cluster.map { $0 + Int(offset % UInt64(partition.clusterBytes) / sectorBytes) }
        }

        /// Ce qu'un acte réécrit d'un fichier qu'il a lu. Sous XP, par le
        /// cache : les pages sont salies, et le *lazy writer* les pose
        /// (`LazyWriter`) ; ailleurs, tout de suite.
        private mutating func writeBack(_ record: FileRecord, touched: Int, phase: Int) {
            guard prefetchBursts, !partition.format.isFAT else {
                emitData(record.extents, limit: touched, isWrite: true, phase: phase)
                return
            }
            var page = 0
            for access in pieces(record.extents, limit: touched) {
                var offset = 0
                while offset < access.sectors {
                    lazy.dirty(.data(record.id), rank: page, lba: access.lba + offset, at: thinkSeconds)
                    page += 1
                    offset += LazyWriter.pageSectors
                }
            }
        }

        /// Les extents d'un fichier, découpés en requêtes de taille bornée et
        /// arrêtés au bout de `limit` octets, arrondis à la granularité de
        /// lecture de l'époque et non au cluster.
        private mutating func emitData(_ extents: [Extent], limit: Int,
                                       isWrite: Bool, phase: Int,
                                       requestSectors: Int = maxRequestSectors) {
            var remaining = PartitionGeometry.readSectors(forBytes: limit, granularity: readGranularity)
            for extent in extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = 0
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, requestSectors, remaining)
                    if !isWrite {
                        let first = Int(extent.start) + offset / partition.clusterSectors
                        let last = Int(extent.start) + (offset + sectors - 1) / partition.clusterSectors
                        followChain(from: first, through: last, phase: phase)
                        tableCache.fill(anonymous: pages(sectors))
                    }
                    append(lba: partition.lba(ofCluster: Int(extent.start)) + offset,
                           sectors: sectors,
                           isWrite: isWrite,
                           phase: phase)
                    offset += sectors
                    remaining -= sectors
                }
                if remaining == 0 { break }
            }
        }

        /// Les pages de table qu'il faut avoir pour suivre la chaîne d'un
        /// fichier de `first` à `last`.
        ///
        /// Sur FAT32, la table n'est pas en mémoire (`mountAccesses`) : pour
        /// trouver le cluster suivant d'un fichier, le pilote lit la page de
        /// table qui le décrit — 4 Ko, soit 1 024 entrées —, et la garde en
        /// cache — VCACHE, qui la garde avec les données des fichiers et la
        /// cède quand elles la poussent dehors (`VCache`). Un fichier fragmenté
        /// retourne à la table à chaque saut vers une page qu'on n'a pas encore
        /// vue, **ou qu'on a vue il y a trop longtemps** : ce sont les retours
        /// périodiques d'un Windows 98 qui lit cent mégaoctets. FAT16 n'est pas
        /// concerné : sa table a été lue entière au montage.
        private mutating func followChain(from first: Int, through last: Int, phase: Int) {
            guard partition.format == .fat32, last >= first else { return }
            let pageSectors = 4_096 / DriveGeometry.bytesPerSector
            let entriesPerPage = pageSectors * DriveGeometry.bytesPerSector / partition.format.fatEntryBytes
            for page in (first / entriesPerPage)...(last / entriesPerPage)
            where !tableCache.touch(page) {
                let sector = page * pageSectors
                guard sector < partition.fatSectors else { continue }
                let sectors = min(pageSectors, partition.fatSectors - sector)
                append(lba: partition.fat1LBA + sector, sectors: sectors, isWrite: false, phase: phase)
                bytesRead += sectors * DriveGeometry.bytesPerSector
                tablePagesRead += 1
                if !tablePagesSeen.insert(page).inserted { tablePagesReread += 1 }
            }
        }

        private func pages(_ sectors: Int) -> Int {
            (sectors * DriveGeometry.bytesPerSector + VCache.pageBytes - 1) / VCache.pageBytes
        }

        /// Ce que le cache du système a fait, pour le bilan.
        ///
        /// **Français, et volontairement pas traduit** : ce rapport ne va nulle
        /// part dans l'app — seul `Tools/Shared/Report.swift` l'imprime, et
        /// `Tools/Measure/bilan.py` le relit au mot près (« dont N relues après
        /// éviction »). Le traduire casserait la mesure sans rien gagner à
        /// l'écran.
        var softwareCacheReport: String? {
            if let smartDrive {
                return "SMARTDRV : \(smartDrive.hits) éléments servis, \(smartDrive.misses) lus "
                    + "(8 Ko, 16 Ko d'avance ; 1 Mo, 512 Ko sous Windows)"
            }
            if partition.format == .fat32 {
                let size = vcachePages.map { "VCACHE de \($0 * VCache.pageBytes / 1_048_576) Mo" }
                    ?? "cache sans éviction"
                return "table FAT32 : \(tablePagesRead) pages lues, dont \(tablePagesReread) relues "
                    + "après éviction (\(size))"
            }
            return nil
        }

        private mutating func append(lba: Int, sectors: Int, isWrite: Bool, phase: Int) {
            // Sous `SMARTDRV`, une lecture ne va au disque que pour ce qu'il n'a
            // pas, par éléments, avec sa lecture anticipée. Rien du tout si
            // tout y est : le calcul en attente part avec la requête suivante.
            if !isWrite, var cache = smartDrive, cache.isActive(inAct: phase) {
                let runs = cache.read(lba: lba, sectors: sectors, act: phase)
                smartDrive = cache
                for run in runs {
                    var offset = 0
                    while offset < run.sectors {
                        let count = min(run.sectors - offset, maxRequestSectors)
                        issue(lba: run.lba + offset, sectors: count, isWrite: false, phase: phase)
                        offset += count
                    }
                }
                return
            }
            issue(lba: lba, sectors: sectors, isWrite: isWrite, phase: phase)
        }

        /// Une requête. Au premier plan, le calcul en attente part avec elle —
        /// et, si un lot du préchargeur vient d'être émis, elle en attend la
        /// fin. En arrière-plan, `think` est ce que le fil calcule pendant
        /// qu'elle se sert, et le calcul en attente reste pour la suivante.
        private mutating func issue(lba: Int, sectors: Int, isWrite: Bool, phase: Int,
                                    flow: RequestFlow = .foreground, delay: Double = 0,
                                    hostWork: Double = 0) {
            if flow == .background {
                requests.append(BlockRequest(issueTime: 0, lba: lba, sectorCount: sectors,
                                             isWrite: isWrite, phaseIndex: phase,
                                             thinkTime: delay,
                                             flow: barrierPending ? .backgroundBarrier : .background,
                                             hostWork: hostWork))
                barrierPending = false
                return
            }
            thinkAtForeground = thinkSeconds
            requests.append(BlockRequest(issueTime: 0,
                                         lba: lba,
                                         sectorCount: sectors,
                                         isWrite: isWrite,
                                         phaseIndex: phase,
                                         thinkTime: pending,
                                         flow: barrierPending ? .barrier : flow))
            barrierPending = false
            pending = 0
        }

        // MARK: - Le préchargeur de XP

        /// Les extensions d'une image — ce que le chargeur projette comme une
        /// section exécutable (`SEC_IMAGE`). Le préchargeur sépare leurs pages
        /// de celles des données.
        static let imageExtensions: Set<String> = ["exe", "dll", "sys", "drv", "ocx", "cpl",
                                                   "scr", "com", "ax", "acm", "ime", "tsp"]

        static func isImage(_ record: FileRecord) -> Bool {
            guard let dot = record.name.lastIndex(of: ".") else { return false }
            return imageExtensions.contains(record.name[record.name.index(after: dot)...].lowercased())
        }

        /// Ce qu'un acte lit de chaque fichier : la trace n'a pas d'autre
        /// mesure dans le modèle que le budget de l'acte.
        func touched(_ files: [FileRecord], _ query: BootQuery) -> [(record: FileRecord, touched: Int)] {
            files.map { ($0, $0.isResident ? 0 : min(Int($0.logicalSize), query.bytesPerFile)) }
        }

        mutating func pendThink(_ seconds: Double) { pending += seconds }

        /// La prochaine requête attendra la fin du lot émis ; le calcul qui
        /// suit — et les délais du lazy writer — comptent de là.
        mutating func awaitPrefetch() {
            barrierPending = true
            thinkAtForeground = thinkSeconds
        }

        /// Les métadonnées d'un scénario, avant ses données
        /// (`CcPfPrefetchMetadata`).
        ///
        /// D'abord les enregistrements de MFT des fichiers et de leurs
        /// répertoires : NTFS les arrondit à la page de 4 Ko, les trie, ôte
        /// les doublons et passe la liste à `MmPrefetchPages`
        /// (`ntfs/fsctrl.c:19334-19362, 19433`), qui comble d'une page factice
        /// un écart de 128 Ko au plus entre deux pages plutôt que de couper la
        /// lecture (`SEEK_THRESHOLD`, `pfsup.c:55-61, 1103`) — un seul lot, que
        /// la file sert par LBA. Puis le contenu de chaque répertoire, lu en
        /// entier et dans l'ordre, les parents avant les enfants
        /// (`CcPfPrefetchDirectoryContents`, `prefetch.c:5455-5470,
        /// 5687-5800`) : une énumération synchrone.
        mutating func prefetchMetadata(files: [FileRecord], catalog: FileCatalog, phase: Int) {
            var folders = Set<UInt32>()
            for record in files {
                var current: UInt32? = record.directory
                while let id = current, Int(id) < catalog.directories.count,
                      folders.insert(id).inserted {
                    current = catalog.directories[Int(id)].parent
                }
            }
            var pages = Set<Int>()
            var rank = fileIndex
            for record in files {
                pages.insert(mftRecord(of: record, readingRank: rank) / recordsPerMFTPage)
                rank += 1
            }
            for id in folders {
                if let number = directoryRecords[id] { pages.insert(number / recordsPerMFTPage) }
            }
            let wanted = pages.subtracting(mftPagesResident).sorted()
            var runs: [(first: Int, last: Int)] = []
            for page in wanted {
                if let last = runs.last, page - last.last <= Self.seekThresholdPages {
                    runs[runs.count - 1].last = page
                } else {
                    runs.append((page, page))
                }
            }
            mftPagesResident.formUnion(wanted)
            var lot: [MetadataAccess] = []
            for run in runs {
                lot += mftPieces(firstRecord: run.first * recordsPerMFTPage,
                                 count: (run.last - run.first + 1) * recordsPerMFTPage)
            }
            bytesRead += lot.reduce(0) { $0 + $1.sectors } * DriveGeometry.bytesPerSector
            issueBurst(lot, isWrite: false, phase: phase)

            guard let placement = directories else { return }
            let order = folders.filter { !enumerated.contains($0) }
                .map { (id: $0, path: catalog.path(ofDirectory: $0).uppercased()) }
                .sorted { ($0.path, $0.id) < ($1.path, $1.id) }
            for folder in order { enumerate(folder.id, in: placement, phase: phase) }
        }

        /// `SEEK_THRESHOLD`, en pages : 128 Ko.
        static let seekThresholdPages = 128 * 1_024 / 4_096

        /// Les secteurs d'une suite d'enregistrements de MFT, coupés là où
        /// la MFT change d'extent, puis à la taille d'une requête.
        private func mftPieces(firstRecord: Int, count: Int) -> [MetadataAccess] {
            var result: [MetadataAccess] = []
            var from = firstRecord
            let end = firstRecord + count
            while from < end {
                let start = partition.mftRecordLBA(from)
                var to = from + 1
                while to < end,
                      partition.mftRecordLBA(to) == start + (to - from) * partition.mftRecordSectors {
                    to += 1
                }
                var lba = start
                var sectors = (to - from) * partition.mftRecordSectors
                while sectors > 0 {
                    let piece = min(sectors, BootPlanner.classPacketSectors)
                    result.append(MetadataAccess(lba: lba, sectors: piece))
                    lba += piece
                    sectors -= piece
                }
                from = to
            }
            return result
        }

        /// Tout le contenu d'un répertoire, dans l'ordre de son index.
        private mutating func enumerate(_ id: UInt32, in placement: DirectoryPlacement, phase: Int) {
            enumerated.insert(id)
            let directory = placement.directories[Int(id)]
            let count = directory.entry.clusterCount
            guard count > 0 else { return }
            if readItems.insert(FileCatalog.itemID(ofDirectory: id)).inserted {
                readOrder.append(FileCatalog.itemID(ofDirectory: id))
            }
            for access in partition.directoryAccesses(directory.extents, clusters: 0..<count) {
                var offset = 0
                while offset < access.sectors {
                    let piece = min(access.sectors - offset, maxRequestSectors)
                    append(lba: access.lba + offset, sectors: piece, isWrite: false, phase: phase)
                    offset += piece
                }
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
            for cluster in 0..<count { indexBuffersRead.insert(UInt64(id) << 32 | UInt64(cluster)) }
        }

        /// Les deux lots d'une phase : les pages de données — avec la page
        /// d'en-tête de chaque image —, puis les pages d'images
        /// (`CcPfPrefetchSections`, `prefetch.c:4930-4960` ; `prefboot.c:870-929`).
        /// Chaque lot est émis d'un bloc et servi par la file d'`atapi`. Les
        /// fichiers sont pris dans l'ordre du scénario, celui du premier
        /// accès : c'est cet ordre-là que `Layout.ini` retient.
        ///
        /// La trace n'existe pas dans le modèle : ce qu'on lit d'un fichier
        /// est le budget de l'acte, depuis le début — lu d'un tenant, comme le
        /// ferait `MmPrefetchPages` de pages tracées qu'aucun écart de plus de
        /// 128 Ko ne sépare.
        ///
        /// - Returns: `false` si rien n'a été émis.
        @discardableResult
        mutating func prefetchLots(_ items: [(record: FileRecord, touched: Int)], phase: Int,
                                   flow: RequestFlow, think: Double = 0) -> Bool {
            var data: [MetadataAccess] = []
            var image: [MetadataAccess] = []
            let header = 4_096
            for (record, touched) in items where touched > 0 {
                if readItems.insert(record.id).inserted { readOrder.append(record.id) }
                bytesRead += touched
                if Self.isImage(record) {
                    data += pieces(record.extents, skipping: 0, limit: min(header, touched),
                                   packet: BootPlanner.classPacketSectors)
                    if touched > header {
                        image += pieces(record.extents, skipping: header, limit: touched - header,
                                        packet: BootPlanner.classPacketSectors)
                    }
                } else {
                    data += pieces(record.extents, skipping: 0, limit: touched,
                                   packet: BootPlanner.classPacketSectors)
                }
            }
            var carried = think
            var emitted = false
            for lot in [data, image] where !lot.isEmpty {
                for access in queue.serve(burst: lot, key: \.lba) {
                    issue(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase,
                          flow: flow, hostWork: carried)
                    carried = 0
                    emitted = true
                }
            }
            return emitted
        }

        /// Ce qu'un acte fait sur des pages déjà en mémoire : du calcul, ce
        /// qu'il réécrit, les dates d'accès.
        ///
        /// - Parameter deferred: le calcul avance le fil de l'hôte pendant le
        ///   lot suivant du préchargeur (les pilotes s'initialisent pendant
        ///   que la phase d'avant `SMSS` se lit) : il est rendu, et non mis en
        ///   attente devant la prochaine requête.
        @discardableResult
        mutating func runOnPrefetchedPages(files: [FileRecord], query: BootQuery, phase: Int,
                                           deferred: Bool) -> Double {
            var computed = 0.0
            for record in files {
                var touched = 0
                if record.isResident {
                    residentFiles += 1
                } else {
                    touched = min(Int(record.logicalSize), query.bytesPerFile)
                    if rng.unitInterval() < query.writeBack {
                        writeBack(record, touched: touched, phase: phase)
                        bytesWritten += touched
                    }
                }
                if stampsAccess { stamp(record) }
                filesRead += 1
                fileIndex += 1
                let cost = think.seconds(bytes: touched)
                thinkSeconds += cost
                sinceFlush += cost
                if deferred {
                    computed += cost
                } else {
                    pending += cost
                    flushStamps(phase: phase)
                }
            }
            return computed
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
