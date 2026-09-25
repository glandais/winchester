import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Démarrer un disque de la galerie.
///
/// Ce qui est vérifié ici n'est pas le *son* — aucun test ne peut le juger —
/// mais les trois propriétés dont il dépend : le démarrage lit des fichiers qui
/// existent, il les lit là où ils sont, et deux exécutions lisent les mêmes.
@Suite("Démarrage d'un disque généré")
struct BootSessionTests {

    /// Les petits volumes, générés en une fraction de seconde même en debug.
    /// Les gros profils sont couverts par le rendu hors-ligne, qui tourne en
    /// release — `swift test` doit rester une poignée de secondes.
    private static let profiles = ["secretaire-1993", "gamer-1993", "dev-1993"]

    private func disk(_ id: String) throws -> GeneratedDisk {
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == id })
        return try DiskGenerator.generate(spec)
    }

    // MARK: - Ce que le plan promet

    @Test("Un démarrage ne lit que des secteurs du volume",
          arguments: BootSessionTests.profiles)
    func withinVolume(id: String) throws {
        let disk = try disk(id)
        let plan = BootPlanner.plan(disk: disk)

        #expect(!plan.requests.isEmpty)
        for request in plan.requests {
            #expect(request.lba >= 0)
            #expect(request.lba + request.sectorCount <= plan.partition.totalSectors,
                    "une requête déborde de la partition")
            #expect(request.sectorCount > 0)
            #expect(plan.phases.indices.contains(request.phaseIndex))
        }
    }

    /// Le plancher processeur : le disque ne peut pas rendre un démarrage plus
    /// rapide que la somme des calculs qui s'intercalent entre les lectures.
    @Test("La durée d'un démarrage ne descend pas sous son temps de calcul",
          arguments: BootSessionTests.profiles)
    func thinkTimeIsAFloor(id: String) throws {
        let disk = try disk(id)
        let plan = BootPlanner.plan(disk: disk)
        let hardware = GeneratedVolumeBridge.drive(for: disk.spec,
                                                   atLeast: plan.partition.totalSectors)
        let trace = DiskSimulator.run(geometry: hardware.geometry,
                                      seekModel: hardware.seek,
                                      requests: plan.requests,
                                      totalDuration: 0,
                                      spinUpAt: 0.35,
                                      spinUpDuration: plan.post - 0.6)
        let duration = trace.timings.last?.end ?? 0

        #expect(duration > plan.thinkSeconds,
                "le disque ne peut pas rattraper le temps que la machine passe à calculer")
        // Et il n'est pas non plus le seul à compter : un démarrage entièrement
        // limité par le processeur ne dirait plus rien du disque.
        #expect(duration > plan.thinkSeconds * 1.1)
        #expect(plan.thinkSeconds > 0)
    }

    /// La condition de tout le reste : deux exécutions du même disque doivent
    /// donner exactement la même trace, sinon deux réglages audio ne sont plus
    /// comparables.
    @Test("Deux plans du même disque sont identiques")
    func deterministic() throws {
        let disk = try disk("dev-1993")
        let first = BootPlanner.plan(disk: disk)
        let second = BootPlanner.plan(disk: disk)

        #expect(first.requests.count == second.requests.count)
        #expect(first.filesRead == second.filesRead)
        #expect(first.thinkSeconds == second.thinkSeconds)
        for (a, b) in zip(first.requests, second.requests) {
            #expect(a.lba == b.lba)
            #expect(a.sectorCount == b.sectorCount)
            #expect(a.isWrite == b.isWrite)
            #expect(a.thinkTime == b.thinkTime)
        }
    }

    /// Là où ranger un volume NTFS a demandé un second défragmenteur, le
    /// démarrage passe par le même chemin que les autres : lire des fichiers ne
    /// suppose aucune stratégie de rangement.
    @Test("Un volume NTFS démarre par le même chemin que les autres")
    func ntfsBoots() throws {
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "secretaire-2003" })
        // Le disque du profil pèse 40 Go : on le réduit pour que le test tienne
        // en debug. Ce qui est vérifié, c'est le format, pas la taille.
        var small = spec
        small.disk.sizeMB = 2_000
        small.timeline.end = small.timeline.start.adding(days: 120)

        let disk = try DiskGenerator.generate(small)
        let plan = BootPlanner.plan(disk: disk)
        #expect(plan.partition.format == .ntfs)
        #expect(plan.filesRead > 0)
        #expect(!plan.requests.isEmpty)
        for request in plan.requests {
            #expect(request.lba + request.sectorCount <= plan.partition.totalSectors)
        }
    }

    /// Un fichier a son enregistrement de MFT, le même pour le démarrage et
    /// pour le défragmenteur ; et un démarrage ne lit pas des enregistrements
    /// consécutifs, puisqu'il ne lit pas les fichiers dans l'ordre où ils ont
    /// été créés.
    @Test("Un fichier a le même enregistrement de MFT quel que soit le scénario")
    func mftRecordsBelongToTheVolume() throws {
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "secretaire-2003" })
        var small = spec
        small.disk.sizeMB = 2_000
        small.timeline.end = small.timeline.start.adding(days: 120)
        let disk = try DiskGenerator.generate(small)

        let numbering = MFTNumbering(disk: disk)
        let records = Array(numbering.files.values) + Array(numbering.directories.values)
        #expect(Set(records).count == records.count)
        #expect(numbering.files.values.allSatisfy { $0 >= 16 })
        // Sous XP, le générateur donne les vrais numéros : la racine est
        // l'enregistrement 5, que le formatage a posé (chantier 49).
        #expect(numbering.directories.values.allSatisfy { $0 >= 16 || $0 == 5 })

        let volume = try GeneratedVolumeBridge.volume(from: disk)
        for (position, file) in volume.files.enumerated() where file.category != .directory {
            #expect(volume.mftRecord(of: position) == numbering.files[file.id])
        }

        // Sous XP, le préchargeur lit la MFT par pages de 4 Ko, triées et
        // sans doublon (`FSCTL_FILE_PREFETCH`, `ntfs/fsctrl.c:19334-19362`) ;
        // les ouvertures une à une ne restent qu'aux actes hors de sa trace.
        let xp = BootPlanner.plan(disk: disk)
        let partition = xp.partition
        let mftEnd = partition.mftLBA + (records.max()! + 1) * partition.mftRecordSectors
        let pages = xp.requests.filter {
            !$0.isWrite && $0.lba >= partition.mftLBA && $0.lba < mftEnd
                && $0.sectorCount != partition.mftRecordSectors
        }
        #expect(!pages.isEmpty)
        #expect(pages.allSatisfy { ($0.lba - partition.mftLBA) % 8 == 0 && $0.sectorCount % 8 == 0 })

        // Les ouvertures une à une, dans l'ordre où le démarrage les lit : le
        // modèle de Vista, où les actes hors préchargement ouvrent chaque
        // fichier.
        var vistaDisk = disk
        vistaDisk.spec.os = "vista"
        let plan = BootPlanner.plan(disk: vistaDisk)
        let opened = plan.requests
            .filter { !$0.isWrite && $0.sectorCount == partition.mftRecordSectors
                      && $0.lba >= partition.mftLBA && $0.lba < mftEnd }
            .map { ($0.lba - partition.mftLBA) / partition.mftRecordSectors }
        #expect(opened.count > 20)
        let consecutive = zip(opened, opened.dropFirst()).filter { $1 == $0 + 1 }.count
        #expect(consecutive < opened.count / 2, "\(consecutive) sur \(opened.count)")
    }

    // MARK: - Le témoin

    /// Le point de comparaison n'a de valeur que s'il ne change qu'une chose :
    /// la place. Mêmes fichiers, mêmes tailles, chacun d'un seul tenant.
    @Test("Le témoin garde le contenu et ne change que le placement")
    func freshlyInstalledKeepsContent() throws {
        let disk = try disk("dev-1993")
        let fresh = disk.freshlyInstalled()

        #expect(fresh.catalog.liveCount == disk.catalog.liveCount)

        var clusters: UInt32 = 0
        var freshClusters: UInt32 = 0
        for record in disk.catalog.files {
            let witness = try #require(fresh.catalog[record.id])
            #expect(witness.logicalSize == record.logicalSize)
            #expect(witness.category == record.category)
            #expect(witness.extents.count <= 1, "le témoin n'a pas de fichier en morceaux")
            #expect(witness.extents.clusterCount == record.extents.clusterCount)
            clusters += record.extents.clusterCount
            freshClusters += witness.extents.clusterCount
        }
        #expect(clusters == freshClusters)
        #expect(clusters > 0)
        #expect(freshClusters <= disk.clusterCount, "le témoin tient dans le volume")
    }

    /// Le témoin lit exactement les mêmes fichiers : ce n'est que leur position,
    /// et l'ordre que le préchargeur en tire, qui change.
    @Test("Le témoin lit les mêmes fichiers que le volume vieilli")
    func freshlyInstalledReadsTheSameFiles() throws {
        let disk = try disk("dev-1993")
        let aged = BootPlanner.plan(disk: disk)
        let fresh = BootPlanner.plan(disk: disk.freshlyInstalled())

        #expect(fresh.filesRead == aged.filesRead)
        #expect(fresh.osName == aged.osName)
        #expect(fresh.appName == aged.appName)
        #expect(fresh.phases.count == aged.phases.count)
        // Le même contenu tient en moins de requêtes : un fichier d'un seul
        // tenant n'impose pas de découpe supplémentaire aux bornes d'extent.
        #expect(fresh.requests.count <= aged.requests.count)
    }

    // MARK: - L'époque

    /// Windows XP a introduit le préchargeur de démarrage. Le sien relit ce
    /// que les démarrages précédents ont lu dans l'ordre du **premier accès**
    /// (`PfSvSortSectionNodesByFirstAccess`, `pfsvc.c:2631-2635`) — c'est la
    /// file d'`atapi` qui en fait un balayage ; Vista et 7 gardent le tri par
    /// position du modèle, sans source. C'est la seule différence de
    /// comportement entre deux époques qui ne tienne pas au matériel, et
    /// c'est la plus audible.
    @Test("Le préchargeur n'existe qu'à partir de Windows XP")
    func prefetchIsAnEra() {
        for era in BootScript.Era.all {
            let expected: BootOrder = switch era.os {
            case "winxp-sp1": .firstAccess
            case "vista", "win7-sp1": .byPosition
            default: .declared
            }
            #expect(era.prefetch == expected, "\(era.os)")
        }
    }

    /// Une mise sous tension à froid dure ce que dure le POST, à peu près : la
    /// journée empruntait 1,2 s en dur, quatre à six fois moins que le
    /// démarrage du même disque. `Scenario` est hors du paquet ; ce test garde
    /// la valeur que ses deux constructions prennent désormais au même endroit.
    @Test("La montée en régime à froid suit le POST, à toutes les époques")
    func coldSpinUpFollowsThePost() {
        for era in BootScript.Era.all {
            #expect(era.spinUpDuration == era.post - 0.6, "\(era.os)")
            #expect((4.4...7.4).contains(era.spinUpDuration), "\(era.os)")
        }
    }

    /// Jusqu'à XP, toute lecture réécrit la date de dernier accès du fichier ;
    /// Vista l'a désactivé par défaut. C'est l'écart d'époque qui sépare 2003
    /// de 2007 sans rien devoir au matériel, et seul ce test le retient : aucun
    /// total de durée ne le verrait disparaître, le recalage l'absorberait.
    @Test("2003 horodate ses accès, 2007 non")
    func accessTimestampsAreAnEra() throws {
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "secretaire-2003" })
        var small = spec
        small.disk.sizeMB = 2_000
        small.timeline.end = small.timeline.start.adding(days: 120)
        let disk = try DiskGenerator.generate(small)

        let xp = BootPlanner.plan(disk: disk)
        #expect(xp.osName == "Windows XP")
        #expect(xp.stampedFiles == xp.filesRead, "chaque fichier lu a sa date réécrite")
        // Différées et groupées : moins d'écritures que de fichiers. Le
        // rapport était de plus de quatre tant que les enregistrements lus se
        // suivaient (le numéro était le rang de lecture) ; dans l'ordre de
        // création, ils sont épars, et seuls ceux d'une même page de 4 Ko ou de
        // pages voisines partagent une écriture — 994 fichiers, 430 écritures,
        // puis 567 quand la MFT est partie à 3 Gio et les données devant elle
        // (lot F de `LEDGER-REALISME.md`) : le cache vide plus souvent.
        // Depuis l'allocateur de XP (chantier 49), 660 écritures, puis 656 et
        // 666 à la reprise de 49c, selon les enregistrements que prennent
        // les documents et `index.dat` : la borne des deux tiers, sans
        // source, tombait entre deux. Ce que le mécanisme dit — des dates
        // différées et groupées par page — est seulement « moins d'écritures
        // que de pages salies ».
        //
        // Jusqu'au chantier 51, une date ne salissait qu'une page — celle de
        // la MFT —, et la borne était « moins d'écritures que de fichiers »
        // (validée le 25 septembre 2026). Sous XP, une date en salit deux :
        // la page de MFT du fichier et l'entrée `$FILE_NAME` de l'index de
        // son répertoire (`ntfs/cleanup.c:2331-2348`, `attrsup.c:3398-3405`,
        // `indexsup.c:611-830`) ; 994 dates, 1 028 écritures au chantier 51f.
        // La borne suit le mécanisme : moins d'écritures que de pages salies.
        #expect(xp.stampWrites > 0)
        #expect(xp.stampWrites < 2 * xp.stampedFiles)
        // Et le journal passe avant elles : quelques pages, bien moins que
        // les tables.
        #expect(xp.stampLogWrites > 0)
        #expect(xp.stampLogWrites < xp.stampWrites)

        // Le même volume sous Vista : plus rien.
        var vistaDisk = disk
        vistaDisk.spec.os = "vista"
        let vista = BootPlanner.plan(disk: vistaDisk)
        #expect(vista.osName == "Windows Vista")
        #expect(vista.filesRead > 0)
        #expect(vista.stampedFiles == 0 && vista.stampWrites == 0)

        // Un redémarrage d'installation ne réécrit rien : ce qu'il lit vient
        // d'être écrit, la date n'a pas changé.
        let reboot = BootPlanner.plan(disk: disk, launchesApplication: false, firstOfTheDay: false)
        #expect(reboot.stampedFiles == 0)

        // Et la table dit la même chose pour les six époques : MS-DOS n'avait
        // pas de date d'accès, VFAT l'a apportée avec Windows 95, et Windows 7
        // a gardé le réglage de Vista.
        #expect(BootScript.Era.all.map(\.stampsAccess) == [false, true, true, true, false, false])
    }

    /// Une fiche peut nommer un système que la table ne connaît pas : il vaut
    /// mieux un démarrage approché qu'un refus.
    @Test("Un système inconnu retombe sur l'époque de son année")
    func unknownOSFallsBackToItsYear() throws {
        var spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "dev-1996" })
        spec.os = "os/2-warp"
        #expect(BootScript.Era.matching(spec).os == "win95-osr1")
    }

    /// Le système n'est pas une application qu'on lance : il est déjà chargé.
    @Test("L'application lancée est la première installée qui ne soit pas le système")
    func launchedApplication() throws {
        let library = try ScenarioLibrary.loadAll()
        func launched(_ id: String) throws -> String? {
            let spec = try #require(library.first { $0.id == id })
            return BootPlanner.launchedApplication(of: spec)?.id
        }
        #expect(try launched("dev-1993") == "bc31")
        #expect(try launched("secretaire-1996") == "office95")
        #expect(try launched("gamer-2003") == "ut2003")
        // Un poste qui n'a rien d'autre que son système saute simplement l'acte.
        #expect(try launched("gamer-1993") == nil)
    }
}
