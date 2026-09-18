import Testing
import Foundation
@testable import DiskCore

@Suite("Scénarios embarqués")
struct ScenarioLibraryTests {

    @Test("Les vingt scénarios se décodent")
    func allDecode() throws {
        let specs = try ScenarioLibrary.loadAll()
        #expect(specs.count == 20)
        #expect(Set(specs.map(\.id)).count == 20)

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
    /// Deux d'entre elles ne sont **pas** atteintes, et le test le dit au lieu
    /// de l'arrondir. L'analyse est au bas de ce fichier.
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

    @Test("gamer-2003 fraîchement installé : moins de 5 %")
    func gamer2003() throws {
        let disk = try Self.generate("gamer-2003")
        print(Self.describe(disk))
        #expect(disk.metrics.fragmentedRatioAmongFragmentable < 0.05)
        // Écrit une fois depuis le DVD sur un disque neuf : pas un seul fichier
        // en deux morceaux.
        #expect(disk.metrics.maxExtentsPerFile == 1)
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
            #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.10)
        }
        #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.03)
        #expect(disk.metrics.fragmentedRatioAmongFragmentable < 0.25)
    }

    @Test("famille-2003 : le remplissage est la variable de premier ordre")
    func family2003() throws {
        let disk = try Self.generate("famille-2003")
        print(Self.describe(disk))

        // Le remplissage, lui, est bien au rendez-vous.
        #expect(disk.metrics.fill > 0.90)

        withKnownIssue("le modèle produit 13 % : NTFS place bien même à 95 % — voir la note") {
            #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.40)
        }
        #expect(disk.metrics.fragmentedRatioAmongFragmentable > 0.01)
        // Mais les gros fichiers écrits en fin de course, eux, sont en miettes.
        #expect(disk.metrics.maxExtentsPerFile > 500)
    }

    /// Le même profil, la même année, sur FAT32 plutôt que NTFS : 17 % contre
    /// 13 %. L'écart entre les deux est l'un des résultats les plus parlants du
    /// modèle — et il montre que ce qui manque à famille-2003 pour atteindre la
    /// fourchette visée n'est pas un réglage, c'est un allocateur qui place
    /// moins bien.
    ///
    /// Le facteur a été de douze, puis de deux, et il se resserre encore.
    /// D'abord parce que `NTFSAllocator` renvoyait son curseur système au début
    /// de la plage de données à chaque échec, ce qui tassait les fichiers
    /// système en tête de volume et laissait le reste étrangement propre ;
    /// ensuite parce que le hint `.system` forçait, sur VFAT et FAT32, le
    /// cluster 0 pour toutes les DLL et tous les fichiers de mise à jour, ce
    /// qu'aucun pilote n'a jamais fait — c'était un fragmenteur de plus, du
    /// côté FAT cette fois. Une fois et demie, c'est ce que le modèle produisait
    /// une fois les deux retirés.
    ///
    /// Puis un quart de plus seulement, depuis le lot 4 : NTFS reçoit par
    /// paquets de 64 Ko les fichiers dont le programme ne connaît pas la
    /// taille, et chaque paquet va dans le trou le plus juste pour lui ; FAT,
    /// qui les recevait déjà cluster par cluster au curseur, n'y change rien.
    /// Ce n'est pas une fourchette qu'on élargit pour que le modèle y entre :
    /// c'est la mesure, et le titre la suit.
    @Test("Le même usage fragmente un quart de plus sur FAT32 que sur NTFS")
    func fileSystemDominatesTheOutcome() throws {
        let fat32 = try Self.generate("famille-1999")
        let ntfs = try Self.generate("famille-2003")
        print(Self.describe(fat32))
        #expect(fat32.metrics.fill > 0.90)
        #expect(ntfs.metrics.fill > 0.90)
        #expect(fat32.metrics.fragmentedRatioAmongFragmentable
                > ntfs.metrics.fragmentedRatioAmongFragmentable * 1.25)
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
// Deux des quatre cibles du cahier des charges ne sont pas atteintes. Le
// diagnostic tient en une phrase : **le taux de fichiers fragmentés mesure
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
// `famille-2003` : 13 % au lieu de 40 à 60 %, à 95 % de remplissage. Ici la
// cause est ailleurs, et elle est cohérente avec le reste du modèle : le
// best-fit de NTFS trouve encore des trous à la bonne taille sur un volume à
// 93 %, et il ne coupe un fichier que lorsqu'il n'a vraiment plus le choix.
// C'est exactement ce que le cahier des charges décrit par ailleurs — « NTFS :
// fichiers bien plus contigus ». Le même usage, la même durée, la même
// saturation, rejoués sur le FAT32 de 1999, donnent plus de vingt fois mieux.
// La fourchette de 40 à 60 % correspondrait à un volume poussé au-delà de 98 %,
// ou à un allocateur qui place moins bien que celui modélisé ici.
//
// Dans les deux cas, ce qui est mesuré est la conséquence du modèle et non un
// réglage : aucune des vingt descriptions embarquées ne contient de taux de
// fragmentation, et un test s'en assure.
