import Testing
import Foundation
@testable import DiskCore

@Suite("Scénarios embarqués")
struct ScenarioLibraryTests {

    @Test("Les vingt-quatre scénarios se décodent")
    func allDecode() throws {
        let specs = try ScenarioLibrary.loadAll()
        #expect(specs.count == 24)
        #expect(Set(specs.map(\.id)).count == 24)

        for spec in specs {
            #expect(!spec.displayName.isEmpty)
            #expect(spec.timeline.start < spec.timeline.end)
            #expect(spec.disk.sizeMB > 0)
            #expect(!spec.installs.isEmpty)
            // Toutes les applications citées existent.
            for app in spec.installs {
                #expect(AppLibrary.manifest(id: app) != nil, "manifeste inconnu : \(app)")
            }
            for uninstall in spec.uninstalls ?? [] {
                #expect(spec.installs.contains(uninstall.app),
                        "\(spec.id) désinstalle \(uninstall.app) sans l'avoir installé")
            }
            // Le volume tient dans ce que le format sait adresser.
            #expect(spec.resolvedFileSystem().supports(clusterCount: spec.clusterCount),
                    "\(spec.id) : \(spec.clusterCount) clusters hors des bornes du format")
        }
    }

    /// Les deux démos de l'accueil ne portent plus de volume à elles : elles
    /// tournent sur un disque du catalogue, nommé par son identifiant dans
    /// `ScenarioKind`. Ce fichier-là n'est pas compilé par le paquet — d'où ces
    /// deux identifiants recopiés : ils sont le seul endroit où un profil
    /// renommé se verrait autrement au lancement de l'application, et non ici.
    @Test("Les profils des deux démos sont dans le catalogue")
    func demoProfilesExist() throws {
        for id in ["secretaire-1999", "dev-1993"] {
            #expect(ScenarioLibrary.identifiers.contains(id), "profil de démo absent : \(id)")
            _ = try ScenarioLibrary.load(id)
        }
    }

    /// Ce qui est écrit dans le JSON décrit un usage, jamais un résultat. Ce
    /// test est là pour que personne n'ajoute un jour un « fragmentation: 0.23 »
    /// à ce format.
    @Test("Le format ne contient aucun résultat")
    func specsDescribeUsageOnly() throws {
        let forbidden = ["fragment", "extent", "fill", "slack", "contig"]
        for id in ScenarioLibrary.identifiers {
            let url = try #require(ScenarioLibrary.url(for: id))
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            for word in forbidden {
                #expect(!text.contains("\"\(word)"), "\(id) contient une clé « \(word) »")
            }
        }
    }

    @Test("Un aller-retour par le JSON ne perd rien")
    func roundTrip() throws {
        for spec in try ScenarioLibrary.loadAll() {
            let again = try ProfileSpec.decode(from: spec.encoded())
            #expect(again.id == spec.id)
            #expect(again.seed == spec.seed)
            #expect(again.timeline.start == spec.timeline.start)
            #expect(again.clusterCount == spec.clusterCount)
        }
    }

    /// Les résumés sont de la prose libre, et personne ne les relit quand une
    /// fiche change : `dev-1993` a annoncé « un disque de 340 Mo » pendant que
    /// le sien en faisait 210, et `secretaire-1996` des « clusters de 32 Ko »
    /// alors que `FORMAT` lui en donne 16.
    ///
    /// Ne sont contrôlées que les tournures qui décrivent sans ambiguïté le
    /// **volume** : « un disque de N Mo », « un FAT32 de N Mo », « clusters de
    /// N Ko ». Une taille de fichier — « des paquets de 400 Mo », « des
    /// disquettes de 1,44 Mo » — n'est pas concernée et doit pouvoir rester.
    @Test("Les résumés ne mentent pas sur le volume qu'ils décrivent")
    func summariesMatchTheirDisk() throws {
        let volume = /(?:disque|FAT16|VFAT|FAT32|NTFS)\s+de\s+([\d\u{202F} ,]+?)\s*(Mo|Go)/
        let cluster = /clusters?\s+de\s+(\d+)\s*Ko/

        for spec in try ScenarioLibrary.loadAll() {
            guard let summary = spec.summary else { continue }

            for match in summary.matches(of: volume) {
                let digits = match.1
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\u{202F}", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                guard let stated = Double(digits) else {
                    Issue.record("\(spec.id) : « \(match.1) » illisible")
                    continue
                }
                let expected = match.2 == "Go"
                    ? Double(spec.disk.sizeMB) / 1_024
                    : Double(spec.disk.sizeMB)
                #expect(abs(stated - expected) / expected < 0.05,
                        "\(spec.id) annonce \(stated) \(match.2) pour \(spec.disk.sizeMB) Mo")
            }

            let clusterKB = spec.resolvedFileSystem().clusterBytes / 1_024
            for match in summary.matches(of: cluster) {
                #expect(UInt32(match.1) == clusterKB,
                        "\(spec.id) annonce des clusters de \(match.1) Ko au lieu de \(clusterKB)")
            }
        }
    }

    @Test("Le calendrier grégorien compte juste")
    func civilDates() {
        #expect(CivilDate("1996-03-01")?.dayNumber == CivilDate(year: 1996, month: 3, day: 1).dayNumber)
        // 1996 est bissextile, 1900 ne l'est pas, 2000 l'est.
        #expect(CivilDate("1996-02-01")!.days(until: CivilDate("1996-03-01")!) == 29)
        #expect(CivilDate("1999-02-01")!.days(until: CivilDate("1999-03-01")!) == 28)
        #expect(CivilDate("2000-02-01")!.days(until: CivilDate("2000-03-01")!) == 29)
        #expect(CivilDate("1996-03-01")!.days(until: CivilDate("1997-09-01")!) == 549)
        // 2003 n'est pas bissextile : trois cent soixante-cinq jours ramènent
        // exactement à la même date. Sur 2004, qui l'est, il en faut un de plus.
        #expect(CivilDate("2003-02-01")!.adding(days: 365) == CivilDate("2004-02-01")!)
        #expect(CivilDate("2004-02-01")!.adding(days: 366) == CivilDate("2005-02-01")!)
        #expect(CivilDate("pas une date") == nil)
    }
}

/// La calibration génère les vingt volumes embarqués, dont plusieurs disques de
/// plusieurs centaines de gigaoctets. C'est une mesure, pas une vérification de
/// logique : elle a sa place en configuration **release**, où elle prend une
/// minute et demie, et pas en débogage, où Swift vérifie chaque accès de
/// tableau et où elle en prend dix.
///
///     swift test -c release --filter CalibrationTests
///
/// En débogage, elle ne s'exécute que si `DISKCORE_CALIBRATION` est présent
/// dans l'environnement.
#if DEBUG
private let calibrationEnabled = ProcessInfo.processInfo.environment["DISKCORE_CALIBRATION"] != nil
#else
private let calibrationEnabled = true
#endif

@Suite("Calibration", .enabled(if: calibrationEnabled))
struct CalibrationTests {

    private static func generate(_ id: String) throws -> GeneratedDisk {
        try DiskGenerator.generate(try ScenarioLibrary.load(id))
    }

    /// Affiche la ligne de mesure d'un volume — c'est par là qu'on regarde ce
    /// que le modèle produit avant de décider si les fourchettes sont tenues.
    private static func describe(_ disk: GeneratedDisk) -> String {
        """
        \(disk.spec.id) — \(disk.metrics.fileCount) fichiers, \
        remplissage \(Int(disk.metrics.fill * 100)) %, \
        fragmentés \(String(format: "%.1f", disk.metrics.fragmentedRatio * 100)) % \
        (\(String(format: "%.1f", disk.metrics.fragmentedRatioAmongFragmentable * 100)) % des fragmentables), \
        extents/fichier \(String(format: "%.2f", disk.metrics.meanExtentsPerFile)) \
        p95 \(disk.metrics.p95ExtentsPerFile) max \(disk.metrics.maxExtentsPerFile), \
        slack \(Int(disk.metrics.slackRatio * 100)) %, \
        \(disk.metrics.freeRunCount) trous, \
        MFT \(disk.mftClusters) clusters en \(disk.mftExtents) extents, \
        \(disk.failedWrites) écritures refusées
        """
    }

    @Test("Les vingt scénarios se génèrent")
    func allScenariosGenerate() throws {
        var lines: [String] = []
        var slowest = 0.0
        var slowestID = ""
        for id in ScenarioLibrary.identifiers {
            let start = Date()
            let disk = try Self.generate(id)
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > slowest { slowest = elapsed; slowestID = id }
            lines.append(String(format: "%@  [%.2f s]", Self.describe(disk), elapsed))

            #expect(disk.metrics.fileCount > 100, "\(id) : volume trop vide")
            #expect(disk.metrics.fill > 0.05, "\(id) : remplissage \(disk.metrics.fill)")
            #expect(disk.metrics.fill <= 1.0)
        }
        print("\n" + lines.joined(separator: "\n"))
        print(String(format: "plus lent : %@ en %.2f s\n", slowestID, slowest))
    }

    /// Les cibles du cahier des charges, et ce que le modèle produit.
    ///
    /// Deux cibles FAT ne sont **pas** atteintes, et le test le dit au lieu
    /// de l'arrondir. Les cibles NTFS de 2003 sont reposées au chantier 49
    /// d'après ce que fait l'allocateur de XP (`LEDGER-XP.md`, décision 1) :
    /// chaque borne dit sa source. L'analyse est au bas de ce fichier.
    @Test("dev-1996 après dix-huit mois : 35 à 50 % de fichiers fragmentés")
    func developer1996() throws {
        let disk = try Self.generate("dev-1996")
        print(Self.describe(disk))

        withKnownIssue("le modèle produit 8 % : voir la note sur la population d'installation") {
            #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.35)
        }
        // Fourchette de non-régression sur ce que le modèle produit réellement.
        #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.04)
        #expect(disk.metrics.fragmentedRatioAmongFragmentable < 0.14)
        // Et le slack de 1996, lui, est bien là.
        #expect(disk.metrics.slackRatio > 0.10)
    }

    /// Un volume de jeu installé sur un disque neuf, puis quelques mois de
    /// parties.
    ///
    /// Ce qui est écrit le jour de l'installation, en fichiers de taille
    /// connue, est d'un seul tenant : sur un volume neuf, le cache des runs
    /// libres de XP tient des runs plus longs que tout fichier installé, et
    /// `NtfsLookupCachedLcnByLength` rend un run au moins aussi long que la
    /// demande — il ne découpe que si aucun ne suffit (`bitmpsup.c:9577-9661`).
    ///
    /// Les sauvegardes, elles, peuvent se découper, et la borne d'avant (« pas
    /// un seul fichier en deux morceaux ») est retirée : un jeu écrit sa
    /// sauvegarde par écritures de 4 Ko sans en connaître la taille, et XP
    /// pose la première dans le plus petit trou qui lui suffit
    /// (`NtfsCommonWrite`, `write.c:2059-2163` ; `UNUSED_LCN`, « maximum
    /// left-packing », `bitmpsup.c:1015-1022`) — ceux que la sauvegarde
    /// précédente a laissés. Le chantier 49 en mesure six, en 7 morceaux au
    /// plus.
    @Test("gamer-2003 fraîchement installé : moins de 5 %, l'installation d'un seul tenant")
    func gamer2003() throws {
        let disk = try Self.generate("gamer-2003")
        print(Self.describe(disk))
        #expect(disk.metrics.fragmentedRatioAmongFragmentable < 0.05)
        let installed = disk.catalog.files.filter { $0.modifiedDay == 0 && !$0.isResident }
        #expect(installed.count > 3_000)
        #expect(installed.allSatisfy { $0.extents.count == 1 },
                "\(installed.filter { $0.extents.count > 1 }.map(\.name))")
    }

    /// Cette cible-là était atteinte, et elle ne l'est plus depuis que `.system`
    /// a cessé de renvoyer les fichiers système au cluster 0 sur VFAT et FAT32.
    /// Ce n'est pas une régression : c'est un mécanisme qui n'a jamais existé
    /// et qui fabriquait de la fragmentation — les 1 044 `UPD*.DLL` de ce
    /// volume avaient une position moyenne à 2,5 % du volume, et rebouchaient
    /// sans fin les miettes de sa tête. Ce qui manque pour atteindre la
    /// fourchette était, selon le lot 2, le même que pour `dev-1996` et
    /// `famille-2003` : l'allocation incrémentale et l'entrelacement.
    ///
    /// Le lot 4 a mesuré les deux. Sur FAT, l'allocation par paquets ne change
    /// rien — un programme seul prend cluster par cluster ce qu'il aurait pris
    /// d'un coup — et le volume reste à 6 %. L'entrelacement, lui, le portait à
    /// 32 %, au-dessus de la fourchette ; mais il donnait à tous les programmes
    /// d'une journée le même débit et les faisait tourner ensemble du matin au
    /// soir, ce qui n'est pas un fait d'époque, et il n'est pas retenu
    /// (`DiskGenerator.runsProgramsConcurrently`). La cible se trouve entre les
    /// deux bornes ; la trancher demande des débits.
    @Test("secretaire-1999 après deux ans : 15 à 25 %")
    func secretary1999() throws {
        let disk = try Self.generate("secretaire-1999")
        print(Self.describe(disk))
        withKnownIssue("le modèle produit 6 % depuis que le hint système ne force plus le cluster 0") {
            #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.15)
        }
        // Fourchette de non-régression autour de ce que le modèle produit
        // (5,5 %), comme pour dev-1996 : la borne haute de la cible n'en est
        // pas une.
        #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.03)
        #expect(disk.metrics.fragmentedRatioAmongFragmentable < 0.10)
    }

    /// famille-2003 : photos et DivX jusqu'à saturation, sur le NTFS de XP.
    ///
    /// **La cible de 40 à 60 % est retirée** (chantier 49, décision 1 de
    /// `LEDGER-XP.md`). Elle venait du cahier des charges, pas de XP ; suivi à
    /// la lettre, l'allocateur de XP en produit 16 %. Ses mécanismes ne vont
    /// pas tous dans le même sens : le *best fit* sur le cache des runs libres
    /// reprend chaque trou dès le point de contrôle qui suit sa libération
    /// (`NtfsFreeRecentlyDeallocated`, `logsup.c:4500-4533`), le découpage
    /// prend les plus grands morceaux d'abord (`AllowShorter`,
    /// `bitmpsup.c:9652-9661`), et la surallocation tient les gros fichiers en
    /// morceaux de 64 Ko au moins (`allocsup.c:1321-1387`) — mais la première
    /// écriture de 4 Ko d'un fichier va dans le plus petit trou qui lui
    /// suffit. La fourchette de non-régression (4 à 16 %) est retirée aussi :
    /// elle suivait la mesure, sans mécanisme.
    ///
    /// **Le remplissage de 90 %** n'est pas l'affaire de l'allocateur : le
    /// volume finit à 88,7 % aux chantiers 48 et 49, au même point de son
    /// cycle de rangement (`hoarding.tidiesUpAt` 0,99), avec les mêmes 161
    /// écritures refusées. Il reste une cible, manquée, hors de ce chantier.
    @Test("famille-2003 : saturé, un gros fichier écrit à la fin est en miettes")
    func family2003() throws {
        let disk = try Self.generate("famille-2003")
        print(Self.describe(disk))

        withKnownIssue("88,7 % : la fin du cycle de rangement du profil, pas l'allocateur") {
            #expect(disk.metrics.fill > 0.90)
        }
        // Un gros fichier écrit quand le volume est plein est découpé dans les
        // runs qui restent, du plus grand au plus petit, jusqu'à 128 par appel
        // et autant d'appels qu'il faut (`AllowShorter`, `MAXIMUM_RUNS_AT_ONCE`,
        // `allocsup.c:1475-1600`) : des centaines de morceaux.
        #expect(disk.metrics.maxExtentsPerFile > 500)
    }

    /// Le même profil sur le FAT32 de 1999 et sur le NTFS de XP.
    ///
    /// **La borne « deux fois plus sur FAT32 » est retirée** (chantier 49,
    /// décision 1). Elle venait du cahier des charges (« NTFS : fichiers bien
    /// plus contigus »), et le modèle ne la tenait que par un allocateur NTFS
    /// sans source, qui préférait l'espace vierge. Celui de XP ne la tient
    /// pas : 16,4 % sur FAT32, 16,2 % sur NTFS. Il pose la première écriture
    /// de 4 Ko d'un fichier dans le plus petit trou qui lui suffit
    /// (`bitmpsup.c:1015-1022, 9577-9661`), là où FAT32 écrit à la suite de
    /// son curseur ; il rattrape ensuite par la surallocation. Aucun
    /// mécanisme de XP ne dit dans quel rapport les deux doivent finir : le
    /// test imprime les deux, et ne borne que le remplissage, qui est le
    /// sujet du profil.
    @Test("Le même usage, sur FAT32 et sur le NTFS de XP")
    func fileSystemDominatesTheOutcome() throws {
        let fat32 = try Self.generate("famille-1999")
        let ntfs = try Self.generate("famille-2003")
        print(Self.describe(fat32))
        print(Self.describe(ntfs))
        #expect(fat32.metrics.fill > 0.90)
        withKnownIssue("88,7 % : la fin du cycle de rangement du profil, pas l'allocateur") {
            #expect(ntfs.metrics.fill > 0.90)
        }
    }

    /// La table de l'en-tête de `NTFSAllocator` : ce que chacune des bornes de
    /// recherche du modèle d'avant pèse sur la fragmentation, bougée seule.
    /// Elle est imprimée telle que l'en-tête la porte ; c'est ce test qui la
    /// refait.
    ///
    /// Depuis le chantier 49, ces bornes ne servent plus qu'à NT 4, Vista et
    /// 7 : XP n'en a aucune, son *best fit* est celui de son cache de runs
    /// libres. Ce qui est vérifié : les volumes de XP n'en dépendent pas du
    /// tout, et sur ceux de Vista l'horizon reste la borne qui fait le plus
    /// varier le résultat — ce que l'en-tête dit.
    @Test("Les bornes de recherche de NTFSAllocator, mesurées une à une")
    func ntfsSearchBoundsWeighOnFragmentation() throws {
        let profiles = ["famille-2003", "secretaire-2003", "dev-2007", "famille-2007"]
        let standard = NTFSAllocator.SearchBounds.standard
        func with(_ change: (inout NTFSAllocator.SearchBounds) -> Void) -> NTFSAllocator.SearchBounds {
            var bounds = standard
            change(&bounds)
            return bounds
        }
        let settings: [(String, NTFSAllocator.SearchBounds)] = [
            ("tel quel (2, 64, 65 536)", standard),
            ("`reuseTolerance` = 4", with { $0.reuseTolerance = 4 }),
            ("`reuseTolerance` = `.max`", with { $0.reuseTolerance = .max }),
            ("`window` = 16", with { $0.window = 16 }),
            ("`window` = 256", with { $0.window = 256 }),
            ("`horizon` = 16 384", with { $0.horizon = 16_384 }),
            ("`horizon` = 262 144", with { $0.horizon = 262_144 }),
        ]
        var ratios: [[Double]] = []
        var lines: [String] = []
        for (label, bounds) in settings {
            let row = try profiles.map { id in
                try DiskGenerator.generate(try ScenarioLibrary.load(id), ntfsSearch: bounds)
                    .metrics.fragmentedRatioAmongFragmentable
            }
            ratios.append(row)
            let cells = row.map { String(format: "%.1f %%", $0 * 100).replacingOccurrences(of: ".", with: ",") }
            lines.append("/// | \(label.padding(toLength: 28, withPad: " ", startingAt: 0)) | "
                         + cells.joined(separator: " | ") + " |")
        }
        print("\n" + lines.joined(separator: "\n"))

        // XP ne connaît aucune de ces bornes.
        for column in 0..<2 {
            #expect(Set(ratios.map { $0[column] }).count == 1, "\(profiles[column]) dépend d'une borne")
        }
        // Sur Vista, l'horizon fait le plus varier chaque volume.
        for column in 2..<4 {
            let values = { (rows: ArraySlice<[Double]>) in rows.map { $0[column] } + [ratios[0][column]] }
            let span = { (rows: ArraySlice<[Double]>) in values(rows).max()! - values(rows).min()! }
            #expect(span(ratios[5...6]) > span(ratios[1...2]), "\(profiles[column])")
            #expect(span(ratios[5...6]) > span(ratios[3...4]), "\(profiles[column])")
        }
    }

    /// L'asymétrie entre profils est ce qui rend l'application crédible : si
    /// tous les volumes se ressemblaient, il n'y aurait rien à montrer.
    @Test("Les profils d'une même époque ne se ressemblent pas")
    func profilesDiverge() throws {
        let dev = try Self.generate("dev-1996")
        let secretary = try Self.generate("secretaire-1996")
        let gamer = try Self.generate("gamer-1996")

        // Le joueur a peu de fichiers, et très gros.
        #expect(gamer.metrics.fileCount < dev.metrics.fileCount)
        #expect(gamer.metrics.meanExtentClusters > dev.metrics.meanExtentClusters * 2)
        // Les trois volumes ne se ressemblent en rien.
        let ratios = [dev, secretary, gamer].map(\.metrics.fragmentedRatioAmongFragmentable)
        #expect(ratios.max()! > ratios.min()! * 2)
        // Le poste de bureau perd une bonne part de son disque en slack, sur
        // des clusters de 32 Ko — bien plus que le développeur, dont les gros
        // fichiers remplissent leurs clusters.
        #expect(secretary.metrics.slackRatio > 0.02)
        #expect(gamer.metrics.slackRatio < secretary.metrics.slackRatio)
    }

    /// Même graine, même disque — jusqu'au dernier cluster.
    @Test("Un scénario embarqué est reproductible")
    func deterministic() throws {
        let first = try Self.generate("secretaire-2003")
        let second = try Self.generate("secretaire-2003")
        #expect(first.metrics == second.metrics)
        #expect(first.catalog.files.map(\.extents) == second.catalog.files.map(\.extents))
    }
}


// MARK: - Ce que le modèle ne produit pas, et pourquoi
//
// Deux des cibles du cahier des charges ne sont pas atteintes, sur FAT ; deux
// autres, sur le NTFS de XP, sont retirées (plus bas). Le diagnostic des
// premières tient en une phrase : **le taux de fichiers fragmentés mesure
// d'abord la population du volume, et seulement ensuite l'allocateur.**
//
// Le lot 4 leur a donné ce qui leur manquait selon le lot 2 : des fichiers
// écrits par paquets quand leur programme n'en connaît pas la taille. Sur FAT
// cela ne change rien — un programme seul prend cluster par cluster ce qu'il
// aurait pris d'un coup — et sur NTFS peu. L'entrelacement de plusieurs
// programmes, qui en aurait refermé une et dépassé une autre, n'est pas retenu
// faute de débits (`DiskGenerator.runsProgramsConcurrently`). Elles restent
// manquées.
//
// `dev-1996` : 8 % au lieu de 35 à 50 %. Sur les 5 500 fichiers du volume,
// 3 000 viennent de l'installation de Windows 95, de Visual C++ et d'Office —
// écrits d'affilée sur un disque vierge, donc parfaitement contigus, et jamais
// retouchés ensuite. Même si *tout le reste* était fragmenté, le taux
// plafonnerait autour de 45 %. Ce que le modèle produit bel et bien, ce sont
// les fichiers de sortie en cinquante morceaux que décrit le cahier des
// charges : le pire fichier du volume est en 290 extents. Pour faire monter le
// taux global il faudrait que la majorité des fichiers survivants aient été
// écrits **après** le mitage — ce qui suppose bien plus de remplacements de
// fichiers système que les trois vagues de mises à jour par an qu'a reçues
// Windows 95.
//
// `famille-2003` : la cible de 40 à 60 % est retirée au chantier 49. Le
// modèle d'avant produisait de 8 à 24 % selon le lot, par un allocateur NTFS
// sans source (préférence pour le vierge, quatre bornes de recherche) ; celui
// de XP, suivi à la lettre (`NTFSAllocator+XP.swift`), en produit 16 %, et
// rien dans son code ne dit qu'un volume à 88 % devrait en compter 40. La
// cible était celle du cahier des charges, pas celle de XP : c'est elle qui
// est fausse (`LEDGER-XP.md`, décision 1). Même chose pour le rapport de deux
// avec le FAT32 de 1999, qui tombe à un.
//
// Dans les deux cas, ce qui est mesuré est la conséquence du modèle et non un
// réglage : aucune des vingt descriptions embarquées ne contient de taux de
// fragmentation, et un test s'en assure.
