import Foundation

/// Un scénario compilé : l'arborescence de départ et l'histoire à rejouer.
public struct CompiledScenario: Sendable {
    public var spec: ProfileSpec
    public var catalog: FileCatalog
    public var timeline: EventTimeline
    /// L'installation du jour 0, étape par étape : ce que chaque logiciel a
    /// posé, extrait puis effacé. Le fichier d'échange ferme la liste.
    public var installSteps: [InstallStep] = []
}

/// Transforme une description déclarative en suite d'événements.
///
/// Aucune des intensités d'entrée ne parle de fragmentation ni de remplissage :
/// on décrit ce que fait l'utilisateur — il compile douze fois par jour, il
/// enregistre son rapport trois fois par semaine, il rippe un album le samedi —
/// et le disque en subit les conséquences. Si le volume finit à 94 % plein et
/// mité, c'est que ces gestes-là, sur cette durée-là, produisent cela.
public struct ScenarioCompiler {

    private let spec: ProfileSpec
    private let manifests: [String: AppManifest]
    private var rng: SeededGenerator
    private var catalog = FileCatalog()
    private var writer = PatternWriter()
    private var nextID: UInt32 = 0

    /// Bibliothèques partagées déjà posées : une DLL déjà présente n'est pas
    /// réinstallée, et personne ne la retire jamais.
    private var sharedLibraries: [String: UInt32] = [:]
    /// Fichiers appartenant à chaque application, pour pouvoir la désinstaller.
    private var filesByApp: [String: [UInt32]] = [:]
    /// Les étapes de l'installation, dans l'ordre où elles s'écrivent.
    private var installSteps: [InstallStep] = []
    /// Tirages de la mise en place — archives extraites, ruches du registre.
    ///
    /// Un générateur à part : ajouter ces fichiers ne doit rien changer aux
    /// tailles et aux dates de tout le reste de l'histoire, sans quoi chaque
    /// disque de la galerie serait redessiné pour une raison qui n'a rien à voir
    /// avec ses fichiers. Seules les places changent, parce que les archives
    /// ont bel et bien occupé le disque le temps de l'installation.
    private var setupRng: SeededGenerator

    /// Fichiers système qu'une mise à jour peut remplacer.
    private var replaceableSystemFiles: [(id: UInt32, bytes: ByteCount)] = []
    private var documents: [UInt32] = []
    private var previousObjects: [UInt32] = []
    private var lastBinary: UInt32?
    private var gameFiles: [[UInt32]] = []

    /// Place estimée occupée par les fichiers durables, slack compris. Le
    /// compilateur connaît le format, donc il sait ce qu'un fichier de 2 Ko
    /// coûte réellement sur des clusters de 32 Ko.
    private var committedBytes: ByteCount = 0
    /// Fichiers que l'utilisateur consentira à supprimer quand il manquera de
    /// place, du plus ancien au plus récent.
    private var disposable: [(id: UInt32, bytes: ByteCount)] = []
    private var disposableCursor = 0

    public init(spec: ProfileSpec, manifests: [AppManifest] = AppLibrary.all) {
        self.spec = spec
        self.manifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        self.rng = SeededGenerator(seed: spec.seed)
        self.setupRng = SeededGenerator(seed: spec.seed ^ 0x5E70_1A57_A11E_D000)
    }

    public static func compile(_ spec: ProfileSpec,
                               manifests: [AppManifest] = AppLibrary.all) -> CompiledScenario {
        var compiler = ScenarioCompiler(spec: spec, manifests: manifests)
        return compiler.build()
    }

    // MARK: - Construction

    private mutating func newID() -> UInt32 {
        defer { nextID += 1 }
        return nextID
    }

    /// Place réellement immobilisée par un fichier de cette taille, sur ce
    /// format-là. C'est ici que les clusters de 32 Ko de 1996 se paient.
    private func occupancy(of bytes: ByteCount) -> ByteCount {
        spec.resolvedFileSystem().allocatedBytes(forLogicalSize: bytes)
    }

    /// Enregistre un fichier durable et, si le disque commence à être plein,
    /// programme la disparition de ce que l'utilisateur garde le moins
    /// précieusement.
    ///
    /// Personne ne remplit un disque jusqu'au dernier octet : on efface de
    /// vieilles photos, on vide le dossier de téléchargements, on désinstalle
    /// un jeu auquel on ne joue plus. C'est ce geste-là qui maintient un volume
    /// réel autour de 85 à 95 % — et c'est aussi lui qui creuse les grands
    /// trous dans lesquels tombera tout ce qui s'écrira ensuite.
    private mutating func track(_ id: UInt32, bytes: ByteCount, disposable canDelete: Bool, on day: UInt32) {
        committedBytes += occupancy(of: bytes)
        if canDelete { disposable.append((id, bytes)) }
        makeRoomIfNeeded(on: day)
    }

    /// Capacité que l'utilisateur s'autorise à occuper avant de faire du
    /// ménage.
    private var tidyThreshold: Double {
        spec.activity.hoarding?.tidiesUpAt ?? 0.93
    }

    private var comfortableCapacity: ByteCount {
        ByteCount(Double(spec.disk.sizeBytes) * tidyThreshold)
    }

    private mutating func makeRoomIfNeeded(on day: UInt32) {
        guard committedBytes > comfortableCapacity else { return }
        // On n'efface que le strict nécessaire : personne ne vide un disque à
        // moitié pour faire de la place à un fichier.
        let target = ByteCount(Double(spec.disk.sizeBytes) * max(tidyThreshold - 0.09, 0.5))

        while committedBytes > target, disposableCursor < disposable.count {
            let victim = disposable[disposableCursor]
            disposableCursor += 1
            writer.timeline.append(.delete(id: victim.id), on: day)
            let freed = occupancy(of: victim.bytes)
            committedBytes = committedBytes > freed ? committedBytes - freed : 0
        }
    }

    private var epochYear: Int { spec.timeline.start.year }
    private var dayCount: UInt32 { spec.timeline.dayCount }

    private mutating func build() -> CompiledScenario {
        installSystemAndApplications()
        installSwapFile()
        runDailyActivity()
        scheduleUninstalls()
        scheduleDefragRuns()

        var timeline = writer.timeline
        timeline.sortByDay()
        timeline.giveUniqueNames()
        return CompiledScenario(spec: spec, catalog: catalog, timeline: timeline,
                                installSteps: installSteps)
    }

    // MARK: - Installation

    private mutating func installSystemAndApplications() {
        for appID in spec.installs {
            guard let manifest = manifests[appID] else { continue }
            install(manifest, on: 0)
        }
    }

    private mutating func install(_ manifest: AppManifest, on day: UInt32) {
        var installed: [UInt32] = []
        let style = SetupLibrary.style(for: manifest, year: epochYear,
                                       fileSystem: spec.fileSystem.type)
        var step = InstallStep(manifestID: manifest.id,
                               displayName: manifest.displayName,
                               kind: SetupLibrary.systemManifests.contains(manifest.id) ? .system : .application,
                               style: style)

        // L'installeur extrait d'abord ce dont il a besoin. Ces fichiers
        // occupent le disque pendant toute la copie : ce qui s'écrit ensuite
        // tombe **après** eux, et leur effacement laisse le premier trou du
        // volume.
        if let extraction = style.extraction {
            step.temporaryIDs = extract(extraction, on: day)
        }

        for group in manifest.groups {
            let directory = catalog.makeDirectory(path: group.directory)
            for index in 0..<group.fileCount {
                let id = newID()
                let bytes = SizeModel.Distribution
                    .logNormal(median: group.medianBytes, sigma: group.sigma)
                    .sample(&rng)
                let spec = FileSpec(id: id,
                                    name: "\(manifest.id.prefix(4).uppercased())\(index).\(group.extension_)",
                                    directory: directory,
                                    category: group.category,
                                    pattern: group.pattern,
                                    bytes: bytes)
                // Les fichiers d'installation sont posés une fois ; ceux dont le
                // manifeste annonce un autre motif vivront leur vie ensuite.
                writer.write(spec, from: day, to: day, touches: 0, rng: &rng)
                committedBytes += occupancy(of: bytes)
                installed.append(id)
                step.fileIDs.append(id)
                if group.pattern == .rewriteInPlace { step.settingsIDs.append(id) }
                if group.category == .systemCore || group.category == .application {
                    replaceableSystemFiles.append((id, bytes))
                }
            }
        }

        // Les bibliothèques partagées ne sont posées qu'une fois, et ne sont
        // **pas** rattachées à l'application : c'est ce qui fait qu'une
        // désinstallation les laisse derrière elle.
        let systemDirectory = catalog.makeDirectory(path: systemLibraryPath)
        for name in manifest.sharedLibraries where sharedLibraries[name] == nil {
            let id = newID()
            sharedLibraries[name] = id
            let bytes = SizeModel.library.sample(&rng)
            writer.write(FileSpec(id: id, name: name, directory: systemDirectory,
                                  category: .systemCore, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            committedBytes += occupancy(of: bytes)
            step.fileIDs.append(id)
        }

        // Le registre naît avec le système. Réécrit en place à chaque
        // installation, il ne change jamais de clusters : il ne coûte qu'au
        // bras, et c'est pour le bras qu'il est là.
        for hive in style.registry {
            let id = newID()
            let bytes = ByteCount(Double(hive.bytes) * setupRng.uniform(0.85...1.15))
            writer.write(FileSpec(id: id, name: hive.name,
                                  directory: catalog.makeDirectory(path: hive.directory),
                                  category: .systemCore, pattern: .rewriteInPlace, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &setupRng)
            committedBytes += occupancy(of: bytes)
            step.fileIDs.append(id)
            step.settingsIDs.append(id)
        }

        // Le ménage de fin d'installation.
        for id in step.temporaryIDs {
            writer.timeline.append(.delete(id: id), on: day)
        }

        filesByApp[manifest.id, default: []].append(contentsOf: installed)
        installSteps.append(step)
    }

    /// Les archives d'un installeur, tirées sur le générateur de la mise en
    /// place : un gros CAB et une poignée de petits fichiers de script, ramenés
    /// au total annoncé.
    private mutating func extract(_ extraction: SetupStyle.Extraction, on day: UInt32) -> [UInt32] {
        let count = max(extraction.fileCount, 1)
        let median = max(extraction.bytes / ByteCount(count), 1)
        var sizes: [ByteCount] = (0..<count).map { _ in
            SizeModel.Distribution.logNormal(median: median, sigma: 1.1).sample(&setupRng)
        }
        let drawn = sizes.reduce(0, +)
        if drawn > 0 {
            let scale = Double(extraction.bytes) / Double(drawn)
            sizes = sizes.map { max(ByteCount(Double($0) * scale), 512) }
        }

        let directory = catalog.makeDirectory(path: extraction.directory)
        var ids: [UInt32] = []
        for (index, bytes) in sizes.enumerated() {
            let id = newID()
            writer.write(FileSpec(id: id, name: "\(extraction.stem)\(index).\(extraction.extension_)",
                                  directory: directory, category: .temporary, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &setupRng)
            ids.append(id)
        }
        return ids
    }

    private var systemLibraryPath: String {
        switch spec.fileSystem.type {
        case .fat16, .vfat, .fat32: return "\\WINDOWS\\SYSTEM"
        case .ntfs:                 return "\\Windows\\System32"
        }
    }

    private mutating func scheduleUninstalls() {
        for uninstall in spec.uninstalls ?? [] {
            let day = UInt32(max(0, spec.timeline.start.days(until: uninstall.date)))
            for id in filesByApp[uninstall.app] ?? [] {
                writer.timeline.append(.delete(id: id), on: day)
            }
        }
    }

    private mutating func scheduleDefragRuns() {
        for date in spec.defragRuns ?? [] {
            let day = UInt32(max(0, spec.timeline.start.days(until: date)))
            writer.timeline.append(.defragment, on: min(day, dayCount))
        }
    }

    // MARK: - Fichier d'échange

    /// Chaque époque a le sien, et chacun se comporte différemment — c'est l'un
    /// des rares fichiers dont le motif d'écriture est une signature d'époque à
    /// lui tout seul.
    private mutating func installSwapFile() {
        let size = spec.disk.sizeBytes
        // Seuls les fichiers d'échange posés le jour de l'installation en font
        // partie : `WIN386.SWP` naît au premier vrai démarrage, le lendemain.
        var dayZero: [UInt32] = []
        defer {
            installSteps.append(InstallStep(manifestID: "swap",
                                            displayName: "Fichier d'échange",
                                            kind: .swap,
                                            style: SetupStyle(medium: .cdrom, speed: 0, extraction: nil,
                                                              registry: [], reboots: 0),
                                            fileIDs: dayZero))
        }
        switch spec.fileSystem.type {
        case .fat16 where epochYear <= 1994:
            // `386SPART.PAR` : permanent, contigu, jamais retouché.
            dayZero.append(nextID)
            writer.write(FileSpec(id: newID(), name: "386SPART.PAR",
                                  directory: catalog.rootDirectory,
                                  category: .swap, bytes: min(size / 12, 16 * 1_024 * 1_024)),
                         from: 0, to: 0, touches: 0, rng: &rng)

        case .fat16, .vfat, .fat32:
            // `WIN386.SWP` : créé au premier démarrage, gonfle et se dégonfle
            // sans arrêt. C'est lui qui déplace tout le reste autour de lui.
            let base = min(size / 16, 40 * 1_024 * 1_024)
            writer.write(FileSpec(id: newID(), name: "WIN386.SWP",
                                  directory: catalog.rootDirectory,
                                  category: .swap,
                                  pattern: .growShrinkDynamic(minBytes: base / 2, maxBytes: base * 2),
                                  bytes: base, hint: .normal),
                         from: 1, to: dayCount, touches: Int(dayCount / 20), rng: &rng)

        case .ntfs:
            // `pagefile.sys` à taille fixe, et sur Vista `hiberfil.sys` : deux
            // gros blocs qui ne bougent jamais et autour desquels tout se range.
            dayZero.append(nextID)
            writer.write(FileSpec(id: newID(), name: "pagefile.sys",
                                  directory: catalog.rootDirectory,
                                  category: .swap, bytes: min(size / 40, 1_536 * 1_024 * 1_024)),
                         from: 0, to: 0, touches: 0, rng: &rng)
            if epochYear >= 2007 {
                dayZero.append(nextID)
                writer.write(FileSpec(id: newID(), name: "hiberfil.sys",
                                      directory: catalog.rootDirectory,
                                      category: .swap,
                                      bytes: min(size / 60, 2_048 * 1_024 * 1_024)),
                             from: 0, to: 0, touches: 0, rng: &rng)
            }
        }
    }

    // MARK: - Activité quotidienne

    private mutating func runDailyActivity() {
        let activity = spec.activity
        for day in 1...max(dayCount, 1) {
            if let build = activity.build { compile(build, on: day) }
            if let browse = activity.browse { browseWeb(browse, on: day) }
            if let office = activity.office { officeWork(office, on: day) }
            if let media = activity.media { importMedia(media, on: day) }
            if let download = activity.download { downloadFiles(download, on: day) }
            if let gaming = activity.gaming { play(gaming, on: day) }
            if let hoarding = activity.hoarding { hoard(hoarding, on: day) }
            if let maintenance = activity.maintenance { update(maintenance, on: day) }
        }
    }

    /// Tire un nombre d'occurrences à partir d'une fréquence : la partie
    /// entière, plus la partie fractionnaire jouée à pile ou face. Sur la durée,
    /// la moyenne est exacte, et aucune journée ne ressemble à la précédente.
    private mutating func occurrences(_ rate: Double) -> Int {
        let whole = Int(rate)
        return whole + (rng.unitInterval() < rate - Double(whole) ? 1 : 0)
    }

    // MARK: Développeur

    /// Le cycle de compilation, dans l'ordre où il se produit réellement : les
    /// objets du cycle précédent disparaissent **pendant** que le compilateur
    /// écrit les nouveaux, et le fichier précompilé est refait au milieu, quand
    /// le volume est au plus mité. Grouper les suppressions à la fin rouvrirait
    /// un grand espace contigu et ne fragmenterait rien.
    private mutating func compile(_ build: ActivitySpec.Build, on day: UInt32) {
        let objects = catalog.makeDirectory(path: objectPath)
        let sources = catalog.makeDirectory(path: sourcePath)

        for pass in 0..<occurrences(build.perDay) {
            // Une compilation ordinaire est **incrémentale** : elle ne refait
            // que les quelques modules touchés depuis la précédente. La
            // reconstruction complète, qui refait tout et le fichier précompilé
            // avec, arrive une fois par jour au plus — c'est la pause café.
            let fullRebuild = pass == 0 && rng.chance(0.4)
            let recompiled = fullRebuild
                ? build.objectFiles
                : max(1, Int(Double(build.objectFiles) * rng.uniform(0.02...0.08)))

            // Un répertoire de compilation n'est pas vidé à la fin de la
            // journée : il contient en permanence les objets du dernier build.
            // Seuls ceux que la compilation en cours recompile sont détruits,
            // et remplacés aussitôt. C'est ce qui fait qu'un développeur laisse
            // derrière lui quelques centaines de fichiers écrits dans le
            // gruyère qu'il vient lui-même de creuser — et qu'ils sont en
            // cinquante morceaux.
            var produced: [UInt32] = []
            let replaced = Array(previousObjects.prefix(recompiled))
            let kept = Array(previousObjects.dropFirst(recompiled))
            let half = replaced.count / 2

            for id in replaced.prefix(half) {
                writer.timeline.append(.delete(id: id), on: day)
            }

            for index in 0..<(recompiled / 2) {
                produced.append(emitObject(index: index, directory: objects, on: day))
            }

            for id in replaced.dropFirst(half) {
                writer.timeline.append(.delete(id: id), on: day)
            }

            // Le fichier précompilé n'est refait que lorsqu'un en-tête commun
            // a changé, donc à la reconstruction complète — mais il pèse alors
            // ses vingt à quarante mégaoctets, à replacer dans un volume que la
            // compilation vient de mitter.
            if build.pchMB > 0, fullRebuild {
                let id = newID()
                writer.write(FileSpec(id: id, name: "VC.PCH", directory: objects,
                                      category: .buildArtifact,
                                      pattern: .createDeleteShortLived(lifetimeDays: 1),
                                      bytes: build.pchMB * 1_024 * 1_024),
                             from: day, to: day + 1, touches: 0, rng: &rng)
            }

            for index in (recompiled / 2)..<recompiled {
                produced.append(emitObject(index: index, directory: objects, on: day))
            }

            // L'éditeur de liens écrit sa sortie dans ce qui reste. Il tourne
            // à chaque passe, incrémentale ou non, et remplace l'exécutable
            // précédent — qui laisse donc un trou de sa taille.
            let binary = newID()
            writer.write(FileSpec(id: binary, name: "PROJET.EXE", directory: objects,
                                  category: .buildArtifact,
                                  bytes: ByteCount(rng.logNormal(median: 1_400_000, sigma: 0.6))),
                         from: day, to: day, touches: 0, rng: &rng)
            if let previous = lastBinary {
                writer.timeline.append(.delete(id: previous), on: day)
            }
            lastBinary = binary

            // Les objets recompilés passent en tête : ce sont les prochains à
            // être retouchés, comme le seraient les modules sur lesquels on
            // travaille en ce moment.
            previousObjects = produced + kept
        }

        // Quelques sources modifiées : supprimées puis réécrites, dans les trous
        // que la compilation vient d'ouvrir.
        for _ in 0..<occurrences(build.perDay / 2) {
            let id = newID()
            let bytes = SizeModel.sourceFile.sample(&rng)
            writer.write(FileSpec(id: id, name: "MODULE.C", directory: sources,
                                  category: .source, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            track(id, bytes: bytes, disposable: false, on: day)
        }

        // Ce qu'un développeur archive et ne jette jamais : une version livrée,
        // une sauvegarde du projet, un CD-ROM de documentation recopié. C'est
        // ce qui remplit son disque bien plus sûrement que ses fichiers objets.
        if rng.chance(build.perDay / 40) {
            let id = newID()
            let bytes = ByteCount(rng.logNormal(median: 9_000_000, sigma: 1.1))
            writer.write(FileSpec(id: id, name: "BUILD.ZIP",
                                  directory: catalog.makeDirectory(path: archivePath),
                                  category: .archive, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            track(id, bytes: bytes, disposable: true, on: day)
        }
    }

    private mutating func emitObject(index: Int, directory: UInt32, on day: UInt32) -> UInt32 {
        let id = newID()
        writer.write(FileSpec(id: id, name: "M\(index).OBJ", directory: directory,
                              category: .buildArtifact,
                              bytes: SizeModel.objectFile.sample(&rng)),
                     from: day, to: day, touches: 0, rng: &rng)
        return id
    }

    private var archivePath: String {
        epochYear <= 1996 ? "\\ARCHIVES" : "\\Archives"
    }

    private var sourcePath: String {
        epochYear <= 1996 ? "\\PROJETS\\SRC" : "\\Projets\\src"
    }
    private var objectPath: String {
        epochYear <= 1996 ? "\\PROJETS\\DEBUG" : "\\Projets\\Debug"
    }

    // MARK: Navigation

    /// Le cache d'un navigateur : des milliers de fichiers minuscules à durée de
    /// vie courte, plus `index.dat` qui ne fait que grossir et n'est jamais
    /// réécrit. Le premier creuse les trous, le second les remplit par bouts.
    private mutating func browseWeb(_ browse: ActivitySpec.Browse, on day: UInt32) {
        let cache = catalog.makeDirectory(path: cachePath)

        for _ in 0..<occurrences(browse.perDay) {
            for index in 0..<browse.pagesPerSession {
                writer.write(FileSpec(id: newID(), name: "C\(index).TMP", directory: cache,
                                      category: .cache,
                                      pattern: .createDeleteShortLived(
                                          lifetimeDays: 1 + rng.cluster(below: 30)),
                                      bytes: SizeModel.browserCache.sample(&rng)),
                             from: day, to: min(day + 40, dayCount), touches: 0, rng: &rng)
            }
        }

        // `index.dat` est créé au premier jour de navigation, puis grossit
        // indéfiniment. Un seul fichier, mais l'un des plus fragmentés du
        // volume.
        if day == 1 {
            writer.write(FileSpec(id: newID(), name: "index.dat", directory: cache,
                                  category: .cache,
                                  pattern: .append(growthPerEvent: 24_000),
                                  bytes: 32_000),
                         from: 1, to: dayCount, touches: Int(dayCount / 3), rng: &rng)
        }
    }

    private var cachePath: String {
        switch epochYear {
        case ...1996: return "\\WINDOWS\\TEMPOR~1"
        case ...2003: return "\\WINDOWS\\Temporary Internet Files"
        default:      return "\\Users\\moi\\AppData\\Local\\Microsoft\\Windows\\Temporary Internet Files"
        }
    }

    // MARK: Bureautique

    /// Le poste de bureau : peu de fichiers, petits, mais réenregistrés sans
    /// arrêt. Chaque enregistrement écrit un temporaire à côté puis remplace
    /// l'original, donc le document change de place et laisse un trou. C'est une
    /// fragmentation discrète mais **dispersée**, très différente de celle d'un
    /// développeur.
    private mutating func officeWork(_ office: ActivitySpec.Office, on day: UInt32) {
        let directory = catalog.makeDirectory(path: documentPath)

        for _ in 0..<occurrences(office.newDocumentsPerWeek / 7) {
            let id = newID()
            // Un document est travaillé quelques semaines, puis il est fini et
            // on n'y touche plus. L'enregistrer encore trois ans plus tard
            // ferait de chaque courrier un fichier en cent morceaux, ce qu'on
            // ne voyait pas sur les disques de l'époque.
            let activeDays = min(14 + rng.cluster(below: 45), dayCount > day ? dayCount - day : 1)
            let saves = Int(office.savesPerDocumentPerWeek * Double(activeDays) / 7)
            let bytes = SizeModel.document(forYear: epochYear).sample(&rng)
            writer.write(FileSpec(id: id, name: "DOC\(id).DOC", directory: directory,
                                  category: .document,
                                  pattern: .writeTempThenRename,
                                  bytes: bytes),
                         from: day, to: day + activeDays, touches: saves, rng: &rng)
            documents.append(id)
            // Un document de travail n'est pas ce qu'on efface pour faire de la
            // place, mais il grossit : on compte large.
            track(id, bytes: bytes * 3, disposable: false, on: day)
        }

        // La boîte aux lettres, qui ne fait que grossir sur trois ans.
        if day == 1, epochYear >= 2003 {
            writer.write(FileSpec(id: newID(), name: "Outlook.pst", directory: directory,
                                  category: .document,
                                  pattern: .append(growthPerEvent: 900_000),
                                  bytes: 4_000_000),
                         from: 1, to: dayCount, touches: Int(dayCount / 7), rng: &rng)
        }
    }

    private var documentPath: String {
        switch epochYear {
        case ...1996: return "\\MYDOCU~1"
        case ...2003: return "\\Documents and Settings\\moi\\Mes documents"
        default:      return "\\Users\\moi\\Documents"
        }
    }

    // MARK: Multimédia

    /// Les médias sont écrits une fois et ne bougent plus : pris isolément, ils
    /// ne fragmentent rien. Ce qu'ils font, c'est **remplir** — et c'est le
    /// remplissage qui fragmente tout ce qui est écrit ensuite.
    private mutating func importMedia(_ media: ActivitySpec.Media, on day: UInt32) {
        let directory = catalog.makeDirectory(path: mediaPath)
        let distribution: SizeModel.Distribution = switch epochYear {
        case ...1999: SizeModel.mp3
        case ...2003: rng.chance(0.75) ? SizeModel.photo(forYear: epochYear) : SizeModel.divx
        default:      rng.chance(0.7) ? SizeModel.photo(forYear: epochYear) : SizeModel.homeVideo
        }

        for _ in 0..<occurrences(media.filesPerWeek / 7) {
            let id = newID()
            let bytes = distribution.sample(&rng)
            writer.write(FileSpec(id: id, name: "M\(id)", directory: directory,
                                  category: .media, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            track(id, bytes: bytes, disposable: true, on: day)
        }
    }

    private var mediaPath: String {
        switch epochYear {
        case ...1999: return "\\MP3"
        case ...2003: return "\\Documents and Settings\\moi\\Mes documents\\Ma musique"
        default:      return "\\Users\\moi\\Pictures"
        }
    }

    // MARK: Téléchargement

    /// Les archives en parties de taille fixe : téléchargées, extraites, puis
    /// supprimées. Elles laissent une alternance de trous parfaitement réguliers
    /// que rien d'autre ne produit — la signature visuelle du téléchargeur.
    private mutating func downloadFiles(_ download: ActivitySpec.Download, on day: UInt32) {
        let directory = catalog.makeDirectory(path: downloadPath)

        for _ in 0..<occurrences(download.perWeek / 7) {
            if let partMB = download.partMB {
                let partBytes = partMB * 1_024 * 1_024
                let parts = 4 + Int(rng.below(12))
                var partIDs: [UInt32] = []
                for index in 0..<parts {
                    let id = newID()
                    writer.write(FileSpec(id: id, name: "PART\(index).RAR", directory: directory,
                                          category: .archive, bytes: partBytes),
                                 from: day, to: day, touches: 0, rng: &rng)
                    partIDs.append(id)
                }
                // L'extraction écrit le contenu à côté des parties, **avant** que
                // celles-ci ne soient supprimées : c'est cet ordre qui fabrique
                // l'alternance.
                let extracted = partBytes * ByteCount(parts) * 95 / 100
                let extractedID = newID()
                writer.write(FileSpec(id: extractedID, name: "EXTRAIT", directory: directory,
                                      category: .archive, bytes: extracted),
                             from: day, to: day, touches: 0, rng: &rng)
                track(extractedID, bytes: extracted, disposable: true, on: day)
                for id in partIDs {
                    writer.timeline.append(.delete(id: id), on: min(day + 1, dayCount))
                }
            } else {
                let id = newID()
                let bytes = SizeModel.archivePart.sample(&rng)
                writer.write(FileSpec(id: id, name: "DL", directory: directory,
                                      category: .archive, bytes: bytes),
                             from: day, to: day, touches: 0, rng: &rng)
                track(id, bytes: bytes, disposable: true, on: day)
            }
        }
    }

    private var downloadPath: String {
        epochYear <= 1996 ? "\\DOWNLOAD" : "\\Downloads"
    }

    // MARK: Jeux

    /// Un jeu, c'est quelques fichiers énormes copiés une fois depuis un CD :
    /// contigus, propres, et parfaitement immobiles. Ce qui fragmente un disque
    /// de joueur, ce n'est pas le jeu, ce sont les **désinstallations**, qui
    /// ouvrent des trous de plusieurs centaines de mégaoctets au milieu du
    /// volume, et les sauvegardes qui les remplissent par petits bouts.
    private mutating func play(_ gaming: ActivitySpec.Gaming, on day: UInt32) {
        let saves = catalog.makeDirectory(path: savePath)

        if occurrences(gaming.installsPerYear / 365) > 0 {
            let directory = catalog.makeDirectory(path: "\(gamePath)\\JEU\(nextID)")
            var files: [UInt32] = []
            for index in 0..<(3 + Int(rng.below(6))) {
                let id = newID()
                let bytes = SizeModel.gameAsset.sample(&rng)
                writer.write(FileSpec(id: id, name: "DATA\(index).PAK", directory: directory,
                                      category: .gameAsset, bytes: bytes),
                             from: day, to: day, touches: 0, rng: &rng)
                files.append(id)
                track(id, bytes: bytes, disposable: true, on: day)
            }
            gameFiles.append(files)
        }

        if !gameFiles.isEmpty, occurrences(gaming.uninstallsPerYear / 365) > 0 {
            let removed = gameFiles.removeFirst()
            for id in removed { writer.timeline.append(.delete(id: id), on: day) }
        }

        for _ in 0..<occurrences(gaming.savesPerDay) {
            writer.write(FileSpec(id: newID(), name: "SAVE.DAT", directory: saves,
                                  category: .document,
                                  pattern: .writeTempThenRename,
                                  bytes: SizeModel.gameSave.sample(&rng)),
                         from: day, to: min(day + 30, dayCount), touches: 4, rng: &rng)
        }
    }

    /// Ce que l'utilisateur entasse : des archives, des images de CD, des
    /// sauvegardes. Écrit une fois, jamais retouché, jamais effacé tant qu'il
    /// reste de la place. Pris isolément, ça ne fragmente rien du tout — mais
    /// c'est ce qui **remplit** le disque, et le remplissage est la variable de
    /// premier ordre : à 60 % il ne se passe rien, à 93 % tout ce qu'on écrit
    /// part en miettes.
    /// Une vague de mises à jour : des fichiers système remplacés un par un.
    /// Chacun est supprimé puis réécrit — et ce qui est réécrit ne revient
    /// jamais à sa place. Sur un volume déjà bien rempli, c'est là que la
    /// majorité des fichiers d'un disque part en morceaux : pas dans ce que
    /// l'utilisateur crée, mais dans ce que le système remplace sous lui.
    private mutating func update(_ maintenance: ActivitySpec.Maintenance, on day: UInt32) {
        guard occurrences(maintenance.updatesPerYear / 365) > 0 else { return }
        guard !replaceableSystemFiles.isEmpty else { return }

        let directory = catalog.makeDirectory(path: systemLibraryPath)
        for _ in 0..<maintenance.filesPerUpdate {
            let index = rng.index(below: replaceableSystemFiles.count)
            let victim = replaceableSystemFiles[index]

            // Le fichier de remplacement est écrit, l'ancien est effacé. Une
            // version plus récente est presque toujours un peu plus grosse.
            let id = newID()
            let bytes = ByteCount(Double(victim.bytes) * rng.uniform(1.0...1.4))
            writer.write(FileSpec(id: id, name: "UPD\(id).DLL", directory: directory,
                                  category: .systemCore, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            writer.timeline.append(.delete(id: victim.id), on: day)

            committedBytes += occupancy(of: bytes)
            let freed = occupancy(of: victim.bytes)
            committedBytes = committedBytes > freed ? committedBytes - freed : 0
            replaceableSystemFiles[index] = (id, bytes)
        }
        makeRoomIfNeeded(on: day)
    }

    private mutating func hoard(_ hoarding: ActivitySpec.Hoarding, on day: UInt32) {
        let bytesPerDay = hoarding.gigabytesPerYear * 1_073_741_824 / 365
        // Une taille typique de « chose qu'on garde » à cette époque-là : une
        // archive de quelques dizaines de mégaoctets en 2003, quelques
        // mégaoctets en 1993.
        let median: Double = epochYear <= 1996 ? 2_000_000 : (epochYear <= 2003 ? 40_000_000 : 200_000_000)
        guard bytesPerDay > 0 else { return }

        // Nombre d'objets entassés aujourd'hui, à partir du débit voulu.
        let rate = bytesPerDay / median
        for _ in 0..<occurrences(rate) {
            let id = newID()
            let bytes = ByteCount(rng.logNormal(median: median, sigma: 0.9))
            writer.write(FileSpec(id: id, name: "ARCH\(id)",
                                  directory: catalog.makeDirectory(path: archivePath),
                                  category: .archive, bytes: bytes),
                         from: day, to: day, touches: 0, rng: &rng)
            track(id, bytes: bytes, disposable: true, on: day)
        }
    }

    private var gamePath: String { epochYear <= 1996 ? "\\JEUX" : "\\Games" }
    private var savePath: String { epochYear <= 1996 ? "\\JEUX\\SAVE" : "\\Games\\Saves" }
}
