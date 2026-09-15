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
    case metadata           // FAT, MFT, répertoires

    /// Où le système de fichiers doit essayer de le poser.
    public var hint: AllocationHint {
        switch self {
        case .systemCore:            return .system
        case .swap:                  return .reservedContiguous
        case .temporary, .cache:     return .temporary
        case .buildArtifact:         return .temporary
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
                createdDay: UInt32 = 0) {
        self.entry = entry
        self.name = name
        self.directory = directory
        self.category = category
        self.pattern = pattern
        self.createdDay = createdDay
        self.modifiedDay = createdDay
    }
}

/// Répertoire : un nom, un parent, et l'ordre dans lequel il a été rencontré.
public struct DirectoryRecord: Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var parent: UInt32?
    /// Rang de création — c'est l'ordre des entrées dans le répertoire parent,
    /// et donc l'ordre dans lequel un défragmenteur d'époque parcourra
    /// l'arborescence, faute d'en connaître un autre.
    public var sequence: UInt32
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
