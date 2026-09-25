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
        /// préchargeur de démarrage, qui garde la trace des six derniers
        /// démarrages, range la liste par position sur le disque et la relit
        /// d'une seule course ; Vista a poussé la même idée avec SuperFetch.
        /// C'est la différence la plus audible entre deux époques, et elle ne
        /// tient pas au matériel.
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
                prefetch: .byPosition,
                labels: [
                    ("post", String(localized: "boot.post", defaultValue: "BIOS POST"),
                     String(localized: "boot.post.detail", defaultValue: "Memory count, disk detection — the platter spins up")),
                    ("mount", String(localized: "boot.mount", defaultValue: "Boot sector"),
                     String(localized: "boot.mount.ntfs.detail", defaultValue: "MBR, boot sector, volume metadata")),
                    ("kernel", String(localized: "boot.kernelHAL", defaultValue: "Kernel and HAL"),
                     String(localized: "boot.kernelHAL.xp.detail", defaultValue: "NTLDR, the kernel, the abstraction layer")),
                    ("drivers", String(localized: "boot.drivers", defaultValue: "Loading the drivers"),
                     String(localized: "boot.drivers.nt.detail", defaultValue: "The drivers in registry order — the characteristic crackle")),
                    ("services", String(localized: "boot.registry", defaultValue: "Registry and services"),
                     String(localized: "boot.registry.xp.detail", defaultValue: "SYSTEM and SOFTWARE hives, logs — reads and writes mixed")),
                    ("shell", String(localized: "boot.logon", defaultValue: "Logging on"),
                     String(localized: "boot.logon.xp.detail", defaultValue: "Explorer, fonts, prefetch — very scattered accesses")),
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
            // services. ReadyBoot relit la trace des démarrages précédents dans
            // l'ordre du disque, comme le préchargeur de XP.
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
    /// Ce que le cache du système a fait, en une ligne de bilan : `SMARTDRV`
    /// en 1993, VCACHE et la table FAT32 en 1999. `nil` sans cache à décrire.
    let softwareCache: String?
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

        var builder = Builder(partition: partition,
                              os: script.os,
                              think: script.think,
                              readGranularity: script.readGranularity,
                              stampsAccess: script.stampsAccess && firstOfTheDay,
                              flushSeconds: script.metadataFlushSeconds,
                              directories: DirectoryPlacement(disk: disk),
                              mftRecords: partition.format.isFAT ? [:] : MFTNumbering(disk: disk).files,
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
        builder.flushStamps(phase: script.acts.count - 1)

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
                        softwareCache: builder.softwareCacheReport,
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
             mftRecords: [UInt32: Int] = [:], seed: UInt64) {
            self.partition = partition
            self.mftRecords = mftRecords
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
            //
            // Les enregistrements sont lus dans l'ordre de la MFT, ceux qui se
            // suivent d'une seule requête : les fichiers d'un démarrage n'ont
            // pas été créés à la suite.
            let bulk = query.order == .byPosition && !partition.format.isFAT
            if bulk, prefetchBursts, !files.isEmpty {
                emitPrefetched(files: files, query: query, phase: phase)
                return
            }
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
                    if readItems.insert(record.id).inserted { readOrder.append(record.id) }
                    emitData(record.extents, limit: touched, isWrite: false, phase: phase)
                    bytesRead += touched
                    if rng.unitInterval() < query.writeBack {
                        emitData(record.extents, limit: touched, isWrite: true, phase: phase)
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

        /// Un acte préchargé, sous XP : ce que `MmPrefetchPages` fait d'un
        /// lot.
        ///
        /// Il met toutes les pages en transition, **émet toutes les lectures**
        /// en asynchrone, puis seulement les attend (`pfsup.c:318-338,
        /// 370-388`) : les requêtes du lot sont en file ensemble, et c'est
        /// `atapi` qui les sert, par LBA croissante à partir de sa clé
        /// courante (`AtapiQueue`). Le système, lui, attend la fin du lot
        /// avant de se servir de ce qu'il a lu : le calcul de l'acte vient
        /// après, fichier par fichier, avec ce qu'il écrit.
        ///
        /// Deux lots : les enregistrements de MFT d'abord, puis les données.
        /// Le reste de l'acte — l'ordre, les pages, les phases — est encore
        /// celui du modèle (`BootOrder.byPosition`).
        private mutating func emitPrefetched(files: [FileRecord], query: BootQuery, phase: Int) {
            var index = fileIndex
            var numbers: [Int] = []
            numbers.reserveCapacity(files.count)
            for record in files {
                numbers.append(mftRecord(of: record, readingRank: index))
                index += 1
            }
            numbers.sort()
            var metadata: [MetadataAccess] = []
            var first = numbers[0]
            var last = first
            func readRun() {
                var from = first
                while from <= last {
                    let start = partition.mftRecordLBA(from)
                    var to = from
                    while to < last,
                          partition.mftRecordLBA(to + 1) == start + (to + 1 - from) * partition.mftRecordSectors {
                        to += 1
                    }
                    metadata.append(MetadataAccess(lba: start, sectors: (to - from + 1) * partition.mftRecordSectors))
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
            issueBurst(metadata, isWrite: false, phase: phase)

            var data: [MetadataAccess] = []
            var touchedBytes: [Int] = []
            touchedBytes.reserveCapacity(files.count)
            for record in files {
                guard !record.isResident else { touchedBytes.append(0); continue }
                let touched = min(Int(record.logicalSize), query.bytesPerFile)
                touchedBytes.append(touched)
                if readItems.insert(record.id).inserted { readOrder.append(record.id) }
                data += pieces(record.extents, limit: touched)
                bytesRead += touched
            }
            issueBurst(data, isWrite: false, phase: phase)

            for (record, touched) in zip(files, touchedBytes) {
                if record.isResident {
                    residentFiles += 1
                } else if rng.unitInterval() < query.writeBack {
                    emitData(record.extents, limit: touched, isWrite: true, phase: phase)
                    bytesWritten += touched
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
        /// découpage que `emitData`.
        private func pieces(_ extents: [Extent], limit: Int) -> [MetadataAccess] {
            var result: [MetadataAccess] = []
            var remaining = PartitionGeometry.readSectors(forBytes: limit, granularity: readGranularity)
            for extent in extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = 0
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, maxRequestSectors, remaining)
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
            dirtyStamps[access.lba] = max(dirtyStamps[access.lba] ?? 0, access.sectors)
            stampedFiles += 1
        }

        /// Le cache vide ce que les dates d'accès ont sali : dans l'ordre du
        /// disque, en fusionnant ce qui se touche.
        ///
        /// L'horloge est le temps de calcul, qui minore le temps réel — le
        /// disque attend aussi — : les vidages sont un peu plus espacés qu'ils
        /// ne l'étaient. Aucune page de journal ne les accompagne : le modèle
        /// suppose, sans source qui le tranche, que NTFS ne journalise pas une
        /// simple date.
        mutating func flushStamps(phase: Int) {
            sinceFlush = 0
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
            for access in partition.openAccesses(fileIndex: mftRecord(of: record, readingRank: fileIndex)) {
                append(lba: access.lba, sectors: access.sectors, isWrite: false, phase: phase)
                bytesRead += access.sectors * DriveGeometry.bytesPerSector
            }
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
            if !range.isEmpty, readItems.insert(FileCatalog.itemID(ofDirectory: id)).inserted {
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

        /// Les extents d'un fichier, découpés en requêtes de taille bornée et
        /// arrêtés au bout de `limit` octets, arrondis à la granularité de
        /// lecture de l'époque et non au cluster.
        private mutating func emitData(_ extents: [Extent], limit: Int,
                                       isWrite: Bool, phase: Int) {
            var remaining = PartitionGeometry.readSectors(forBytes: limit, granularity: readGranularity)
            for extent in extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = 0
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, maxRequestSectors, remaining)
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

        private mutating func issue(lba: Int, sectors: Int, isWrite: Bool, phase: Int) {
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
