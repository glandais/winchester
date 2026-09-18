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
    /// Taille des écritures de données. MS-DOS écrit par tampons de quelques
    /// dizaines de kilo-octets ; un cache de Windows vide des mégaoctets d'une
    /// traite. Écrire un DVD par morceaux de 64 Ko, c'était attendre un demi-tour
    /// de plateau deux cent mille fois.
    let writeRequestSectors: Int

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
                              writeRequestSectors: 512)
        case 2001...2005:
            return InstallEra(name: "Windows XP", think: ThinkModel(perFile: 0.012, perMegabyte: 0.05),
                              flush: .every(seconds: 1), journaled: spec.fileSystem.type == .ntfs,
                              floppySwap: 6, detection: 8, configuration: 10, restartPrompt: 2,
                              writeRequestSectors: 1_024)
        default:
            return InstallEra(name: "Windows Vista", think: ThinkModel(perFile: 0.006, perMegabyte: 0.03),
                              flush: .every(seconds: 1), journaled: spec.fileSystem.type == .ntfs,
                              floppySwap: 6, detection: 6, configuration: 12, restartPrompt: 2,
                              writeRequestSectors: 2_048)
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
                    descriptors.append(PhaseDescriptor(id: "step-\(index)", label: "Fichier d'échange",
                                                       detail: "\(size) réservés d'un seul tenant"))
                }
            case .system, .application:
                copy.append(descriptors.count)
                var detail = "\(files) fichiers, \(size), depuis \(step.style.label(bytes: ByteCount(catalog.bytes[index])))"
                if let extraction = step.style.extraction {
                    detail += " · archives extraites dans \(extraction.directory)"
                }
                descriptors.append(PhaseDescriptor(
                    id: "step-\(index)",
                    label: step.kind == .system ? "Copie de \(step.displayName)"
                                                : "Installation de \(step.displayName)",
                    detail: detail))
            }

            if step.style.reboots > 0 {
                reboot.append(descriptors.count)
                let count = step.style.reboots
                descriptors.append(PhaseDescriptor(
                    id: "reboot-\(index)",
                    label: step.kind == .system ? "Redémarrages et configuration" : "Redémarrage",
                    detail: count > 1 ? "\(count) redémarrages" : "Un redémarrage"))
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
        private var cabinetCursor = (extent: 0, offset: UInt32(0))
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
            flushMetadata(force: true)
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

        private mutating func writeData(of record: FileRecord, compressed: Bool) {
            var remaining = partition.clusters(forBytes: max(Int(record.logicalSize), 1))
            let perRequest = UInt32(max(era.writeRequestSectors / partition.clusterSectors, 1))
            for extent in record.extents {
                var offset: UInt32 = 0
                while offset < extent.length && remaining > 0 {
                    let clusters = min(extent.length - offset, perRequest, UInt32(remaining))
                    let bytes = Int(clusters) * partition.clusterSectors * DriveGeometry.bytesPerSector
                    pendingThink += sourceTime(bytes: min(bytes, Int(record.logicalSize)),
                                               compressed: compressed)
                    let cluster = Int(extent.start + offset)
                    emit(.writeExtent, lba: partition.lba(ofCluster: cluster),
                         sectors: Int(clusters) * partition.clusterSectors,
                         isWrite: true, cluster: cluster)
                    offset += clusters
                    remaining -= Int(clusters)
                }
                if remaining == 0 { break }
            }
        }

        /// Relit un morceau d'archive, là où l'installeur en était.
        private mutating func readCabinet(bytes: Int) {
            guard !cabinets.isEmpty else { return }
            var clusters = UInt32(max(partition.clusters(forBytes: max(bytes, 1)), 1))
            let perRequest = UInt32(max(maxRequestSectors / partition.clusterSectors, 1))
            var guardSteps = 0
            while clusters > 0, guardSteps < 64 {
                guardSteps += 1
                if cabinetCursor.extent >= cabinets.count { cabinetCursor = (0, 0) }
                let extent = cabinets[cabinetCursor.extent]
                let take = min(extent.length - cabinetCursor.offset, clusters, perRequest)
                let cluster = Int(extent.start + cabinetCursor.offset)
                emit(.readExtent, lba: partition.lba(ofCluster: cluster),
                     sectors: Int(take) * partition.clusterSectors, isWrite: false, cluster: cluster)
                plan.temporaryBytesRead += Int(take) * partition.clusterSectors * DriveGeometry.bytesPerSector
                clusters -= take
                cabinetCursor.offset += take
                if cabinetCursor.offset >= extent.length {
                    cabinetCursor = (cabinetCursor.extent + 1, 0)
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
                    readWhole(record, isWrite: true)
                    rewrote = true
                }
            }
            if rewrote { plan.settingsRewrites += 1 }
        }

        private mutating func readWhole(_ record: FileRecord, isWrite: Bool) {
            var remaining = partition.clusters(forBytes: max(Int(record.logicalSize), 1))
            let perRequest = UInt32(max(maxRequestSectors / partition.clusterSectors, 1))
            for extent in record.extents {
                var offset: UInt32 = 0
                while offset < extent.length && remaining > 0 {
                    let clusters = min(extent.length - offset, perRequest, UInt32(remaining))
                    let cluster = Int(extent.start + offset)
                    emit(isWrite ? .metadata : .readExtent, lba: partition.lba(ofCluster: cluster),
                         sectors: Int(clusters) * partition.clusterSectors,
                         isWrite: isWrite, cluster: cluster)
                    offset += clusters
                    remaining -= Int(clusters)
                }
                if remaining == 0 { break }
            }
        }

        // MARK: Redémarrages

        /// Un démarrage à chaud sur ce qui est posé jusqu'ici. Le plateau ne
        /// s'arrête pas : seul le POST impose son silence.
        private mutating func reboot() {
            flushMetadata(force: true)
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
                pendingThink += request.thinkTime
                let offset = request.lba - partition.dataStartLBA
                let cluster = offset >= 0 ? offset / partition.clusterSectors : nil
                emit(request.isWrite ? .metadata : .scan, lba: request.lba,
                     sectors: request.sectorCount, isWrite: request.isWrite, cluster: cluster)
            }
            pendingThink += boot.tail
            plan.reboots += 1
        }

        // MARK: Métadonnées

        private mutating func markDirty(_ record: FileRecord) {
            let rank = ranks[record.id] ?? 16
            let clusters = record.extents.isEmpty ? [0] : record.extents.map { Int($0.start) }
            // Le répertoire tel qu'il est au soir de l'installation : il a pu
            // grandir depuis ce fichier, mais il n'a pas bougé.
            let directories = installed.disk.catalog.directories
            let entry = partition.entrySector(inDirectory: directories.indices.contains(Int(record.directory))
                                                  ? directories[Int(record.directory)] : nil)
            for cluster in clusters {
                for access in partition.commitAccesses(forCluster: cluster, fileIndex: rank,
                                                       entrySector: entry,
                                                       validation: nil) {
                    dirty[access.lba] = max(dirty[access.lba] ?? 0, access.sectors)
                }
            }
        }

        private mutating func flushMetadata(force: Bool) {
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

        private mutating func emit(_ kind: DiskOperation.Kind, lba: Int, sectors: Int,
                                   isWrite: Bool, cluster: Int?) {
            let start = sink.mutationMark
            for mutation in pendingMutations { sink.record(mutation) }
            let count = Int32(pendingMutations.count)
            pendingMutations.removeAll(keepingCapacity: true)

            sink.progress = min(Double(bytesPlaced) / Double(totalBytes), 1)
            sink.moves = MoveCount(filesMoved: plan.filesWritten, evacuations: 0)
            sink.emit(DiskOperation(kind: kind, phase: phase, lba: lba, sectors: sectors,
                                    isWrite: isWrite, issueTime: 0, cluster: cluster,
                                    mutationStart: start, mutationCount: count,
                                    thinkTime: pendingThink))
            plan.thinkSeconds += pendingThink
            clock += pendingThink
                + Double(sectors * DriveGeometry.bytesPerSector) / diskBytesPerSecond
                + 0.012
            pendingThink = 0
        }
    }
}
