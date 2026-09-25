import Foundation
import DiskCore

/// Installer un disque de la galerie.
///
/// Le démarrage lit des fichiers que l'histoire du volume a laissés ; la
/// défragmentation les déplace. L'installation, elle, les **pose** : c'est le
/// jour 0 du scénario rejoué à l'oreille, fichier par fichier, sur un volume
/// vierge. Rien n'y est décidé pour faire du bruit : les places sont celles que
/// l'allocateur a données au générateur, et le disque d'arrivée est exactement
/// celui que deux ans d'usage vieilliront.
///
/// Ce qui fait qu'on reconnaît une installation d'époque est autour des
/// fichiers :
///
/// - **la source** bride la copie — une disquette se lit à quelques dizaines de
///   kilo-octets par seconde, un CD de 1998 à 3,6 Mo/s — et c'est elle qui
///   espace les écritures ;
/// - **les archives** : l'installeur les extrait sur le disque avant de copier,
///   les relit morceau par morceau, puis les efface ;
/// - **les tables** : chaque fichier créé touche la FAT ou la MFT, écrites tout
///   de suite sous MS-DOS, par salves derrière le cache ensuite ;
/// - **le registre**, réécrit en bloc après chaque logiciel ;
/// - **les redémarrages**, qui relisent ce qui vient d'être posé.
enum InstallSession {}

// MARK: - L'époque d'une installation

/// Ce qui, dans une installation, ne dépend que de la machine de l'époque.
///
/// Les pauses sont **raccourcies** : une détection du matériel prenait des
/// minutes, une question à l'écran attendait qu'on revienne du café. On en
/// garde assez pour que le disque s'y taise et qu'on l'entende repartir.
struct InstallEra: Sendable {

    enum MetadataFlush: Sendable, Equatable {
        /// Chaque fichier écrit ses tables aussitôt : MS-DOS sans SMARTDRV,
        /// tel que l'installeur démarré d'une disquette le trouvait.
        case everyFile
        /// Le cache garde les tables et les vide à intervalles : VCACHE sous
        /// Windows 95 et 98, le *lazy writer* sous NT.
        case every(seconds: Double)
    }

    let name: String
    /// Calcul par fichier — le créer, l'enregistrer — et décompression par
    /// mégaoctet écrit.
    let think: ThinkModel
    let flush: MetadataFlush
    /// NTFS journalise ses métadonnées : chaque vidage écrit aussi `$LogFile`.
    let journaled: Bool
    /// Changer de disquette : la question, la main, le lecteur qui relit.
    let floppySwap: Double
    /// Détection du matériel, après le premier redémarrage d'un système.
    let detection: Double
    /// « Configuration de Windows » entre deux redémarrages.
    let configuration: Double
    /// Cliquer sur « Redémarrer » à la fin d'une étape.
    let restartPrompt: Double
    /// Taille des écritures de données, en secteurs : **jamais plus de 256**.
    ///
    /// Une commande ATA sans LBA48 porte son compte de secteurs sur huit bits,
    /// zéro valant 256 : 128 Ko par commande, quoi que le cache ait à vider.
    /// Sous XP, les 64 Ko ne viennent pas du pilote de port — `atapi`
    /// accepte 128 Ko par SRB, en LBA48 aussi (`ide/inc/idep.h:31`), et
    /// `classpnp` coupe à 124 Ko (`BootPlanner.classPacketSectors`) : ils
    /// viennent du cache, dont le *lazy writer* écrit par 64 Ko au plus
    /// (`MAX_WRITE_BEHIND`, `cache/cc.h:159, 175`), et de `CopyFile`, qui copie
    /// par 64 Ko (`BASE_COPY_FILE_CHUNK`, `win32/client/basedll.h:129`) ;
    /// MS-DOS écrit par ses tampons de 64 Ko. Vista garde ici le plafond de
    /// l'ATA : les disques de 2007 sont en LBA48, qui le lève, mais rien ne
    /// dit ce que faisait son pilote.
    ///
    /// Écrire un DVD par morceaux de 64 Ko ne fait pas attendre un demi-tour de
    /// plateau à chaque morceau : le disque a son cache d'écriture, il acquitte
    /// le morceau et pose la suite sans attendre le tour. Ce que coûte le
    /// plafond est mesuré dans `LEDGER.md` (chantier 27).
    let writeRequestSectors: Int

    /// Ce que le système lit ou écrit au moins d'un fichier, en octets : les
    /// secteurs demandés sous MS-DOS, des pages de 4 Ko derrière le cache de
    /// Windows — pas des clusters, qui sont l'unité d'allocation
    /// (`BootScript.Era.readGranularity`, le même choix pour le démarrage).
    /// Écrire les 2 Ko d'un `.ini` sur un volume en clusters de 32 Ko coûte
    /// 4 Ko, et non 32.
    var granularity: Int {
        name == "MS-DOS" ? DriveGeometry.bytesPerSector : 4_096
    }

    static func matching(_ spec: ProfileSpec) -> InstallEra {
        let year = spec.timeline.start.year
        switch year {
        case ..<1995:
            return InstallEra(name: "MS-DOS", think: ThinkModel(perFile: 0.08, perMegabyte: 0.6),
                              flush: .everyFile, journaled: false,
                              floppySwap: 6, detection: 3, configuration: 4, restartPrompt: 2,
                              writeRequestSectors: 128)
        case 1995...1997:
            return InstallEra(name: "Windows 95", think: ThinkModel(perFile: 0.04, perMegabyte: 0.25),
                              flush: .every(seconds: 3), journaled: false,
                              floppySwap: 6, detection: 12, configuration: 8, restartPrompt: 2,
                              writeRequestSectors: 256)
        case 1998...2000:
            return InstallEra(name: "Windows 98", think: ThinkModel(perFile: 0.02, perMegabyte: 0.12),
                              flush: .every(seconds: 3), journaled: false,
                              floppySwap: 6, detection: 10, configuration: 8, restartPrompt: 2,
                              writeRequestSectors: 256)
        case 2001...2005:
            return InstallEra(name: "Windows XP", think: ThinkModel(perFile: 0.012, perMegabyte: 0.05),
                              flush: .every(seconds: 1), journaled: spec.fileSystem.type == .ntfs,
                              floppySwap: 6, detection: 8, configuration: 10, restartPrompt: 2,
                              writeRequestSectors: 128)
        case 2006...2009:
            return InstallEra(name: "Windows Vista", think: ThinkModel(perFile: 0.006, perMegabyte: 0.03),
                              flush: .every(seconds: 1), journaled: spec.fileSystem.type == .ntfs,
                              floppySwap: 6, detection: 6, configuration: 12, restartPrompt: 2,
                              writeRequestSectors: 256)
        default:
            // Windows 7 : le calcul de Vista divisé par 1,5, comme au démarrage
            // (`ThinkModel.boot`) ; le même plafond de requête, faute de savoir
            // ce que faisait le pilote AHCI.
            return InstallEra(name: "Windows 7", think: ThinkModel(perFile: 0.004, perMegabyte: 0.02),
                              flush: .every(seconds: 1), journaled: spec.fileSystem.type == .ntfs,
                              floppySwap: 6, detection: 4, configuration: 10, restartPrompt: 2,
                              writeRequestSectors: 256)
        }
    }
}

// MARK: - Les phases

/// Les phases d'une installation, et où chaque étape range ses opérations.
struct InstallPhases {
    let descriptors: [PhaseDescriptor]
    /// Phase de la copie de chaque étape.
    let copy: [Int]
    /// Phase des redémarrages de chaque étape, s'il y en a.
    let reboot: [Int?]

    init(_ installed: InstalledDisk) {
        var descriptors: [PhaseDescriptor] = []
        var copy: [Int] = []
        var reboot: [Int?] = []
        let catalog = InstallSummary(installed)

        for (index, step) in installed.steps.enumerated() {
            let files = catalog.files[index]
            let megabytes = Double(catalog.bytes[index]) / 1_048_576
            let size = megabytes >= 10
                ? String(format: "%.0f Mo", megabytes)
                : String(format: "%.1f Mo", megabytes).replacingOccurrences(of: ".", with: ",")

            switch step.kind {
            case .swap:
                if step.fileIDs.isEmpty {
                    copy.append(max(descriptors.count - 1, 0))
                } else {
                    copy.append(descriptors.count)
                    descriptors.append(PhaseDescriptor(
                        id: "step-\(index)",
                        label: String(localized: "category.swap", defaultValue: "Page file"),
                        detail: String(localized: "phase.swap.detail",
                                       defaultValue: "\(size) reserved in one piece")))
                }
            case .system, .application:
                copy.append(descriptors.count)
                var detail = "\(files) fichiers, \(size), depuis \(step.style.label(bytes: ByteCount(catalog.bytes[index])))"
                if let extraction = step.style.extraction {
                    detail += " · archives extraites dans \(extraction.directory)"
                }
                descriptors.append(PhaseDescriptor(
                    id: "step-\(index)",
                    label: step.kind == .system
                        ? String(localized: "phase.copyOf", defaultValue: "Copying \(step.displayName)")
                        : String(localized: "phase.installOf", defaultValue: "Installing \(step.displayName)"),
                    detail: detail))
            }

            if step.style.reboots > 0 {
                reboot.append(descriptors.count)
                let count = step.style.reboots
                descriptors.append(PhaseDescriptor(
                    id: "reboot-\(index)",
                    label: step.kind == .system
                        ? String(localized: "phase.rebootsAndSetup", defaultValue: "Restarts and setup")
                        : String(localized: "phase.reboot", defaultValue: "Restart"),
                    detail: String(localized: "phase.reboot.detail",
                                   defaultValue: "\(count) restarts",
                                   comment: "Nombre de redémarrages, au pluriel de la langue")))
            } else {
                reboot.append(nil)
            }
        }

        self.descriptors = descriptors
        self.copy = copy
        self.reboot = reboot
    }
}

/// Ce que chaque étape pose, lu dans le journal.
struct InstallSummary {
    /// Fichiers et octets posés pour de bon, par étape.
    var files: [Int]
    var bytes: [Int]
    var temporaryFiles = 0
    var temporaryBytes = 0

    init(_ installed: InstalledDisk) {
        files = Array(repeating: 0, count: installed.steps.count)
        bytes = Array(repeating: 0, count: installed.steps.count)
        let temporaries = Set(installed.steps.flatMap(\.temporaryIDs))
        var step = 0
        for entry in installed.journal {
            switch entry {
            case let .begin(index):
                step = index
            case let .created(record):
                if temporaries.contains(record.id) {
                    temporaryFiles += 1
                    temporaryBytes += Int(record.logicalSize)
                } else {
                    files[step] += 1
                    bytes[step] += Int(record.logicalSize)
                }
            case .deleted, .metadataGrew, .directoryGrew:
                break
            }
        }
    }

    var totalFiles: Int { files.reduce(0, +) }
    var totalBytes: Int { bytes.reduce(0, +) }
}

// MARK: - Le plan

/// Ce qu'une installation a écrit, et ce qu'elle a coûté hors du disque.
struct InstallPlan {
    let partition: PartitionGeometry
    let phases: [PhaseDescriptor]
    var filesWritten = 0
    var bytesWritten = 0
    var temporaryFiles = 0
    var temporaryBytes = 0
    var temporaryBytesRead = 0
    var settingsRewrites = 0
    var reboots = 0
    /// Vidages des tables, et secteurs de métadonnées écrits.
    var metadataFlushes = 0
    var metadataSectors = 0
    /// Lecture de la source — disquettes, CD — et changements de disquette.
    var sourceSeconds = 0.0
    /// Tout le temps passé hors du disque : source, calcul, pauses.
    var thinkSeconds = 0.0
}

enum InstallPlanner {

    /// Même découpage que le démarrage : fin devant un extent.
    static let maxRequestSectors = 128

    /// L'état de départ de la carte : un volume vierge, où seul le système de
    /// fichiers occupe déjà sa place.
    static func initialRuns(of installed: InstalledDisk) -> [MapRun] {
        installed.initialSystemExtents
            .filter { !$0.isEmpty }
            .sorted { $0.start < $1.start }
            .map { MapRun(start: $0.start, count: $0.length, category: ClusterCategory.reserved.rawValue) }
    }

    /// Rejoue l'installation dans `sink`.
    ///
    /// - Parameter diskBytesPerSecond: débit du disque, pour estimer l'heure à
    ///   laquelle le cache vide ses tables. Le planificateur ne connaît pas la
    ///   mécanique ; il n'a besoin que d'un ordre de grandeur.
    @discardableResult
    static func plan(installed: InstalledDisk,
                     diskBytesPerSecond: Double,
                     into sink: OperationSink,
                     isCancelled: () -> Bool = { false }) -> InstallPlan {
        var emitter = Emitter(installed: installed,
                              diskBytesPerSecond: diskBytesPerSecond,
                              sink: sink)
        for (index, entry) in installed.journal.enumerated() {
            if index & 0xFF == 0, isCancelled() { break }
            emitter.consume(entry)
        }
        emitter.finish()
        return emitter.plan
    }

    // MARK: - Émission

    private struct Emitter {

        let installed: InstalledDisk
        let partition: PartitionGeometry
        let era: InstallEra
        let phases: InstallPhases
        let diskBytesPerSecond: Double
        let sink: OperationSink
        let temporaries: Set<UInt32>
        let summary: InstallSummary
        let totalBytes: Int

        var plan: InstallPlan

        /// Fichiers présents, tels qu'ils ont été posés.
        private var placed: [UInt32: FileRecord] = [:]
        /// Rang de création, qui désigne l'enregistrement MFT. Les seize
        /// premiers sont ceux du système de fichiers lui-même.
        private var ranks: [UInt32: Int] = [:]
        private var step = -1
        private var phase = 0

        /// Secteurs de métadonnées modifiés et pas encore écrits.
        private var dirty: [Int: Int] = [:]
        /// Sous XP, le *lazy writer* et la file d'`atapi` (`LazyWriter`).
        private var lazy = LazyWriter()
        private var queue = AtapiQueue()
        /// L'heure estimée de la fin de la dernière requête du premier plan.
        private var foregroundEnd = 0.0
        private var usesLazyWriter: Bool {
            era.name == "Windows XP" && partition.format == .ntfs
        }
        private var pendingMutations: [MapMutation] = []
        private var pendingThink = 0.0
        /// Heure estimée de la passe, et du dernier vidage des tables.
        private var clock = 0.0
        private var lastFlush = 0.0
        private var bytesPlaced = 0
        /// Octets compressés lus depuis la disquette en cours.
        private var floppyBytes = 0.0

        /// Archives de l'étape, relues en tourniquet pendant la copie.
        private var cabinets: [Extent] = []
        /// Sous XP, à quel fichier appartient chaque extent des archives, et
        /// à quel secteur de ce fichier il commence : la lecture anticipée
        /// du cache se joue par fichier (`CcReadAhead`).
        private var cabinetOwners: [(id: UInt32, firstSector: Int)] = []
        private var cabinetFiles: [UInt32: (extents: [Extent], size: Int)] = [:]
        private var readAheads: [UInt32: CcReadAhead] = [:]
        /// Où l'installeur en est dans ses archives : l'extent, et le secteur
        /// dans cet extent.
        private var cabinetCursor = (extent: 0, offset: 0)
        private var cabinetRatio = 0.0
        private var engineLaunched = false

        init(installed: InstalledDisk, diskBytesPerSecond: Double, sink: OperationSink) {
            self.installed = installed
            self.partition = GeneratedVolumeBridge.partition(of: installed.disk)
            self.era = InstallEra.matching(installed.disk.spec)
            self.phases = InstallPhases(installed)
            self.diskBytesPerSecond = max(diskBytesPerSecond, 100_000)
            self.sink = sink
            self.temporaries = Set(installed.steps.flatMap(\.temporaryIDs))
            let summary = InstallSummary(installed)
            self.summary = summary
            self.totalBytes = max(summary.totalBytes, 1)
            self.plan = InstallPlan(partition: partition, phases: phases.descriptors)
        }

        private var currentStep: InstallStep? {
            installed.steps.indices.contains(step) ? installed.steps[step] : nil
        }

        mutating func consume(_ entry: InstallEntry) {
            switch entry {
            case let .begin(index):
                closeStep()
                open(step: index)
            case let .created(record):
                create(record)
            case let .deleted(record):
                delete(record)
            case let .metadataGrew(extents):
                grow(extents, as: .reserved)
            case let .directoryGrew(extents):
                grow(extents, as: .directory)
            }
        }

        mutating func finish() {
            closeStep()
            flushMetadata(force: true, shutdown: true)
            // La dernière écriture des tables, et ce que la carte attend encore.
            sink.progress = 1
            if !pendingMutations.isEmpty {
                emit(.metadata, lba: partition.startLBA, sectors: 1, isWrite: true, cluster: nil)
            }
        }

        // MARK: Étapes

        private mutating func open(step index: Int) {
            step = index
            guard let current = currentStep else { return }
            phase = phases.copy[index]
            cabinets = []
            cabinetOwners = []
            cabinetFiles = [:]
            readAheads = [:]
            cabinetCursor = (0, 0)
            engineLaunched = false
            // Part d'archive relue par octet posé : l'installeur tire tout ce
            // qu'il copie de ce qu'il a extrait.
            let posed = summary.bytes[index]
            cabinetRatio = current.style.extraction?.use == .cabinets && posed > 0
                ? Double(current.style.extraction?.bytes ?? 0) / Double(posed)
                : 0
            // Insérer le support, lancer l'installeur.
            if current.kind != .swap { pendingThink += era.restartPrompt }
        }

        private mutating func closeStep() {
            guard let current = currentStep else { return }
            flushMetadata(force: true)
            guard current.kind != .swap else { return }

            rewriteSettings()

            guard current.style.reboots > 0, let rebootPhase = phases.reboot[step] else { return }
            phase = rebootPhase
            for index in 0..<current.style.reboots {
                pendingThink += era.restartPrompt
                reboot()
                if current.kind == .system {
                    // Après le premier redémarrage, Windows cherche son
                    // matériel ; après les suivants, il se configure. Dans les
                    // deux cas il écrit ses réglages avant de redémarrer.
                    pendingThink += index == 0 ? era.detection : era.configuration
                    rewriteSettings()
                    flushMetadata(force: true)
                }
            }
        }

        // MARK: Fichiers

        private mutating func create(_ record: FileRecord) {
            guard let current = currentStep else { return }
            placed[record.id] = record
            ranks[record.id] = 16 + ranks.count

            let isTemporary = temporaries.contains(record.id)
            let bytes = Int(record.logicalSize)

            // Les tables d'abord : le fichier naît dans le répertoire avant
            // d'avoir un octet.
            markDirty(record)

            if !isTemporary, current.style.extraction?.use == .setupEngine, !engineLaunched {
                launchEngine()
            }

            pendingThink += era.think.perFile

            if current.kind == .swap {
                // Un fichier d'échange est réservé, pas rempli : seules les
                // tables sont écrites, et la carte se colore d'un bloc.
                queueMutations(for: record)
                plan.filesWritten += 1
                bytesPlaced += bytes
            } else if record.isResident || record.extents.isEmpty {
                pendingThink += sourceTime(bytes: bytes, compressed: !isTemporary)
                count(record, temporary: isTemporary)
            } else {
                queueMutations(for: record)
                if !isTemporary, cabinetRatio > 0 {
                    readCabinet(bytes: Int(Double(bytes) * cabinetRatio))
                }
                writeData(of: record, compressed: !isTemporary)
                count(record, temporary: isTemporary)
            }

            if isTemporary, current.style.extraction?.use == .cabinets {
                var first = 0
                for extent in record.extents {
                    cabinetOwners.append((record.id, first))
                    first += Int(extent.length) * partition.clusterSectors
                }
                cabinetFiles[record.id] = (record.extents, Int(record.logicalSize))
                cabinets.append(contentsOf: record.extents)
            }
            flushMetadata(force: era.flush == .everyFile)
        }

        private mutating func count(_ record: FileRecord, temporary: Bool) {
            if temporary {
                plan.temporaryFiles += 1
                plan.temporaryBytes += Int(record.logicalSize)
            } else {
                plan.filesWritten += 1
                plan.bytesWritten += Int(record.logicalSize)
                bytesPlaced += Int(record.logicalSize)
            }
        }

        private mutating func delete(_ record: FileRecord) {
            // Sous XP, ses pages sales sont purgées sans être écrites
            // (`ntfs/cleanup.c:1576, 1930, 2515`).
            if usesLazyWriter { lazy.discard(.data(record.id)) }
            markDirty(record)
            placed.removeValue(forKey: record.id)
            for extent in record.extents where !extent.isEmpty {
                pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                    category: .free))
            }
            pendingThink += era.think.perFile / 2
            flushMetadata(force: era.flush == .everyFile)
        }

        private mutating func grow(_ extents: [Extent], as category: ClusterCategory) {
            for extent in extents where !extent.isEmpty {
                pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                    category: category))
                // Les nouveaux enregistrements sont initialisés à leur place.
                emit(.metadata, lba: partition.lba(ofCluster: Int(extent.start)),
                     sectors: min(Int(extent.length) * partition.clusterSectors, 16),
                     isWrite: true, cluster: Int(extent.start))
            }
        }

        private mutating func queueMutations(for record: FileRecord) {
            let category = ClusterCategory(record.category)
            let contiguous = record.extents.coalesced().count <= 1
            for extent in record.extents where !extent.isEmpty {
                pendingMutations.append(MapMutation(start: Int(extent.start), count: Int(extent.length),
                                                    category: category, contiguous: contiguous))
            }
        }

        // MARK: Données

        /// Temps de source et de décompression pour `bytes` écrits.
        private mutating func sourceTime(bytes: Int, compressed: Bool) -> Double {
            guard let current = currentStep, current.kind != .swap else { return 0 }
            let expansion = compressed ? SetupLibrary.floppyExpansion : 1
            let onMedium = Double(bytes) / expansion
            var seconds = onMedium / current.style.sourceBytesPerSecond
            plan.sourceSeconds += seconds
            if current.style.medium == .floppy {
                floppyBytes += onMedium
                while floppyBytes >= 1_457_664 {
                    floppyBytes -= 1_457_664
                    seconds += era.floppySwap
                    plan.sourceSeconds += era.floppySwap
                }
            }
            if compressed {
                seconds += era.think.perMegabyte * Double(bytes) / 1_048_576
            }
            return seconds
        }

        /// Sous XP, `CopyFile` écrit par le cache (`BaseCopyStream`,
        /// 64 Ko à la fois, `win32/client/fileopcr.c:4847-4870`) : les pages
        /// sont salies, et c'est le *lazy writer* qui les pose (`LazyWriter`).
        private mutating func writeData(of record: FileRecord, compressed: Bool) {
            var remaining = PartitionGeometry.readSectors(forBytes: Int(record.logicalSize),
                                                          granularity: era.granularity)
            var page = 0
            for extent in record.extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = 0
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, era.writeRequestSectors, remaining)
                    let bytes = sectors * DriveGeometry.bytesPerSector
                    pendingThink += sourceTime(bytes: min(bytes, Int(record.logicalSize)),
                                               compressed: compressed)
                    let cluster = Int(extent.start) + offset / partition.clusterSectors
                    let lba = partition.lba(ofCluster: Int(extent.start)) + offset
                    if usesLazyWriter {
                        var piece = 0
                        while piece < sectors {
                            lazy.dirty(.data(record.id), rank: page, lba: lba + piece,
                                       at: clock + pendingThink)
                            page += 1
                            piece += LazyWriter.pageSectors
                        }
                        runLazyWriter(at: clock + pendingThink, shutdown: false)
                    } else {
                        emit(.writeExtent, lba: lba, sectors: sectors, isWrite: true, cluster: cluster)
                    }
                    offset += sectors
                    remaining -= sectors
                }
                if remaining == 0 { break }
            }
        }

        /// Relit un morceau d'archive, là où l'installeur en était.
        private mutating func readCabinet(bytes: Int) {
            guard !cabinets.isEmpty else { return }
            var sectors = PartitionGeometry.readSectors(forBytes: bytes, granularity: era.granularity)
            var guardSteps = 0
            while sectors > 0, guardSteps < 64 {
                guardSteps += 1
                if cabinetCursor.extent >= cabinets.count { cabinetCursor = (0, 0) }
                let extent = cabinets[cabinetCursor.extent]
                let length = Int(extent.length) * partition.clusterSectors
                let take = min(length - cabinetCursor.offset, sectors, maxRequestSectors)
                let cluster = Int(extent.start) + cabinetCursor.offset / partition.clusterSectors
                let lba = partition.lba(ofCluster: Int(extent.start)) + cabinetCursor.offset
                if usesLazyWriter {
                    readCabinetThroughCache(extent: cabinetCursor.extent, sectors: take)
                } else {
                    emit(.readExtent, lba: lba, sectors: take, isWrite: false, cluster: cluster)
                }
                plan.temporaryBytesRead += take * DriveGeometry.bytesPerSector
                sectors -= take
                cabinetCursor.offset += take
                if cabinetCursor.offset >= length {
                    cabinetCursor = (cabinetCursor.extent + 1, 0)
                }
            }
        }

        /// Sous XP, une lecture d'archive passe par le cache : ce que le lazy
        /// writer n'a pas encore posé, ou que la lecture anticipée a déjà lu,
        /// s'y relit ; ce que le cache lit d'avance part en arrière-plan
        /// (`CcReadAhead`).
        private mutating func readCabinetThroughCache(extent index: Int, sectors take: Int) {
            let owner = cabinetOwners[index]
            guard let file = cabinetFiles[owner.id] else { return }
            let sector = DriveGeometry.bytesPerSector
            let offset = (owner.firstSector + cabinetCursor.offset) * sector
            var cache = readAheads[owner.id] ?? CcReadAhead()
            let (demand, ahead) = cache.read(offset: offset, length: take * sector, fileSize: file.size)
            readAheads[owner.id] = cache
            func held(_ piece: MetadataAccess) -> Bool {
                stride(from: piece.lba / 8 * 8, to: piece.lba + piece.sectors, by: 8)
                    .allSatisfy { lazy.holds(lba: $0) }
            }
            if let demand {
                for piece in CcReadAhead.pieces(of: file.extents, bytes: demand, partition: partition)
                where !held(piece) {
                    emit(.readExtent, lba: piece.lba, sectors: piece.sectors, isWrite: false,
                         cluster: (piece.lba - partition.dataStartLBA) / partition.clusterSectors)
                }
            }
            if let ahead {
                for piece in CcReadAhead.pieces(of: file.extents, bytes: ahead, partition: partition)
                where !held(piece) {
                    sink.emit(DiskOperation(kind: .readExtent, phase: phase, lba: piece.lba,
                                            sectors: piece.sectors, isWrite: false, issueTime: 0,
                                            cluster: (piece.lba - partition.dataStartLBA) / partition.clusterSectors,
                                            mutationStart: sink.mutationMark, mutationCount: 0,
                                            flow: .background))
                }
            }
        }

        /// Le programme d'installation est lu d'un bloc avant la première copie.
        private mutating func launchEngine() {
            engineLaunched = true
            guard let current = currentStep else { return }
            for id in current.temporaryIDs {
                guard let record = placed[id] else { continue }
                pendingThink += era.think.perFile
                readWhole(record, isWrite: false)
            }
            // L'assistant pose ses questions : nom, dossier, composants.
            pendingThink += era.configuration
        }

        private mutating func rewriteSettings() {
            var rewrote = false
            for step in installed.steps {
                for id in step.settingsIDs {
                    guard let record = placed[id], !record.extents.isEmpty else { continue }
                    pendingThink += era.think.perFile
                    if usesLazyWriter {
                        // Sous XP, la ruche est salie, et le vidage paresseux
                        // du registre part 5 s après la dernière modification
                        // (`CmpLazyFlush`, `config/cmworker.c:41, 523-535` :
                        // la minuterie est réarmée à chaque `HvMarkDirty`,
                        // `hivesync.c:659-662`).
                        dirtyHives.insert(id)
                        registryFlushAt = clock + pendingThink + Self.registryFlushDelay
                    } else {
                        readWhole(record, isWrite: true)
                    }
                    rewrote = true
                }
            }
            if rewrote { plan.settingsRewrites += 1 }
        }

        /// `LAZY_FLUSH_INTERVAL_IN_SECONDS` (`config/cmworker.c:41`).
        static let registryFlushDelay = 5.0
        /// Sous XP, les ruches salies, et l'heure de leur vidage paresseux.
        private var dirtyHives: Set<UInt32> = []
        private var registryFlushAt = Double.infinity

        /// Sous XP, le vidage des ruches salies (`CmpDoFlushAll`, puis
        /// `HvSyncHive`, `config/hivesync.c:1759-2500, 2542-2810`) : pour
        /// chacune, son `.LOG` — en-tête, secteurs sales, en-tête —, chaque
        /// écriture suivie d'un `ZwFlushBuffersFile` qui descend jusqu'au
        /// `FLUSH CACHE` du disque (`cmwrapr.c:1045-1048` ; `ntfs/flush.c:596-611` ;
        /// `disk/disk.c:3406-3411`) ; puis la ruche elle-même, par le cache
        /// (`CcFlushCache`, sans vidage du disque, `cmwrapr.c:1036-1040`).
        ///
        /// Le catalogue n'a pas de `.LOG` : ses écritures ne sont pas posées,
        /// seuls ses trois `FLUSH CACHE` le sont. La ruche est réécrite en
        /// entier, comme le modèle le faisait : ce qu'une installation salit
        /// d'une ruche n'est dit nulle part.
        ///
        /// - Parameter now: à l'arrêt ou avant un redémarrage
        ///   (`CmShutdownSystem`), l'hôte l'attend ; sinon c'est un fil de
        ///   travail, en arrière-plan, à son heure.
        private mutating func flushRegistry(now: Bool) {
            guard !dirtyHives.isEmpty else { return }
            let delay = now ? 0 : max(registryFlushAt - foregroundEnd, 0)
            let flow: RequestFlow = now ? .foreground : .background
            for step in installed.steps {
                for id in step.settingsIDs where dirtyHives.contains(id) {
                    guard let record = placed[id] else { continue }
                    for _ in 0..<3 {
                        sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: partition.startLBA,
                                                sectors: 0, isWrite: true, issueTime: 0, cluster: nil,
                                                mutationStart: sink.mutationMark, mutationCount: 0,
                                                thinkTime: delay, flow: flow))
                    }
                    for piece in CcReadAhead.pieces(of: record.extents,
                                                    bytes: 0..<Int(record.logicalSize),
                                                    partition: partition) {
                        sink.emit(DiskOperation(kind: .metadata, phase: phase, lba: piece.lba,
                                                sectors: piece.sectors, isWrite: true, issueTime: 0,
                                                cluster: (piece.lba - partition.dataStartLBA) / partition.clusterSectors,
                                                mutationStart: sink.mutationMark, mutationCount: 0,
                                                thinkTime: delay, flow: flow))
                    }
                }
            }
            dirtyHives.removeAll()
            registryFlushAt = .infinity
        }

        private mutating func readWhole(_ record: FileRecord, isWrite: Bool) {
            var remaining = PartitionGeometry.readSectors(forBytes: Int(record.logicalSize),
                                                          granularity: era.granularity)
            for extent in record.extents {
                let length = Int(extent.length) * partition.clusterSectors
                var offset = 0
                while offset < length && remaining > 0 {
                    let sectors = min(length - offset, maxRequestSectors, remaining)
                    let cluster = Int(extent.start) + offset / partition.clusterSectors
                    emit(isWrite ? .metadata : .readExtent,
                         lba: partition.lba(ofCluster: Int(extent.start)) + offset,
                         sectors: sectors, isWrite: isWrite, cluster: cluster)
                    offset += sectors
                    remaining -= sectors
                }
                if remaining == 0 { break }
            }
        }

        // MARK: Redémarrages

        /// Un démarrage à chaud sur ce qui est posé jusqu'ici. Le plateau ne
        /// s'arrête pas : seul le POST impose son silence.
        private mutating func reboot() {
            flushMetadata(force: true, shutdown: true)
            var catalog = installed.disk.catalog
            for id in catalog.liveIDs where placed[id] == nil {
                _ = catalog.remove(id)
            }
            var partial = installed.disk
            partial.catalog = catalog

            let boot = BootPlanner.plan(disk: partial, launchesApplication: false,
                                        firstOfTheDay: false)
            pendingThink += boot.post
            for request in boot.requests {
                if !request.flow.isBackground { pendingThink += request.thinkTime }
                let offset = request.lba - partition.dataStartLBA
                let cluster = offset >= 0 ? offset / partition.clusterSectors : nil
                emit(request.isWrite ? .metadata : .scan, lba: request.lba,
                     sectors: request.sectorCount, isWrite: request.isWrite, cluster: cluster,
                     flow: request.flow,
                     delay: request.flow.isBackground ? request.thinkTime : 0,
                     hostWork: request.hostWork)
            }
            pendingThink += boot.tail
            queue = boot.queue
            plan.reboots += 1
        }

        // MARK: Métadonnées

        private mutating func markDirty(_ record: FileRecord) {
            let rank = ranks[record.id] ?? 16
            // Le répertoire tel qu'il est au soir de l'installation : il a pu
            // grandir depuis ce fichier, mais il n'a pas bougé.
            let directories = installed.disk.catalog.directories
            let entry = partition.entrySector(inDirectory: directories.indices.contains(Int(record.directory))
                                                  ? directories[Int(record.directory)] : nil)
            let accesses = partition.commitAccesses(for: record.extents, fileIndex: rank,
                                                    entrySector: entry,
                                                    validation: nil)
            guard usesLazyWriter else {
                for access in accesses { dirty[access.lba] = max(dirty[access.lba] ?? 0, access.sectors) }
                return
            }
            MachineWriter.dirtyNTFS(accesses, partition: partition, into: &lazy,
                                    at: clock + pendingThink)
        }

        /// Sous XP, les passages du *lazy writer* échus — ou tout, avant un
        /// redémarrage et à la fin —, en arrière-plan, une page de journal
        /// devant chacun (`MachineWriter.runLazyWriter`).
        private mutating func runLazyWriter(at time: Double, shutdown: Bool) {
            let scans = shutdown ? [LazyWriter.Scan(time: time, streams: lazy.flushAll())]
                : lazy.due(at: time)
            for scan in scans where !scan.streams.isEmpty {
                let metadata = scan.streams.contains { $0.first?.stream.isMetadata ?? false }
                var log: [LazyWriter.Write] = []
                if metadata {
                    let page = partition.logPage(journalPages)
                    journalPages += 1
                    log = [LazyWriter.Write(lba: page.lba, sectors: page.sectors, stream: .other(0))]
                }
                // Le passage tombe tant de secondes après la dernière requête
                // du premier plan ; l'arrêt, lui, l'attend.
                let delay = shutdown ? 0 : max(scan.time - foregroundEnd, 0)
                for write in LazyWriter.served(scan.streams, log: log, queue: &queue) {
                    // Les couleurs en attente partent avec l'écriture : les
                    // données n'arrivent au disque que par le lazy writer.
                    let start = sink.mutationMark
                    for mutation in pendingMutations { sink.record(mutation) }
                    let count = Int32(pendingMutations.count)
                    pendingMutations.removeAll(keepingCapacity: true)
                    let data = !write.stream.isMetadata
                    let offset = write.lba - partition.dataStartLBA
                    sink.progress = min(Double(bytesPlaced) / Double(totalBytes), 1)
                    sink.moves = MoveCount(filesMoved: plan.filesWritten, evacuations: 0)
                    sink.emit(DiskOperation(kind: data ? .writeExtent : .metadata, phase: phase,
                                            lba: write.lba, sectors: write.sectors, isWrite: true,
                                            issueTime: 0,
                                            cluster: data && offset >= 0 ? offset / partition.clusterSectors : nil,
                                            mutationStart: start, mutationCount: count,
                                            thinkTime: delay,
                                            flow: shutdown ? .foreground : .background))
                    if !data { plan.metadataSectors += write.sectors }
                }
                if metadata { plan.metadataFlushes += 1 }
            }
        }

        /// - Parameter shutdown: l'arrêt de la machine, qui vide tout. Sous
        ///   XP, rien d'autre ne force le *lazy writer*.
        private mutating func flushMetadata(force: Bool, shutdown: Bool = false) {
            if usesLazyWriter {
                if shutdown || registryFlushAt <= clock + pendingThink {
                    flushRegistry(now: shutdown)
                }
                runLazyWriter(at: clock + pendingThink, shutdown: shutdown)
                return
            }
            guard !dirty.isEmpty else { return }
            if !force, case let .every(seconds) = era.flush, clock - lastFlush < seconds { return }

            // Le cache écrit dans l'ordre du disque, et fusionne ce qui se
            // touche.
            var runs: [(lba: Int, sectors: Int)] = []
            for lba in dirty.keys.sorted() {
                let sectors = dirty[lba] ?? 1
                if let last = runs.last, lba <= last.lba + last.sectors {
                    runs[runs.count - 1].sectors = max(last.sectors, lba + sectors - last.lba)
                } else {
                    runs.append((lba, sectors))
                }
            }
            dirty.removeAll(keepingCapacity: true)

            // Écriture anticipée : la page de journal part avant les tables
            // qu'elle décrit, une par vidage — c'est le *lazy writer* qui
            // groupe.
            if era.journaled {
                let page = partition.logPage(journalPages)
                journalPages += 1
                emit(.metadata, lba: page.lba, sectors: page.sectors, isWrite: true, cluster: nil)
                plan.metadataSectors += page.sectors
            }
            for run in runs {
                emit(.metadata, lba: run.lba, sectors: run.sectors, isWrite: true, cluster: nil)
                plan.metadataSectors += run.sectors
            }
            plan.metadataFlushes += 1
            lastFlush = clock
        }

        /// Pages de `$LogFile` écrites jusqu'ici : le journal est circulaire,
        /// et chaque vidage écrit la suivante.
        private var journalPages = 0

        // MARK: Sortie

        /// `flow` et `backgroundThink` : comme `MachineWriter.emit`.
        private mutating func emit(_ kind: DiskOperation.Kind, lba: Int, sectors: Int,
                                   isWrite: Bool, cluster: Int?,
                                   flow: RequestFlow = .foreground, delay: Double = 0,
                       hostWork: Double = 0) {
            // Ce que le lazy writer — et le vidage du registre — ont écrit
            // pendant le calcul qui précède.
            if usesLazyWriter, !flow.isBackground {
                if registryFlushAt <= clock + pendingThink { flushRegistry(now: false) }
                runLazyWriter(at: clock + pendingThink, shutdown: false)
            }
            let start = sink.mutationMark
            for mutation in pendingMutations { sink.record(mutation) }
            let count = Int32(pendingMutations.count)
            pendingMutations.removeAll(keepingCapacity: true)

            let think = flow.isBackground ? delay : pendingThink
            sink.progress = min(Double(bytesPlaced) / Double(totalBytes), 1)
            sink.moves = MoveCount(filesMoved: plan.filesWritten, evacuations: 0)
            sink.emit(DiskOperation(kind: kind, phase: phase, lba: lba, sectors: sectors,
                                    isWrite: isWrite, issueTime: 0, cluster: cluster,
                                    mutationStart: start, mutationCount: count,
                                    thinkTime: think, flow: flow, hostWork: hostWork))
            guard !flow.isBackground else {
                plan.thinkSeconds += hostWork
                clock += hostWork
                return
            }
            plan.thinkSeconds += think
            clock += think
                + Double(sectors * DriveGeometry.bytesPerSector) / diskBytesPerSecond
                + 0.012
            foregroundEnd = clock
            pendingThink = 0
        }
    }
}
