import Foundation

// MARK: - La mise en place d'un logiciel

/// Comment un logiciel arrivait sur le disque, tel que son époque l'imposait.
///
/// Le manifeste dit **ce qui** est posé ; ceci dit **d'où** et **comment**. Un
/// Windows 3.1 arrivait sur une pile de disquettes et s'écrivait fichier par
/// fichier, un Office 97 décompressait d'abord son moteur d'installation dans
/// `\WINDOWS\TEMP`, un Windows 98 posait `WININST0.400` avant de copier quoi que
/// ce soit. Ce sont ces gestes-là — et non une durée décrétée — qui donnent son
/// rythme à une installation rejouée.
public struct SetupStyle: Sendable, Equatable {

    public enum Medium: String, Sendable {
        /// 1,44 Mo par disquette, lus à quelques dizaines de ko/s.
        case floppy
        case cdrom
        case dvd
    }

    /// Les fichiers que l'installeur extrait sur le disque avant de copier, et
    /// qu'il efface à la fin.
    public struct Extraction: Sendable, Equatable {

        public enum Use: Sendable, Equatable {
            /// Le programme d'installation lui-même : lu au lancement, puis
            /// laissé là jusqu'au ménage. `WININST0.400`.
            case setupEngine
            /// Des archives d'où l'on tire chaque fichier : l'installeur lit un
            /// morceau d'archive, écrit le fichier qui en sort, et recommence.
            /// C'est le va-et-vient qui fait crépiter une installation.
            case cabinets
        }

        public var directory: String
        public var stem: String
        public var extension_: String
        public var fileCount: Int
        /// Octets extraits au total.
        public var bytes: ByteCount
        public var use: Use
    }

    /// Une ruche du registre, ou un fichier de réglages réécrit en bloc.
    public struct Hive: Sendable, Equatable {
        public var directory: String
        public var name: String
        public var bytes: ByteCount
    }

    public var medium: Medium
    /// Vitesse du lecteur en multiples de la simple vitesse : 150 ko/s pour un
    /// CD, 1 385 ko/s pour un DVD. Sans objet pour une disquette.
    public var speed: Int
    public var extraction: Extraction?
    /// Ruches posées par le système — vides pour une application, qui écrit
    /// dans celles du système.
    public var registry: [Hive]
    /// Redémarrages demandés à la fin de l'étape.
    public var reboots: Int

    /// Débit de lecture de la source, en octets par seconde.
    public var sourceBytesPerSecond: Double {
        switch medium {
        case .floppy: return 45_000
        case .cdrom:  return 150_000 * Double(max(speed, 1))
        case .dvd:    return 1_385_000 * Double(max(speed, 1))
        }
    }

    /// Le libellé d'écran : « CD-ROM 24x », « 11 disquettes ».
    public func label(bytes: ByteCount) -> String {
        switch medium {
        case .floppy:
            let disks = max(1, Int((Double(bytes) / SetupLibrary.floppyExpansion / 1_457_664).rounded(.up)))
            return "\(disks) disquette\(disks > 1 ? "s" : "")"
        case .cdrom:
            return "CD-ROM \(speed)x"
        case .dvd:
            return "DVD \(speed)x"
        }
    }
}

/// Les mises en place d'époque, en un seul endroit.
///
/// Les valeurs sont des ordres de grandeur, comme les manifestes : un lecteur
/// de CD est « 4x en 1995, 24x en 1998 », pas le modèle précis qu'avait telle
/// machine. Ce qui compte pour le disque, c'est que la source bride la copie, et
/// que ce bridage change d'un facteur dix entre 1995 et 2001.
public enum SetupLibrary {

    /// Ce que donne un octet compressé une fois extrait. Les fichiers `.EX_` de
    /// MS-DOS et les CAB de Windows tournaient autour de deux.
    public static let floppyExpansion = 1.9

    /// Les manifestes qui **sont** le système : ils s'installent en premier, ils
    /// posent les ruches, et on ne les « lance » pas au démarrage. Liste
    /// explicite plutôt que déduite de la présence de fichiers système —
    /// Internet Explorer 5 en posait autant qu'un pilote, et reste une
    /// application qu'on lance.
    public static let systemManifests: Set<String> = [
        "msdos-6", "win31", "win95", "win98se", "winxp", "vista",
    ]

    /// Vitesse du lecteur de CD d'une machine de l'année donnée.
    static func cdSpeed(year: Int) -> Int {
        switch year {
        case ..<1995: return 2
        case 1995:    return 4
        case 1996:    return 8
        case 1997:    return 16
        case 1998:    return 24
        case 1999:    return 32
        case 2000...2001: return 40
        default:      return 48
        }
    }

    /// La mise en place d'un manifeste sur une machine de l'année donnée.
    ///
    /// - Parameter systemFileSystem: le format du volume, qui décide où vit le
    ///   répertoire temporaire.
    public static func style(for manifest: AppManifest,
                             year: Int,
                             fileSystem: FileSystemKind) -> SetupStyle {
        let windowsDirectory = fileSystem == .ntfs && year >= 2007 ? "\\Windows" : "\\WINDOWS"

        switch manifest.id {
        case "msdos-6", "win31":
            // Trois disquettes pour MS-DOS, six pour Windows 3.1 : l'installeur
            // décompresse chaque fichier directement à sa place, sans rien
            // extraire à côté.
            return SetupStyle(medium: .floppy, speed: 0, extraction: nil, registry: [], reboots: 1)

        case "win95":
            return SetupStyle(
                medium: .cdrom, speed: cdSpeed(year: year),
                // L'assistant d'installation est extrait avant toute question.
                extraction: .init(directory: "\\WININST0.400", stem: "PRECOPY", extension_: "CAB",
                                  fileCount: 36, bytes: 3_600_000, use: .setupEngine),
                registry: [.init(directory: "\\WINDOWS", name: "SYSTEM.DAT", bytes: 1_100_000),
                           .init(directory: "\\WINDOWS", name: "USER.DAT", bytes: 220_000)],
                // Fin de la copie, puis fin de la détection du matériel.
                reboots: 2)

        case "win98se":
            return SetupStyle(
                medium: .cdrom, speed: cdSpeed(year: year),
                extraction: .init(directory: "\\WININST0.400", stem: "PRECOPY", extension_: "CAB",
                                  fileCount: 48, bytes: 5_800_000, use: .setupEngine),
                registry: [.init(directory: "\\WINDOWS", name: "SYSTEM.DAT", bytes: 2_400_000),
                           .init(directory: "\\WINDOWS", name: "USER.DAT", bytes: 380_000)],
                // Copie, matériel, puis « mise à jour des paramètres système ».
                reboots: 3)

        case "winxp":
            // Démarré depuis le CD : la phase texte copie directement dans
            // `\WINDOWS`, sans dossier d'extraction sur le disque cible.
            return SetupStyle(
                medium: .cdrom, speed: cdSpeed(year: year), extraction: nil,
                registry: [
                    .init(directory: "\\WINDOWS\\system32\\config", name: "SYSTEM", bytes: 3_200_000),
                    .init(directory: "\\WINDOWS\\system32\\config", name: "SOFTWARE", bytes: 11_000_000),
                    .init(directory: "\\WINDOWS\\system32\\config", name: "DEFAULT", bytes: 260_000),
                    .init(directory: "\\WINDOWS\\system32\\config", name: "SAM", bytes: 32_000),
                    .init(directory: "\\WINDOWS\\system32\\config", name: "SECURITY", bytes: 36_000),
                    .init(directory: "\\Documents and Settings\\Utilisateur", name: "NTUSER.DAT",
                          bytes: 900_000),
                ],
                // Fin de la phase texte, fin de la phase graphique.
                reboots: 2)

        case "vista":
            return SetupStyle(
                medium: .dvd, speed: 16, extraction: nil,
                registry: [
                    .init(directory: "\\Windows\\System32\\config", name: "SYSTEM", bytes: 9_500_000),
                    .init(directory: "\\Windows\\System32\\config", name: "SOFTWARE", bytes: 32_000_000),
                    .init(directory: "\\Windows\\System32\\config", name: "COMPONENTS", bytes: 18_000_000),
                    .init(directory: "\\Windows\\System32\\config", name: "DEFAULT", bytes: 260_000),
                    .init(directory: "\\Windows\\System32\\config", name: "SAM", bytes: 262_144),
                    .init(directory: "\\Windows\\System32\\config", name: "SECURITY", bytes: 262_144),
                    .init(directory: "\\Users\\Utilisateur", name: "NTUSER.DAT", bytes: 1_300_000),
                ],
                reboots: 3)

        default:
            // Une application d'avant le CD arrive sur disquettes et s'écrit à
            // sa place, comme le système de la même époque.
            if year < 1995 {
                return SetupStyle(medium: .floppy, speed: 0, extraction: nil, registry: [], reboots: 0)
            }
            // Sur CD : InstallShield ou ACME extraient leur moteur et leurs
            // archives dans le répertoire temporaire, de l'ordre du dixième de
            // ce qu'ils vont poser, et le vident à la fin.
            let bytes = min(max(ByteCount(Double(manifest.approximateBytes) * 0.10), 1_500_000),
                            60_000_000)
            let medium: SetupStyle.Medium = manifest.approximateBytes > 1_500_000_000 ? .dvd : .cdrom
            return SetupStyle(
                medium: medium,
                speed: medium == .dvd ? 16 : cdSpeed(year: year),
                extraction: .init(directory: "\(windowsDirectory)\\TEMP\\_ISTMP0.DIR",
                                  stem: "DATA", extension_: "CAB",
                                  fileCount: 8 + Int(bytes / 4_000_000),
                                  bytes: bytes, use: .cabinets),
                registry: [],
                // Un installeur qui remplace des DLL partagées ne peut pas le
                // faire tant qu'elles sont chargées : il demande de redémarrer.
                reboots: manifest.sharedLibraries.isEmpty ? 0 : 1)
        }
    }
}

// MARK: - Les étapes d'une installation

/// Une étape de l'installation : un logiciel, ou le fichier d'échange.
///
/// Le compilateur la décrit en identifiants au moment où il écrit l'histoire.
/// Sans elle, le jour 0 ne serait qu'une suite de créations anonymes : on ne
/// saurait plus quel fichier appartient à Office 97, ni lesquels sont les
/// archives que l'installeur va effacer.
public struct InstallStep: Sendable {

    public enum Kind: Sendable, Equatable {
        case system
        case application
        case swap
    }

    public var manifestID: String
    public var displayName: String
    public var kind: Kind
    public var style: SetupStyle
    /// Fichiers extraits avant la copie et effacés après, dans l'ordre.
    public var temporaryIDs: [UInt32]
    /// Fichiers posés pour de bon, dans l'ordre d'écriture : ceux du manifeste,
    /// les bibliothèques partagées, puis les ruches.
    public var fileIDs: [UInt32]
    /// Ruches et fichiers de réglages, réécrits en bloc à la fin de l'étape.
    /// Un sous-ensemble de `fileIDs`.
    public var settingsIDs: [UInt32]

    public init(manifestID: String, displayName: String, kind: Kind, style: SetupStyle,
                temporaryIDs: [UInt32] = [], fileIDs: [UInt32] = [], settingsIDs: [UInt32] = []) {
        self.manifestID = manifestID
        self.displayName = displayName
        self.kind = kind
        self.style = style
        self.temporaryIDs = temporaryIDs
        self.fileIDs = fileIDs
        self.settingsIDs = settingsIDs
    }
}

/// Ce que l'allocateur a fait pendant l'installation, dans l'ordre.
public enum InstallEntry: Sendable {
    /// Une étape commence.
    case begin(step: Int)
    /// Un fichier est créé : l'enregistrement complet, extents compris.
    case created(FileRecord)
    /// Un fichier est effacé ; `extents` sont les clusters qu'il rend.
    case deleted(FileRecord)
    /// La table de métadonnées a pris ces clusters pour grandir.
    case metadataGrew([Extent])
}

/// Une installation rejouée : le disque tel qu'il est à la fin du jour 0, et
/// comment il y est arrivé.
public struct InstalledDisk: Sendable {
    /// Le disque au soir de l'installation. C'est lui qui, vieilli, devient le
    /// disque de la galerie.
    public var disk: GeneratedDisk
    public var steps: [InstallStep]
    public var journal: [InstallEntry]
    /// Ce que le système de fichiers occupait avant le premier fichier :
    /// `$Boot`, la MFT initiale et sa copie sur NTFS, rien sur FAT.
    public var initialSystemExtents: [Extent]
}
