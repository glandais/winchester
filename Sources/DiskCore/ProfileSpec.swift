import Foundation

/// Date civile réduite à ce dont le noyau a besoin : de quoi compter des jours.
///
/// Ni `Date`, ni `Calendar`, ni `DateFormatter` : le calendrier grégorien tient
/// en quinze lignes, il est identique sur toutes les plateformes, et il ne
/// dépend d'aucun fuseau horaire ni d'aucune locale — trois sources
/// d'indéterminisme dont la génération d'un disque se passe très bien.
public struct CivilDate: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {

    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Décode `"1996-03-01"`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Jour julien modifié, algorithme de Howard Hinnant : une multiplication
    /// et quelques divisions, exactes en entiers.
    public var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthTerm = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthTerm + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Nombre de jours jusqu'à une autre date, négatif si elle est antérieure.
    public func days(until other: CivilDate) -> Int {
        other.dayNumber - dayNumber
    }

    public func adding(days: Int) -> CivilDate {
        CivilDate.from(dayNumber: dayNumber + days)
    }

    public static func from(dayNumber: Int) -> CivilDate {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let y = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthTerm = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthTerm + 2) / 5 + 1
        let month = monthTerm < 10 ? monthTerm + 3 : monthTerm - 9
        return CivilDate(year: month <= 2 ? y + 1 : y, month: month, day: day)
    }

    public static func < (lhs: CivilDate, rhs: CivilDate) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }

    // Sérialisé comme une chaîne, pas comme un objet à trois champs.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = CivilDate(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "date illisible : \(text)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Description d'un scénario

public struct DiskSpec: Sendable, Codable {
    public var sizeMB: UInt64
    public var rpm: Int
    public var averageSeekMs: Double
    /// Durée d'un seek d'une piste. Omise, elle est celle des disques de
    /// l'année du scénario : c'est une donnée de fiche comme le seek moyen, et
    /// elle ne s'en déduit pas — le rapport des deux a changé du tout au tout
    /// entre 1993 et 2003.
    public var trackToTrackMs: Double?
    /// Géométrie zonée. Toujours vraie sur un disque à plateaux ; le drapeau
    /// n'existe que pour pouvoir l'éteindre et entendre la différence.
    public var zbr: Bool

    public init(sizeMB: UInt64, rpm: Int, averageSeekMs: Double,
                trackToTrackMs: Double? = nil, zbr: Bool = true) {
        self.sizeMB = sizeMB
        self.rpm = rpm
        self.averageSeekMs = averageSeekMs
        self.trackToTrackMs = trackToTrackMs
        self.zbr = zbr
    }

    public var sizeBytes: UInt64 { sizeMB * 1_024 * 1_024 }
}

public enum FileSystemKind: String, Sendable, Codable {
    case fat16
    /// FAT16 servi par VFAT : même format, stratégie de FAT32.
    case vfat
    case fat32
    case ntfs
}

public struct FileSystemSpec: Sendable, Codable {
    public var type: FileSystemKind
    /// Taille de cluster. Omise, elle est déduite comme l'aurait fait `FORMAT`.
    public var clusterKB: UInt32?

    public init(type: FileSystemKind, clusterKB: UInt32? = nil) {
        self.type = type
        self.clusterKB = clusterKB
    }
}

public struct TimelineSpec: Sendable, Codable {
    public var start: CivilDate
    public var end: CivilDate

    public init(start: CivilDate, end: CivilDate) {
        self.start = start
        self.end = end
    }

    public var dayCount: UInt32 {
        UInt32(max(start.days(until: end), 1))
    }
}

/// Intensités d'activité. Tout est exprimé en **fréquence** et en **volume**,
/// jamais en fragmentation : ce que ces chiffres produisent sur le disque
/// dépend entièrement du format et de l'allocateur.
public struct ActivitySpec: Sendable, Codable {

    public struct Build: Sendable, Codable {
        public var perDay: Double
        public var objectFiles: Int
        public var pchMB: UInt64
        public init(perDay: Double, objectFiles: Int, pchMB: UInt64) {
            self.perDay = perDay
            self.objectFiles = objectFiles
            self.pchMB = pchMB
        }
    }

    public struct Browse: Sendable, Codable {
        public var perDay: Double
        public var pagesPerSession: Int
        public init(perDay: Double, pagesPerSession: Int) {
            self.perDay = perDay
            self.pagesPerSession = pagesPerSession
        }
    }

    public struct Office: Sendable, Codable {
        /// Documents créés par semaine.
        public var newDocumentsPerWeek: Double
        /// Enregistrements par document et par semaine — le motif de Word, et
        /// donc le vrai fragmenteur d'un poste de bureau.
        public var savesPerDocumentPerWeek: Double
        public init(newDocumentsPerWeek: Double, savesPerDocumentPerWeek: Double) {
            self.newDocumentsPerWeek = newDocumentsPerWeek
            self.savesPerDocumentPerWeek = savesPerDocumentPerWeek
        }
    }

    public struct Media: Sendable, Codable {
        /// Fichiers importés par semaine — MP3 rippés, photos, vidéos.
        public var filesPerWeek: Double
        public init(filesPerWeek: Double) { self.filesPerWeek = filesPerWeek }
    }

    public struct Download: Sendable, Codable {
        public var perWeek: Double
        /// Archives en parties de taille fixe, extraites puis supprimées : la
        /// signature visuelle du téléchargeur.
        public var partMB: UInt64?
        public init(perWeek: Double, partMB: UInt64? = nil) {
            self.perWeek = perWeek
            self.partMB = partMB
        }
    }

    public struct Gaming: Sendable, Codable {
        /// Jeux installés sur la période — quelques centaines de mégaoctets
        /// écrits d'un coup depuis un CD.
        public var installsPerYear: Double
        /// Jeux désinstallés : ce sont eux qui laissent les grands trous.
        public var uninstallsPerYear: Double
        public var savesPerDay: Double
        public init(installsPerYear: Double, uninstallsPerYear: Double, savesPerDay: Double) {
            self.installsPerYear = installsPerYear
            self.uninstallsPerYear = uninstallsPerYear
            self.savesPerDay = savesPerDay
        }
    }

    /// Ce que l'utilisateur accumule et ne supprime jamais de lui-même :
    /// archives, images de CD, sauvegardes, bibliothèque qui grossit. Exprimé
    /// en gigaoctets par an — un débit d'usage, pas un taux de remplissage
    /// visé. Ce que ça donne à l'arrivée dépend de la taille du disque, et si
    /// celui-ci sature, l'utilisateur fait le ménage.
    public struct Hoarding: Sendable, Codable {
        public var gigabytesPerYear: Double
        /// Taux de remplissage à partir duquel l'utilisateur consent à faire du
        /// ménage. C'est un trait de caractère, pas un objectif : certains
        /// effacent dès qu'ils passent 85 %, d'autres vivent avec un disque à
        /// 99 % et un message d'avertissement permanent. La différence est
        /// énorme sur le disque — tant qu'on efface, on rouvre de grands blocs
        /// contigus où le reste ira tenir ; quand on n'efface plus, il ne reste
        /// que des miettes et tout ce qu'on écrit part en morceaux.
        public var tidiesUpAt: Double?

        public init(gigabytesPerYear: Double, tidiesUpAt: Double? = nil) {
            self.gigabytesPerYear = gigabytesPerYear
            self.tidiesUpAt = tidiesUpAt
        }
    }

    /// Mises à jour et réinstallations. Un correctif, un service pack, un
    /// pilote remplacé : le fichier est supprimé et réécrit — donc replacé là
    /// où il y a de la place, c'est-à-dire dans les trous. C'est le mécanisme
    /// qui fragmente la population la plus nombreuse d'un volume, celle des
    /// fichiers système, et il ne concerne pas du tout les mêmes fichiers selon
    /// l'époque : Windows 95 recevait deux correctifs par an, XP en recevait un
    /// par mois.
    public struct Maintenance: Sendable, Codable {
        /// Vagues de mise à jour par an.
        public var updatesPerYear: Double
        /// Fichiers réécrits à chaque vague.
        public var filesPerUpdate: Int
        public init(updatesPerYear: Double, filesPerUpdate: Int) {
            self.updatesPerYear = updatesPerYear
            self.filesPerUpdate = filesPerUpdate
        }
    }

    public var maintenance: Maintenance?
    public var hoarding: Hoarding?
    public var build: Build?
    public var browse: Browse?
    public var office: Office?
    public var media: Media?
    public var download: Download?
    public var gaming: Gaming?

    public init(maintenance: Maintenance? = nil,
                hoarding: Hoarding? = nil,
                build: Build? = nil, browse: Browse? = nil, office: Office? = nil,
                media: Media? = nil, download: Download? = nil, gaming: Gaming? = nil) {
        self.maintenance = maintenance
        self.hoarding = hoarding
        self.build = build
        self.browse = browse
        self.office = office
        self.media = media
        self.download = download
        self.gaming = gaming
    }
}

/// Un scénario complet, tel qu'il est écrit dans le bundle.
///
/// On y trouve une époque, un matériel, un format, une durée et des intensités
/// d'usage. On n'y trouve **pas** de taux de fragmentation, ni de nombre
/// d'extents, ni de taux de remplissage visé : ce sont des résultats, et les
/// écrire ici reviendrait à décider d'avance de ce que la simulation doit
/// trouver.
public struct ProfileSpec: Sendable, Codable, Identifiable {

    public var id: String
    public var displayName: String
    public var summary: String?
    public var seed: UInt64
    public var disk: DiskSpec
    public var fileSystem: FileSystemSpec
    public var os: String
    public var timeline: TimelineSpec
    /// Applications installées, par identifiant de manifeste.
    public var installs: [String]
    /// Applications désinstallées en cours de route, et le jour où.
    public var uninstalls: [Uninstall]?
    public var activity: ActivitySpec
    /// Dates des passes de défragmentation lancées par l'utilisateur.
    public var defragRuns: [CivilDate]?

    public struct Uninstall: Sendable, Codable {
        public var app: String
        public var date: CivilDate
        public init(app: String, date: CivilDate) {
            self.app = app
            self.date = date
        }
    }

    public init(id: String,
                displayName: String,
                summary: String? = nil,
                seed: UInt64,
                disk: DiskSpec,
                fileSystem: FileSystemSpec,
                os: String,
                timeline: TimelineSpec,
                installs: [String],
                uninstalls: [Uninstall]? = nil,
                activity: ActivitySpec,
                defragRuns: [CivilDate]? = nil) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.seed = seed
        self.disk = disk
        self.fileSystem = fileSystem
        self.os = os
        self.timeline = timeline
        self.installs = installs
        self.uninstalls = uninstalls
        self.activity = activity
        self.defragRuns = defragRuns
    }

    // MARK: - Décodage

    public static func decode(from data: Data) throws -> ProfileSpec {
        try JSONDecoder().decode(ProfileSpec.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Profil de système de fichiers correspondant, avec la taille de cluster
    /// qu'aurait choisie l'outil de formatage de l'époque si elle n'est pas
    /// imposée.
    public func resolvedFileSystem() -> any FileSystemProfile {
        switch fileSystem.type {
        case .fat16, .vfat:
            return fileSystem.clusterKB.map { FAT16Profile(clusterKB: $0) }
                ?? FAT16Profile.forVolume(bytes: disk.sizeBytes)
        case .fat32:
            return FAT32Profile(clusterKB: fileSystem.clusterKB ?? 4)
        case .ntfs:
            return NTFSProfile(clusterKB: fileSystem.clusterKB ?? 4)
        }
    }

    public var clusterCount: UInt32 {
        let profile = resolvedFileSystem()
        let count = disk.sizeBytes / UInt64(profile.clusterBytes)
        return UInt32(min(count, UInt64(profile.maxClusterCount)))
    }
}
