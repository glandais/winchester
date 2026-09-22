import Foundation

/// Arborescence et tailles d'une application d'époque.
///
/// Ces manifestes ne sont pas des listings relevés sur un vrai disque : ce sont
/// des **règles**. On dit « Office 97 pose une quarantaine de mégaoctets dans
/// `\PROGRA~1\MSOFFICE`, quelques dizaines de DLL dans `SYSTEM`, et partage
/// `MFC42.DLL` avec tout le monde », et le générateur en tire une arborescence
/// cohérente, différente à chaque graine mais toujours plausible.
///
/// Le partage de DLL est la partie qui compte : c'est lui qui fait qu'une
/// désinstallation laisse des orphelins, et que le volume garde des cicatrices
/// de logiciels qui n'y sont plus.
public struct AppManifest: Sendable, Codable, Identifiable {

    /// Un lot de fichiers de même nature, décrit par une distribution.
    public struct Group: Sendable, Codable {
        public var directory: String
        public var extension_: String
        public var category: FileCategory
        public var fileCount: Int
        /// Médiane de la taille, en octets, et dispersion sur le logarithme.
        public var medianBytes: ByteCount
        public var sigma: Double
        public var pattern: WritePattern

        public init(directory: String,
                    extension_: String,
                    category: FileCategory,
                    fileCount: Int,
                    medianBytes: ByteCount,
                    sigma: Double,
                    pattern: WritePattern = .createOnce) {
            self.directory = directory
            self.extension_ = extension_
            self.category = category
            self.fileCount = fileCount
            self.medianBytes = medianBytes
            self.sigma = sigma
            self.pattern = pattern
        }

        enum CodingKeys: String, CodingKey {
            case directory, category, fileCount, medianBytes, sigma, pattern
            case extension_ = "extension"
        }
    }

    public var id: String
    public var displayName: String
    public var groups: [Group]
    /// Bibliothèques partagées posées dans le répertoire système. Une DLL déjà
    /// présente n'est pas réécrite, et une désinstallation ne l'enlève pas :
    /// c'est exactement ce que faisaient les installeurs de l'époque, et c'est
    /// pour cela que `\WINDOWS\SYSTEM` ne faisait que grossir.
    public var sharedLibraries: [String]
    /// Le jour où le logiciel s'est vendu. `nil` quand la date n'est pas
    /// connue avec certitude : `ProfileIssues` ne juge que celles-là. Un
    /// profil qui l'installe avant reçoit un avertissement, pas un refus —
    /// un disque anachronique est une question légitime.
    public var releaseDate: CivilDate?

    public init(id: String, displayName: String, groups: [Group], sharedLibraries: [String] = [],
                releaseDate: CivilDate? = nil) {
        self.id = id
        self.displayName = displayName
        self.groups = groups
        self.sharedLibraries = sharedLibraries
        self.releaseDate = releaseDate
    }

    /// Octets posés par l'application, hors bibliothèques partagées.
    public var approximateBytes: ByteCount {
        groups.reduce(0) { total, group in
            // Espérance d'une log-normale : médiane × e^(σ²/2).
            total + ByteCount(Double(group.medianBytes) * exp(group.sigma * group.sigma / 2))
                * ByteCount(group.fileCount)
        }
    }
}

/// Fabrique de manifestes : une règle par application et par époque.
///
/// Les tailles et les effectifs sont des ordres de grandeur d'époque, pas des
/// relevés. Ce qui compte pour le disque, ce n'est pas qu'`OLEAUT32.DLL` fasse
/// exactement 584 Ko, c'est qu'une installation de 1996 pose quelques milliers
/// de fichiers dont une centaine de DLL partagées.
public enum AppLibrary {

    /// Les bibliothèques que tout le monde partageait. Chaque installeur les
    /// posait « au cas où », et aucun désinstalleur n'osait les retirer.
    private static let commonRuntime = [
        "MFC42.DLL", "MSVCRT.DLL", "OLEAUT32.DLL", "COMCTL32.DLL", "CTL3D32.DLL",
    ]

    public static func manifest(id: String) -> AppManifest? {
        all.first { $0.id == id }
    }

    public static let all: [AppManifest] = [

        // MARK: 1993 — MS-DOS et Windows 3.1

        AppManifest(id: "msdos-6", displayName: "MS-DOS 6.22", groups: [
            .init(directory: "\\DOS", extension_: "EXE", category: .systemCore,
                  fileCount: 70, medianBytes: 30_000, sigma: 1.0),
            .init(directory: "\\DOS", extension_: "SYS", category: .systemCore,
                  fileCount: 12, medianBytes: 9_000, sigma: 0.8),
            .init(directory: "\\DOS", extension_: "HLP", category: .archive,
                  fileCount: 6, medianBytes: 180_000, sigma: 0.5),
        ],
            // MS-DOS 6.22 : juin 1994 (6.0 : mars 1993). Les profils de 1993 l'installent en avril 1993.
            releaseDate: CivilDate("1994-06-01")!),

        AppManifest(id: "win31", displayName: "Windows 3.1", groups: [
            .init(directory: "\\WINDOWS", extension_: "EXE", category: .systemCore,
                  fileCount: 60, medianBytes: 45_000, sigma: 1.2),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "DRV", category: .systemCore,
                  fileCount: 90, medianBytes: 22_000, sigma: 1.0),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", category: .systemCore,
                  fileCount: 120, medianBytes: 60_000, sigma: 1.4),
            .init(directory: "\\WINDOWS", extension_: "INI", category: .systemCore,
                  fileCount: 14, medianBytes: 3_000, sigma: 0.9, pattern: .rewriteInPlace),
        ]),

        AppManifest(id: "bc31", displayName: "Borland C++ 3.1", groups: [
            .init(directory: "\\BORLANDC\\BIN", extension_: "EXE", category: .application,
                  fileCount: 22, medianBytes: 320_000, sigma: 0.9),
            .init(directory: "\\BORLANDC\\LIB", extension_: "LIB", category: .application,
                  fileCount: 40, medianBytes: 140_000, sigma: 1.1),
            .init(directory: "\\BORLANDC\\INCLUDE", extension_: "H", category: .source,
                  fileCount: 180, medianBytes: 7_000, sigma: 1.0),
        ]),

        AppManifest(id: "works3", displayName: "Microsoft Works 3", groups: [
            .init(directory: "\\WORKS", extension_: "EXE", category: .application,
                  fileCount: 8, medianBytes: 700_000, sigma: 0.6),
            .init(directory: "\\WORKS", extension_: "DLL", category: .application,
                  fileCount: 24, medianBytes: 180_000, sigma: 1.0),
            .init(directory: "\\WORKS\\TEMPLATE", extension_: "WPS", category: .document,
                  fileCount: 40, medianBytes: 12_000, sigma: 0.7),
        ]),

        // MARK: 1996 — Windows 95

        AppManifest(id: "win95", displayName: "Windows 95", groups: [
            .init(directory: "\\WINDOWS", extension_: "EXE", category: .systemCore,
                  fileCount: 120, medianBytes: 70_000, sigma: 1.3),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", category: .systemCore,
                  fileCount: 420, medianBytes: 80_000, sigma: 1.5),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "VXD", category: .systemCore,
                  fileCount: 110, medianBytes: 26_000, sigma: 1.1),
            .init(directory: "\\WINDOWS\\HELP", extension_: "HLP", category: .archive,
                  fileCount: 60, medianBytes: 220_000, sigma: 0.9),
            .init(directory: "\\WINDOWS\\FONTS", extension_: "TTF", category: .archive,
                  fileCount: 70, medianBytes: 90_000, sigma: 0.8),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "office95", displayName: "Office 95", groups: [
            .init(directory: "\\MSOFFICE\\WINWORD", extension_: "EXE", category: .application,
                  fileCount: 6, medianBytes: 3_600_000, sigma: 0.5),
            .init(directory: "\\MSOFFICE\\EXCEL", extension_: "EXE", category: .application,
                  fileCount: 5, medianBytes: 3_200_000, sigma: 0.5),
            .init(directory: "\\MSOFFICE", extension_: "DLL", category: .application,
                  fileCount: 90, medianBytes: 260_000, sigma: 1.3),
            .init(directory: "\\MSOFFICE\\TEMPLATE", extension_: "DOT", category: .document,
                  fileCount: 120, medianBytes: 26_000, sigma: 0.8),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "vc42", displayName: "Visual C++ 4.2", groups: [
            .init(directory: "\\MSDEV\\BIN", extension_: "EXE", category: .application,
                  fileCount: 30, medianBytes: 900_000, sigma: 1.0),
            .init(directory: "\\MSDEV\\LIB", extension_: "LIB", category: .application,
                  fileCount: 120, medianBytes: 400_000, sigma: 1.4),
            .init(directory: "\\MSDEV\\INCLUDE", extension_: "H", category: .source,
                  fileCount: 620, medianBytes: 9_000, sigma: 1.1),
            .init(directory: "\\MSDEV\\HELP", extension_: "MVB", category: .archive,
                  fileCount: 18, medianBytes: 4_000_000, sigma: 0.6),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "netscape3", displayName: "Netscape Navigator 3", groups: [
            .init(directory: "\\NETSCAPE", extension_: "EXE", category: .application,
                  fileCount: 4, medianBytes: 2_800_000, sigma: 0.4),
            .init(directory: "\\NETSCAPE", extension_: "DLL", category: .application,
                  fileCount: 20, medianBytes: 220_000, sigma: 1.0),
        ], sharedLibraries: commonRuntime,
            // Netscape Navigator 3.0 : 19 août 1996.
            releaseDate: CivilDate("1996-08-19")!),

        AppManifest(id: "doom2", displayName: "Doom II", groups: [
            .init(directory: "\\DOOM2", extension_: "WAD", category: .gameAsset,
                  fileCount: 2, medianBytes: 14_000_000, sigma: 0.2),
            .init(directory: "\\DOOM2", extension_: "EXE", category: .application,
                  fileCount: 3, medianBytes: 700_000, sigma: 0.4),
        ]),

        AppManifest(id: "quake", displayName: "Quake", groups: [
            .init(directory: "\\QUAKE\\ID1", extension_: "PAK", category: .gameAsset,
                  fileCount: 2, medianBytes: 26_000_000, sigma: 0.3),
            .init(directory: "\\QUAKE", extension_: "EXE", category: .application,
                  fileCount: 4, medianBytes: 500_000, sigma: 0.5),
        ],
            // Quake : 22 juin 1996 (shareware). Installé en mars 1996 par les profils de 1996.
            releaseDate: CivilDate("1996-06-22")!),

        // MARK: 1999 — Windows 98 SE

        AppManifest(id: "win98se", displayName: "Windows 98 SE", groups: [
            .init(directory: "\\WINDOWS", extension_: "EXE", category: .systemCore,
                  fileCount: 180, medianBytes: 90_000, sigma: 1.3),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", category: .systemCore,
                  fileCount: 900, medianBytes: 95_000, sigma: 1.5),
            .init(directory: "\\WINDOWS\\SYSTEM32\\DRIVERS", extension_: "SYS", category: .systemCore,
                  fileCount: 160, medianBytes: 30_000, sigma: 1.1),
            .init(directory: "\\WINDOWS\\HELP", extension_: "CHM", category: .archive,
                  fileCount: 90, medianBytes: 280_000, sigma: 0.9),
            .init(directory: "\\WINDOWS\\APPLOG", extension_: "LGC", category: .cache,
                  fileCount: 60, medianBytes: 4_000, sigma: 0.8,
                  pattern: .append(growthPerEvent: 2_000)),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "office97", displayName: "Office 97", groups: [
            .init(directory: "\\PROGRA~1\\MSOFFICE\\OFFICE", extension_: "EXE", category: .application,
                  fileCount: 8, medianBytes: 5_200_000, sigma: 0.5),
            .init(directory: "\\PROGRA~1\\MSOFFICE\\OFFICE", extension_: "DLL", category: .application,
                  fileCount: 140, medianBytes: 320_000, sigma: 1.3),
            .init(directory: "\\PROGRA~1\\MSOFFICE\\TEMPLATES", extension_: "DOT", category: .document,
                  fileCount: 160, medianBytes: 30_000, sigma: 0.8),
            .init(directory: "\\PROGRA~1\\MSOFFICE\\CLIPART", extension_: "WMF", category: .media,
                  fileCount: 600, medianBytes: 18_000, sigma: 1.0),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "ie5", displayName: "Internet Explorer 5", groups: [
            .init(directory: "\\PROGRA~1\\INTERN~1", extension_: "EXE", category: .application,
                  fileCount: 3, medianBytes: 800_000, sigma: 0.4),
            .init(directory: "\\WINDOWS\\SYSTEM", extension_: "DLL", category: .systemCore,
                  fileCount: 60, medianBytes: 400_000, sigma: 1.2),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "winamp", displayName: "Winamp 2", groups: [
            .init(directory: "\\PROGRA~1\\WINAMP", extension_: "EXE", category: .application,
                  fileCount: 2, medianBytes: 600_000, sigma: 0.3),
            .init(directory: "\\PROGRA~1\\WINAMP\\PLUGINS", extension_: "DLL", category: .application,
                  fileCount: 24, medianBytes: 90_000, sigma: 0.9),
            .init(directory: "\\PROGRA~1\\WINAMP\\SKINS", extension_: "WSZ", category: .archive,
                  fileCount: 18, medianBytes: 220_000, sigma: 0.7),
        ]),

        AppManifest(id: "halflife", displayName: "Half-Life", groups: [
            .init(directory: "\\SIERRA\\HALF-LIFE\\VALVE", extension_: "WAD", category: .gameAsset,
                  fileCount: 12, medianBytes: 30_000_000, sigma: 0.6),
            .init(directory: "\\SIERRA\\HALF-LIFE\\VALVE\\MAPS", extension_: "BSP", category: .gameAsset,
                  fileCount: 80, medianBytes: 4_000_000, sigma: 0.7),
            .init(directory: "\\SIERRA\\HALF-LIFE", extension_: "DLL", category: .application,
                  fileCount: 20, medianBytes: 300_000, sigma: 0.9),
        ]),

        // MARK: 2003 — Windows XP

        AppManifest(id: "winxp", displayName: "Windows XP SP1", groups: [
            .init(directory: "\\WINDOWS\\system32", extension_: "dll", category: .systemCore,
                  fileCount: 1_900, medianBytes: 110_000, sigma: 1.6),
            .init(directory: "\\WINDOWS\\system32\\drivers", extension_: "sys", category: .systemCore,
                  fileCount: 320, medianBytes: 40_000, sigma: 1.2),
            .init(directory: "\\WINDOWS", extension_: "exe", category: .systemCore,
                  fileCount: 260, medianBytes: 120_000, sigma: 1.4),
            .init(directory: "\\WINDOWS\\Fonts", extension_: "ttf", category: .archive,
                  fileCount: 140, medianBytes: 140_000, sigma: 0.9),
            .init(directory: "\\WINDOWS\\Help", extension_: "chm", category: .archive,
                  fileCount: 180, medianBytes: 320_000, sigma: 1.0),
            .init(directory: "\\WINDOWS\\Prefetch", extension_: "pf", category: .cache,
                  fileCount: 120, medianBytes: 26_000, sigma: 0.8,
                  pattern: .writeTempThenRename),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "officexp", displayName: "Office XP", groups: [
            .init(directory: "\\Program Files\\Microsoft Office\\Office10", extension_: "exe",
                  category: .application, fileCount: 10, medianBytes: 9_000_000, sigma: 0.5),
            .init(directory: "\\Program Files\\Microsoft Office\\Office10", extension_: "dll",
                  category: .application, fileCount: 220, medianBytes: 420_000, sigma: 1.3),
            .init(directory: "\\Program Files\\Common Files\\Microsoft Shared", extension_: "dll",
                  category: .application, fileCount: 180, medianBytes: 300_000, sigma: 1.2),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "vsnet", displayName: "Visual Studio .NET", groups: [
            .init(directory: "\\Program Files\\Microsoft Visual Studio .NET\\Common7\\IDE",
                  extension_: "dll", category: .application,
                  fileCount: 420, medianBytes: 500_000, sigma: 1.4),
            .init(directory: "\\Program Files\\Microsoft Visual Studio .NET\\Vc7\\include",
                  extension_: "h", category: .source,
                  fileCount: 1_100, medianBytes: 11_000, sigma: 1.1),
            .init(directory: "\\Program Files\\Microsoft Visual Studio .NET\\Vc7\\lib",
                  extension_: "lib", category: .application,
                  fileCount: 160, medianBytes: 1_400_000, sigma: 1.3),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "ut2003", displayName: "Unreal Tournament 2003", groups: [
            .init(directory: "\\UT2003\\Animations", extension_: "ukx", category: .gameAsset,
                  fileCount: 40, medianBytes: 30_000_000, sigma: 0.6),
            .init(directory: "\\UT2003\\Textures", extension_: "utx", category: .gameAsset,
                  fileCount: 90, medianBytes: 22_000_000, sigma: 0.7),
            .init(directory: "\\UT2003\\Maps", extension_: "ut2", category: .gameAsset,
                  fileCount: 60, medianBytes: 14_000_000, sigma: 0.6),
            .init(directory: "\\UT2003\\System", extension_: "dll", category: .application,
                  fileCount: 50, medianBytes: 400_000, sigma: 1.0),
        ]),

        AppManifest(id: "nero", displayName: "Nero Burning ROM", groups: [
            .init(directory: "\\Program Files\\Ahead\\Nero", extension_: "exe",
                  category: .application, fileCount: 6, medianBytes: 2_400_000, sigma: 0.5),
            .init(directory: "\\Program Files\\Ahead\\Nero", extension_: "dll",
                  category: .application, fileCount: 40, medianBytes: 280_000, sigma: 1.0),
        ], sharedLibraries: commonRuntime),

        // MARK: 2007 — Windows Vista

        AppManifest(id: "vista", displayName: "Windows Vista", groups: [
            .init(directory: "\\Windows\\System32", extension_: "dll", category: .systemCore,
                  fileCount: 3_400, medianBytes: 180_000, sigma: 1.6),
            .init(directory: "\\Windows\\System32\\drivers", extension_: "sys", category: .systemCore,
                  fileCount: 520, medianBytes: 60_000, sigma: 1.2),
            .init(directory: "\\Windows\\winsxs", extension_: "dll", category: .systemCore,
                  fileCount: 6_000, medianBytes: 90_000, sigma: 1.5),
            .init(directory: "\\Windows\\Fonts", extension_: "ttf", category: .archive,
                  fileCount: 220, medianBytes: 220_000, sigma: 0.9),
            .init(directory: "\\Windows\\Prefetch", extension_: "pf", category: .cache,
                  fileCount: 180, medianBytes: 40_000, sigma: 0.8,
                  pattern: .writeTempThenRename),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "office2007", displayName: "Office 2007", groups: [
            .init(directory: "\\Program Files\\Microsoft Office\\Office12", extension_: "exe",
                  category: .application, fileCount: 12, medianBytes: 14_000_000, sigma: 0.5),
            .init(directory: "\\Program Files\\Microsoft Office\\Office12", extension_: "dll",
                  category: .application, fileCount: 300, medianBytes: 600_000, sigma: 1.3),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "crysis", displayName: "Crysis", groups: [
            .init(directory: "\\Program Files\\Electronic Arts\\Crytek\\Crysis\\Game\\Levels",
                  extension_: "pak", category: .gameAsset,
                  fileCount: 24, medianBytes: 420_000_000, sigma: 0.4),
            .init(directory: "\\Program Files\\Electronic Arts\\Crytek\\Crysis\\Bin32",
                  extension_: "dll", category: .application,
                  fileCount: 40, medianBytes: 900_000, sigma: 1.0),
        ],
            // Crysis : 13 novembre 2007. Les profils de 2007 l'installent en avril.
            releaseDate: CivilDate("2007-11-13")!),

        AppManifest(id: "itunes7", displayName: "iTunes 7", groups: [
            .init(directory: "\\Program Files\\iTunes", extension_: "dll", category: .application,
                  fileCount: 60, medianBytes: 800_000, sigma: 1.1),
            .init(directory: "\\Program Files\\iTunes", extension_: "exe", category: .application,
                  fileCount: 4, medianBytes: 9_000_000, sigma: 0.4),
        ], sharedLibraries: commonRuntime),

        // MARK: 2012 — Windows 7
        //
        // Un Windows 7 de 2012 est en 64 bits : les applications 32 bits vont
        // dans `\Program Files (x86)`, le système garde `System32` pour lui.

        AppManifest(id: "win7", displayName: "Windows 7 SP1", groups: [
            .init(directory: "\\Windows\\System32", extension_: "dll", category: .systemCore,
                  fileCount: 3_000, medianBytes: 200_000, sigma: 1.6),
            .init(directory: "\\Windows\\System32\\drivers", extension_: "sys", category: .systemCore,
                  fileCount: 400, medianBytes: 60_000, sigma: 1.2),
            .init(directory: "\\Windows\\winsxs", extension_: "dll", category: .systemCore,
                  fileCount: 9_000, medianBytes: 100_000, sigma: 1.5),
            // Le magasin de pilotes : chaque pilote livré avec le système,
            // qu'un périphérique le demande ou non.
            .init(directory: "\\Windows\\System32\\DriverStore\\FileRepository", extension_: "sys",
                  category: .systemCore, fileCount: 2_000, medianBytes: 50_000, sigma: 1.4),
            .init(directory: "\\Windows\\Fonts", extension_: "ttf", category: .archive,
                  fileCount: 250, medianBytes: 250_000, sigma: 0.9),
            // Windows 7 garde au plus 128 traces de préchargement.
            .init(directory: "\\Windows\\Prefetch", extension_: "pf", category: .cache,
                  fileCount: 128, medianBytes: 40_000, sigma: 0.8,
                  pattern: .writeTempThenRename),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "office2010", displayName: "Office 2010", groups: [
            .init(directory: "\\Program Files (x86)\\Microsoft Office\\Office14", extension_: "exe",
                  category: .application, fileCount: 12, medianBytes: 16_000_000, sigma: 0.5),
            .init(directory: "\\Program Files (x86)\\Microsoft Office\\Office14", extension_: "dll",
                  category: .application, fileCount: 350, medianBytes: 650_000, sigma: 1.3),
            // La source d'installation gardée sur le disque, pour réparer ou
            // ajouter une fonction sans le DVD.
            .init(directory: "\\MSOCache\\All Users", extension_: "cab", category: .archive,
                  fileCount: 20, medianBytes: 30_000_000, sigma: 0.8),
        ], sharedLibraries: commonRuntime),

        AppManifest(id: "vs2010", displayName: "Visual Studio 2010", groups: [
            .init(directory: "\\Program Files (x86)\\Microsoft Visual Studio 10.0\\Common7\\IDE",
                  extension_: "dll", category: .application,
                  fileCount: 900, medianBytes: 500_000, sigma: 1.4),
            .init(directory: "\\Program Files (x86)\\Microsoft Visual Studio 10.0\\VC\\include",
                  extension_: "h", category: .source,
                  fileCount: 1_500, medianBytes: 12_000, sigma: 1.1),
            .init(directory: "\\Program Files (x86)\\Microsoft Visual Studio 10.0\\VC\\lib",
                  extension_: "lib", category: .application,
                  fileCount: 250, medianBytes: 1_500_000, sigma: 1.3),
            .init(directory: "\\Program Files (x86)\\Microsoft SDKs\\Windows\\v7.0A\\Include",
                  extension_: "h", category: .source,
                  fileCount: 1_800, medianBytes: 15_000, sigma: 1.2),
        ], sharedLibraries: commonRuntime),

        // Les archives de Bethesda : une douzaine de `.bsa`, de quelques
        // dizaines de mégaoctets à plus d'un gigaoctet pour les textures.
        AppManifest(id: "skyrim", displayName: "The Elder Scrolls V: Skyrim", groups: [
            .init(directory: "\\Program Files (x86)\\Steam\\steamapps\\common\\skyrim\\Data",
                  extension_: "bsa", category: .gameAsset,
                  fileCount: 12, medianBytes: 250_000_000, sigma: 1.2),
            .init(directory: "\\Program Files (x86)\\Steam\\steamapps\\common\\skyrim",
                  extension_: "dll", category: .application,
                  fileCount: 30, medianBytes: 900_000, sigma: 1.0),
        ]),

        // Frostbite 2 range ses données dans des `cas_NN.cas` qui plafonnent à
        // un gigaoctet, et les indexe par milliers de petits fichiers.
        AppManifest(id: "bf3", displayName: "Battlefield 3", groups: [
            .init(directory: "\\Program Files (x86)\\Origin Games\\Battlefield 3\\Data",
                  extension_: "cas", category: .gameAsset,
                  fileCount: 18, medianBytes: 1_000_000_000, sigma: 0.1),
            .init(directory: "\\Program Files (x86)\\Origin Games\\Battlefield 3\\Data\\Win32",
                  extension_: "sb", category: .gameAsset,
                  fileCount: 1_200, medianBytes: 300_000, sigma: 1.5),
            .init(directory: "\\Program Files (x86)\\Origin Games\\Battlefield 3",
                  extension_: "dll", category: .application,
                  fileCount: 40, medianBytes: 1_200_000, sigma: 1.0),
        ]),

        AppManifest(id: "itunes10", displayName: "iTunes 10", groups: [
            .init(directory: "\\Program Files (x86)\\iTunes", extension_: "dll", category: .application,
                  fileCount: 80, medianBytes: 900_000, sigma: 1.1),
            .init(directory: "\\Program Files (x86)\\iTunes", extension_: "exe", category: .application,
                  fileCount: 4, medianBytes: 12_000_000, sigma: 0.4),
        ], sharedLibraries: commonRuntime),
    ]
}
