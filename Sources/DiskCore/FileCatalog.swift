import Foundation

/// Nature d'un fichier, du point de vue de ce qui le fait vivre.
///
/// Ce n'est pas une classification par extension : c'est une classification par
/// **comportement**. Deux fichiers de même taille dont l'un est écrit une fois
/// depuis un CD et l'autre réenregistré cent fois ne produisent pas du tout le
/// même disque, et c'est cette différence-là qu'il faut pouvoir exprimer.
public enum FileCategory: UInt8, Sendable, CaseIterable, Codable {
    case systemCore = 0     // noyau, pilotes, DLL du système
    case application        // exécutables et bibliothèques installés
    case source             // .c, .h, .pas — petits, nombreux, réécrits
    case buildArtifact      // .obj, .pch, exécutables de sortie
    case document           // .doc, .xls, .txt
    case media              // MP3, JPEG, DivX
    case gameAsset          // .pak, .wad — énormes, écrits une fois
    case archive            // .zip, .rar, aide en ligne
    case cache              // Temporary Internet Files, index.dat
    case temporary          // ~WRD0001.TMP, fichiers de travail
    case swap               // WIN386.SWP, pagefile.sys, hiberfil.sys
    case metadata           // FAT, MFT
    /// Un répertoire : sur FAT un fichier comme les autres, qui porte les
    /// entrées de ses enfants ; sur NTFS l'index de ses noms. N'est jamais la
    /// catégorie d'un `FileRecord` — seulement celle des clusters d'un
    /// `DirectoryRecord`.
    case directory

    /// Où le système de fichiers doit essayer de le poser.
    public var hint: AllocationHint {
        switch self {
        case .systemCore:            return .system
        case .swap:                  return .reservedContiguous
        default:                     return .normal
        }
    }
}

/// Un fichier du catalogue : ce que l'allocateur en sait, plus ce qu'il faut
/// pour le nommer, le dater et le ranger dans une arborescence.
public struct FileRecord: Sendable, Identifiable {

    public var entry: FileEntry
    /// Nom seul — le chemin complet se reconstruit en remontant les répertoires.
    /// Une chaîne par fichier et non un chemin complet : sur un volume de 2007,
    /// répéter `C:\Windows\winsxs\…` cent mille fois coûterait plus cher que
    /// tout le reste du catalogue réuni.
    public var name: String
    public var directory: UInt32
    public var category: FileCategory
    public var pattern: WritePattern
    /// Jour de création, compté depuis le début du scénario.
    public var createdDay: UInt32
    public var modifiedDay: UInt32
    /// Son enregistrement dans la MFT, quand le système de fichiers le
    /// désigne (NTFS de XP : `Allocator.takeRecord`) ; `nil` ailleurs, où le
    /// rang de création en tient lieu.
    public var mftRecord: UInt32?
    /// Comment son programme le fait grandir (`FileSpec.growth`) : un ajout,
    /// un réenregistrement le reprennent.
    public var growth: StreamedGrowth

    public var id: UInt32 { entry.id }
    public var logicalSize: UInt64 { entry.logicalSize }
    public var extents: [Extent] { entry.extents }
    public var isResident: Bool { entry.isResident }
    public var isFragmented: Bool { entry.isFragmented }

    public init(entry: FileEntry,
                name: String,
                directory: UInt32,
                category: FileCategory,
                pattern: WritePattern = .createOnce,
                createdDay: UInt32 = 0,
                growth: StreamedGrowth = .buffered) {
        self.entry = entry
        self.name = name
        self.directory = directory
        self.category = category
        self.pattern = pattern
        self.createdDay = createdDay
        self.growth = growth
        self.modifiedDay = createdDay
    }
}

/// Répertoire : un nom, un parent, l'ordre dans lequel il a été rencontré —
/// et la place qu'il occupe.
///
/// Un répertoire n'est pas qu'un préfixe de chemin. Sur FAT, c'est un fichier,
/// alloué comme les autres, qui porte les entrées de 32 octets de ses enfants
/// et grandit d'un cluster quand elles débordent ; sur NTFS, c'est un
/// enregistrement de MFT dont l'index des noms quitte l'enregistrement quand il
/// grossit, et prend alors des clusters par tampons de 4 Ko. Dans les deux cas
/// il obtient sa place à des moments éloignés : il se fragmente, et chaque
/// parcours le paie (`Simulator`, `DirectoryFormat`).
public struct DirectoryRecord: Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var parent: UInt32?
    /// Rang de création — c'est l'ordre des entrées dans le répertoire parent,
    /// et donc l'ordre dans lequel un défragmenteur d'époque parcourra
    /// l'arborescence, faute d'en connaître un autre.
    public var sequence: UInt32
    /// Ce que le répertoire occupe. Vide tant qu'il n'existe pas sur le disque,
    /// vide aussi s'il tient là où le format le loge sans cluster — la racine
    /// d'un FAT16, l'index d'un petit répertoire NTFS.
    public var entry: FileEntry
    /// Octets d'entrées en service : celles de ses enfants vivants, plus `.`
    /// et `..` sur FAT.
    public var entryBytes: UInt64 = 0
    /// Le plus haut que `entryBytes` ait jamais atteint. Un répertoire ne rend
    /// pas ses clusters : une entrée effacée est marquée libre et resservira,
    /// mais la chaîne ne raccourcit pas.
    public var peakEntryBytes: UInt64 = 0
    /// Octets d'entrées que sa place actuelle peut porter : au-delà, il
    /// grandit.
    public var capacityBytes: UInt64 = 0
    /// Le répertoire a-t-il été créé sur le disque ? Il l'est au moment où il
    /// reçoit son premier enfant — c'est là qu'un installeur ou un programme
    /// fait son `mkdir`.
    public var exists = false
    /// Son enregistrement dans la MFT, comme `FileRecord.mftRecord`.
    public var mftRecord: UInt32?

    public init(id: UInt32, name: String, parent: UInt32?, sequence: UInt32) {
        self.id = id
        self.name = name
        self.parent = parent
        self.sequence = sequence
        self.entry = FileEntry(id: id, logicalSize: 0)
    }

    public var extents: [Extent] { entry.extents }
}

/// Ce que coûte une entrée de répertoire, et comment un répertoire grandit —
/// une propriété du format **et** du pilote : le même FAT16 ne connaît pas les
/// noms longs sous MS-DOS, et les connaît sous VFAT.
public struct DirectoryFormat: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// Entrées de 32 octets. `longNames` : VFAT, qui ajoute au nom court une
        /// entrée par tranche de treize caractères du nom long.
        /// `fixedRoot` : la racine de FAT16 vit dans sa région à elle, avant
        /// les données, et ne prend aucun cluster.
        case fat(longNames: Bool, fixedRoot: Bool)
        /// L'index des noms d'un répertoire NTFS.
        case ntfs
    }

    public let kind: Kind
    /// Octets par cluster du volume.
    public let clusterBytes: UInt64
    /// Ce que l'index d'un répertoire NTFS peut occuper dans son enregistrement
    /// de MFT avant d'en sortir : la même place que les données d'un fichier
    /// résident, puisque c'est le même kilo-octet (`NTFSProfile`).
    public let residentBytes: UInt64

    public init(kind: Kind, clusterBytes: UInt64, residentBytes: UInt64 = 0) {
        self.kind = kind
        self.clusterBytes = clusterBytes
        self.residentBytes = residentBytes
    }

    /// Le pas de croissance : un cluster sur FAT, un tampon d'index de 4 Ko
    /// (`INDX`) sur NTFS, quelle que soit la taille de cluster.
    public var growthBytes: UInt64 {
        switch kind {
        case .fat:  return clusterBytes
        case .ntfs: return 4_096
        }
    }

    /// Octets de ce qu'un répertoire tout neuf contient déjà : `.` et `..` sur
    /// FAT, rien dans l'index d'un NTFS.
    public var initialBytes: UInt64 {
        if case .fat = kind { return 64 }
        return 0
    }

    /// La racine de ce format prend-elle des clusters ?
    public var rootTakesClusters: Bool {
        if case .fat(_, true) = kind { return false }
        return true
    }

    /// Ce que coûte le nom d'un fichier ou d'un sous-répertoire dans son
    /// répertoire.
    ///
    /// - FAT sous MS-DOS : une entrée de 32 octets, le nom est court ;
    /// - VFAT : l'entrée du nom court, plus une entrée par tranche de treize
    ///   caractères du nom long quand le nom n'est pas un nom court valide en
    ///   majuscules. `Rapport trimestriel 1996.doc` en coûte quatre ;
    /// - NTFS : une entrée d'index de 82 octets plus deux par caractère,
    ///   arrondie à huit, et une seconde pour le nom court que XP et Vista
    ///   génèrent par défaut quand le nom n'en est pas un.
    public func entryBytes(forName name: String) -> UInt64 {
        switch kind {
        case let .fat(longNames, _):
            guard longNames, !Self.isShortName(name, caseSensitive: true) else { return 32 }
            let characters = UInt64(name.utf16.count)
            return 32 * (1 + (characters + 12) / 13)
        case .ntfs:
            func indexEntry(_ characters: Int) -> UInt64 { (82 + 2 * UInt64(characters) + 7) / 8 * 8 }
            let long = indexEntry(name.utf16.count)
            return Self.isShortName(name, caseSensitive: false) ? long : long + indexEntry(12)
        }
    }

    /// Un nom court 8.3 valide : huit caractères au plus, un point, trois au
    /// plus, pris dans le jeu de MS-DOS. Sous VFAT, un nom qui a des
    /// minuscules en a besoin d'un long pour garder sa casse ; NTFS la garde
    /// sans cela.
    public static func isShortName(_ name: String, caseSensitive: Bool) -> Bool {
        // Un seul passage sur les octets, sans découper la chaîne : la
        // question se pose à chaque création et à chaque effacement.
        var base = 0
        var extension_ = 0
        var dots = 0
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "."):
                dots += 1
                if dots > 1 || base == 0 { return false }
                continue
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                break
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                if caseSensitive { return false }
            case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
                 UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"),
                 UInt8(ascii: "-"), UInt8(ascii: "@"), UInt8(ascii: "^"), UInt8(ascii: "_"),
                 UInt8(ascii: "`"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "~"):
                break
            default:
                return false
            }
            if dots == 0 { base += 1 } else { extension_ += 1 }
            if base > 8 || extension_ > 3 { return false }
        }
        return base > 0 && (dots == 0 || extension_ > 0)
    }

    /// Le cluster d'un répertoire qui porte l'octet `offset` de ses entrées :
    /// son rang dans la chaîne, dans l'ordre du répertoire.
    public func clusterIndex(ofEntryAt offset: UInt64) -> UInt32 {
        UInt32(offset / clusterBytes)
    }

    /// Clusters qu'occupe un répertoire dont les entrées ont atteint `bytes`.
    public func clusters(forEntryBytes bytes: UInt64) -> UInt32 {
        guard bytes > 0 else { return 0 }
        if case .ntfs = kind, bytes <= residentBytes { return 0 }
        let units = (bytes + growthBytes - 1) / growthBytes
        return UInt32((units * growthBytes + clusterBytes - 1) / clusterBytes)
    }
}

/// Un élément de l'arborescence, dans l'ordre où on la parcourt.
public enum TreeItem: Sendable {
    case directory(DirectoryRecord)
    case file(FileRecord)
}

/// Arborescence et fichiers d'un volume.
///
/// Les fichiers vivent dans un tableau dense indexé par identifiant, et les
/// identifiants ne sont jamais réutilisés : un fichier supprimé laisse un trou
/// dans le tableau. C'est ce qui garantit qu'aucun parcours ne dépend de l'ordre
/// d'itération d'une table de hachage — la condition du déterminisme.
public struct FileCatalog: Sendable {

    private var slots: [FileRecord?] = []
    public private(set) var directories: [DirectoryRecord] = []
    public private(set) var liveCount: Int = 0
    private var nextID: UInt32 = 0
    private var directoryIndex: [String: UInt32] = [:]

    public init() {
        directories.append(DirectoryRecord(id: 0, name: "", parent: nil, sequence: 0))
        directoryIndex["\\"] = 0
    }

    public var rootDirectory: UInt32 { 0 }

    /// L'identifiant d'un répertoire quand il côtoie des fichiers dans une
    /// même liste — les éléments d'une défragmentation, les places qu'elle
    /// rend. Les deux sont comptés à part dans le catalogue ; le bit de poids
    /// fort les sépare.
    public static func itemID(ofDirectory id: UInt32) -> UInt32 { 0x8000_0000 | id }

    /// Le répertoire que désigne cet identifiant d'élément, s'il en désigne un.
    public static func directory(ofItem id: UInt32) -> UInt32? {
        id & 0x8000_0000 != 0 ? id & 0x7FFF_FFFF : nil
    }

    // MARK: - Répertoires

    /// Crée le répertoire désigné par un chemin, et tous ses parents.
    @discardableResult
    public mutating func makeDirectory(path: String) -> UInt32 {
        let normalized = Self.normalize(path)
        if let existing = directoryIndex[normalized] { return existing }

        let components = normalized.split(separator: "\\", omittingEmptySubsequences: true)
        var parent: UInt32 = 0
        var walked = "\\"

        for component in components {
            walked = walked == "\\" ? "\\\(component)" : "\(walked)\\\(component)"
            if let existing = directoryIndex[walked] {
                parent = existing
                continue
            }
            let id = UInt32(directories.count)
            directories.append(DirectoryRecord(id: id,
                                               name: String(component),
                                               parent: parent,
                                               sequence: id))
            directoryIndex[walked] = id
            parent = id
        }
        return parent
    }

    public func path(ofDirectory id: UInt32) -> String {
        var components: [String] = []
        var current: UInt32? = id
        while let index = current, index != 0 {
            let directory = directories[Int(index)]
            components.append(directory.name)
            current = directory.parent
        }
        return components.isEmpty ? "\\" : "\\" + components.reversed().joined(separator: "\\")
    }

    public func path(of file: FileRecord) -> String {
        let directory = path(ofDirectory: file.directory)
        return directory == "\\" ? "\\\(file.name)" : "\(directory)\\\(file.name)"
    }

    private static func normalize(_ path: String) -> String {
        let trimmed = path.hasSuffix("\\") ? String(path.dropLast()) : path
        return trimmed.isEmpty ? "\\" : (trimmed.hasPrefix("\\") ? trimmed : "\\" + trimmed)
    }

    // MARK: - Fichiers

    /// Modifie un répertoire en place.
    public mutating func updateDirectory<T>(_ id: UInt32, _ body: (inout DirectoryRecord) -> T) -> T {
        body(&directories[Int(id)])
    }

    public mutating func reserveCapacity(_ count: Int) {
        slots.reserveCapacity(count)
    }

    /// Fait de la place pour un identifiant décidé ailleurs. C'est le cas
    /// normal : les identifiants sont attribués par la timeline, avant toute
    /// allocation, pour qu'une même histoire puisse être rejouée sur plusieurs
    /// systèmes de fichiers et donner les mêmes fichiers.
    public mutating func reserve(id: UInt32) {
        let needed = Int(id) + 1
        if slots.count < needed {
            slots.append(contentsOf: repeatElement(nil, count: needed - slots.count))
        }
        nextID = max(nextID, id + 1)
    }

    /// Réserve un identifiant. Les identifiants sont attribués dans l'ordre de
    /// création et jamais recyclés : c'est aussi le rang de l'entrée dans son
    /// répertoire.
    public mutating func allocateID() -> UInt32 {
        let id = nextID
        nextID += 1
        slots.append(nil)
        return id
    }

    public mutating func insert(_ record: FileRecord) {
        let index = Int(record.id)
        precondition(index < slots.count, "identifiant \(record.id) non réservé")
        if slots[index] == nil { liveCount += 1 }
        slots[index] = record
    }

    public mutating func remove(_ id: UInt32) -> FileRecord? {
        let index = Int(id)
        guard index < slots.count, let record = slots[index] else { return nil }
        slots[index] = nil
        liveCount -= 1
        return record
    }

    public subscript(id: UInt32) -> FileRecord? {
        get {
            let index = Int(id)
            return index < slots.count ? slots[index] : nil
        }
        set {
            let index = Int(id)
            guard index < slots.count else { return }
            if slots[index] == nil, newValue != nil { liveCount += 1 }
            if slots[index] != nil, newValue == nil { liveCount -= 1 }
            slots[index] = newValue
        }
    }

    public func contains(_ id: UInt32) -> Bool { self[id] != nil }

    /// Tous les fichiers vivants, dans l'ordre de leur création. Ordre stable,
    /// reproductible, et c'est le seul par lequel passent les mesures.
    public var files: [FileRecord] {
        slots.compactMap { $0 }
    }

    /// Identifiants vivants, dans l'ordre de création.
    public var liveIDs: [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(liveCount)
        for slot in slots where slot != nil { result.append(slot!.id) }
        return result
    }

    /// Fichiers rangés dans l'ordre où un parcours de l'arborescence les
    /// rencontre : chaque répertoire dans l'ordre de sa création, et dans
    /// chacun les fichiers dans l'ordre de leur entrée. C'est le seul ordre
    /// dont disposait un défragmenteur d'époque.
    public func directoryWalkOrder() -> [FileRecord] {
        var byDirectory: [[FileRecord]] = Array(repeating: [], count: directories.count)
        for slot in slots {
            guard let record = slot else { continue }
            byDirectory[Int(record.directory)].append(record)
        }
        var result: [FileRecord] = []
        result.reserveCapacity(liveCount)
        for directory in directories.indices {
            result.append(contentsOf: byDirectory[directory])
        }
        return result
    }

    /// La même chose, répertoires compris : chaque répertoire juste avant les
    /// fichiers qu'il contient. C'est ce que rencontre un défragmenteur qui
    /// lit l'arborescence — il ouvre un répertoire, puis ce qu'il y trouve.
    /// Les répertoires qui n'existent pas sur le disque n'y figurent pas.
    public func treeWalkOrder() -> [TreeItem] {
        var byDirectory: [[FileRecord]] = Array(repeating: [], count: directories.count)
        for slot in slots {
            guard let record = slot else { continue }
            byDirectory[Int(record.directory)].append(record)
        }
        var result: [TreeItem] = []
        result.reserveCapacity(liveCount + directories.count)
        for directory in directories.indices {
            if directories[directory].exists { result.append(.directory(directories[directory])) }
            for record in byDirectory[directory] { result.append(.file(record)) }
        }
        return result
    }

    /// Où tombe l'entrée de chaque nom dans son répertoire, en octets depuis
    /// le début de celui-ci : c'est ce qui dit quel cluster du répertoire un
    /// pilote doit lire pour trouver un fichier, et lequel il réécrit quand le
    /// fichier change de place.
    ///
    /// L'ordre est celui de la création, à une approximation près : les
    /// sous-répertoires d'abord, puisqu'un installeur crée l'arborescence avant
    /// d'y copier, puis les fichiers vivants dans l'ordre de leurs
    /// identifiants. Les entrées des fichiers effacés, qui laissent des places
    /// libres au milieu, ne sont pas comptées.
    public func entryOffsets(format: DirectoryFormat) -> (files: [UInt32: UInt64], directories: [UInt64]) {
        var next = directories.map { $0.parent == nil ? UInt64(0) : format.initialBytes }
        var ofDirectory = [UInt64](repeating: 0, count: directories.count)
        for directory in directories {
            guard let parent = directory.parent else { continue }
            ofDirectory[Int(directory.id)] = next[Int(parent)]
            next[Int(parent)] += format.entryBytes(forName: directory.name)
        }
        var ofFile: [UInt32: UInt64] = [:]
        ofFile.reserveCapacity(liveCount)
        for slot in slots {
            guard let record = slot else { continue }
            ofFile[record.id] = next[Int(record.directory)]
            next[Int(record.directory)] += format.entryBytes(forName: record.name)
        }
        return (ofFile, ofDirectory)
    }

    /// Reconstruit le lien cluster → fichier. Coûteux en mémoire — quatre
    /// octets par cluster — et c'est pour cela qu'il n'est pas tenu à jour en
    /// permanence : seul un défragmenteur en a besoin, et seulement sur les
    /// volumes qu'on lui donne à défragmenter.
    public func ownerMap(clusterCount: UInt32) -> [UInt32] {
        var owner = [UInt32](repeating: .max, count: Int(clusterCount))
        for slot in slots {
            guard let record = slot else { continue }
            for extent in record.extents {
                let end = min(extent.end, clusterCount)
                guard extent.start < end else { continue }
                for cluster in extent.start..<end { owner[Int(cluster)] = record.id }
            }
        }
        return owner
    }

    /// Carte des catégories, une par cluster : ce que la vue consomme pour
    /// colorier la grille.
    public func categoryMap(clusterCount: UInt32, free: UInt8 = 0) -> [UInt8] {
        var map = [UInt8](repeating: free, count: Int(clusterCount))
        for directory in directories {
            for extent in directory.extents {
                let end = min(extent.end, clusterCount)
                guard extent.start < end else { continue }
                for cluster in extent.start..<end { map[Int(cluster)] = FileCategory.directory.rawValue }
            }
        }
        for slot in slots {
            guard let record = slot else { continue }
            let value = record.category.rawValue
            for extent in record.extents {
                let end = min(extent.end, clusterCount)
                guard extent.start < end else { continue }
                for cluster in extent.start..<end { map[Int(cluster)] = value }
            }
        }
        return map
    }
}
