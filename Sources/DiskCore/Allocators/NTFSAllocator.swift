import Foundation

/// Allocateur NTFS.
///
/// **Deux allocateurs sous un même nom**, depuis le chantier 49 :
///
/// - **XP** (`Formatting.xp`) : celui du pilote de XP SP1, suivi à la lettre
///   (`NTFSAllocator+XP.swift`) — un cache des runs libres borné, un *best
///   fit* par longueur sans curseur ni préférence pour le vierge, le
///   découpage du plus grand morceau au plus petit, les clusters libérés
///   rendus au point de contrôle, la surallocation de `NtfsCommonWrite`, une
///   zone MFT recalculée à chaque montage, une MFT qui grandit par seize
///   enregistrements. Aucune borne sans source ;
/// - **NT 4, Vista et 7** : le modèle d'avant, que le code de XP ne permet
///   pas de vérifier pour eux, et qui est décrit ci-dessous tel qu'il est.
///
/// Le modèle d'avant tient en trois mécanismes :
///
/// - **best-fit** plutôt que premier trou venu, **mais** un trou n'est repris
///   que s'il fait au plus deux fois le besoin : au-delà, l'allocateur préfère
///   l'espace jamais servi ;
/// - **zone MFT** — 12,5 % du volume sous NT, 200 Mo renouvelables sous
///   Vista et 7 (KB 961095) —, tenue à l'écart des données ; quand le reste
///   du volume est plein, elle **rend la moitié de ce qui lui reste libre**,
///   et recommence à chaque remplissage ;
/// - **prolongement en place**, et un complément cherché **à partir du
///   fichier**, comme le fait le pilote NTFS de Linux
///   (`ntfs_attr_extend_allocation`). XP, lui, prend le run du cache qui suit
///   le fichier, sinon le trou le plus juste, où qu'il soit (`ntfs-alloc-04`).
///
/// **Quatre bornes de recherche** (`SearchBounds`) règlent la fragmentation de
/// ce modèle, et **aucune ne vient d'une source**. Ce qu'elles pèsent, en
/// fichiers fragmentés parmi les fragmentables — la table que régénère
/// `CalibrationTests.ntfsSearchBoundsWeighOnFragmentation` ; les deux volumes
/// de XP n'y bougent pas, par construction :
///
/// | réglage                      | `famille-2003` | `secretaire-2003` | `dev-2007` | `famille-2007` |
/// |------------------------------|-------:|-------:|------:|-------:|
/// | tel quel (2, 64, 65 536)     | 16,2 % | 64,0 % | 9,2 % | 22,5 % |
/// | `reuseTolerance` = 4         | 16,2 % | 64,0 % | 9,2 % | 22,4 % |
/// | `reuseTolerance` = `.max`    | 16,2 % | 64,0 % | 8,3 % | 21,0 % |
/// | `window` = 16                | 16,2 % | 64,0 % | 8,6 % | 22,7 % |
/// | `window` = 256               | 16,2 % | 64,0 % | 9,2 % | 22,3 % |
/// | `horizon` = 16 384           | 16,2 % | 64,0 % | 12,7 % | 35,0 % |
/// | `horizon` = 262 144          | 16,2 % | 64,0 % | 6,5 % | 22,3 % |
///
/// Sur les volumes de Vista, **l'horizon décide le plus** : de 6,5 à 12,7 %
/// sur `dev-2007`, de 22,3 à 35,0 % sur `famille-2007`, quand la tolérance ne
/// les bouge que d'un point ou deux. La quatrième borne, les seize fenêtres
/// du dernier recours (`fallbackWindows`), ne joue que sur un volume sans
/// espace vierge. Leur coût est sans ambiguïté : sans tolérance, la
/// génération de `dev-2007` est huit fois plus longue.
///
/// La « réutilisation paresseuse » des clusters libérés est modélisée, hors
/// XP, par cette préférence pour l'espace jamais servi : la libération est
/// immédiate, et un trou n'est repris que s'il convient vraiment au fichier,
/// ou quand le vierge est épuisé. Sous XP, le délai tient au journal : les
/// clusters libérés sont masqués jusqu'au point de contrôle, puis offerts au
/// *best fit* comme les autres (`ntfs-alloc-03`).
public struct NTFSAllocator: Allocator {

    /// Où `FORMAT` pose les métafichiers, selon le système qui formate.
    ///
    /// Quatre dispositions, et ce que chacune doit à une source :
    ///
    /// - **XP et Server 2003**, d'après le code de `FORMAT` de XP SP1
    ///   (`base/fs/utils/untfs`, `LOGFILE_PLACEMENT_V1` défini à
    ///   `format.cxx:62`), qui fait foi (`LEDGER-XP.md`, décision 1) :
    ///   `$MFT` à **3 Gio** du début (LCN 786 432 en clusters de 4 Ko), à
    ///   1 Gio pour un volume de 2 à 6 Gio, au tiers sous 2 Gio
    ///   (`format.cxx:585-593`) ; la bitmap de la MFT juste devant elle
    ///   (`mftfile.cxx:289-293`) ; `$LogFile` qui finit deux clusters avant
    ///   (`format.cxx:617-618`, `logfile.cxx:223-233`) ; `$MFTMirr` au
    ///   **milieu** du volume (`mftref.cxx:177-182`), suivi de `$AttrDef`,
    ///   `$Bitmap`, `$UpCase` et de l'allocation de l'index racine, que
    ///   l'allocateur de `FORMAT` pose l'un derrière l'autre
    ///   (`format.cxx:337-341, 904-1175`, `ntfsbit.cxx:452-460, 585`). La
    ///   zone de 12,5 % est celle du pilote (`bitmpsup.c:42, 8542-8551`) ;
    /// - **NT 4 et 2000** (`mkntfs.c`, qui reproduit `FORMAT` de l'époque) :
    ///   `$MFT` en tête derrière `$Boot`, `$MFTMirr` au **milieu** du volume,
    ///   `$LogFile` juste derrière lui, zone MFT de 12,5 % du volume ;
    /// - **Vista** : `$MFT` à 3 Gio (au huitième d'un volume plus petit, une
    ///   règle du modèle), `$MFTMirr` au milieu, `$LogFile` derrière lui comme
    ///   le pose `mkntfs`, `$Bitmap` derrière la zone ; la zone fait
    ///   **200 Mo**, renouvelés par tranches de 200 Mo quand la MFT la remplit
    ///   (KB 961095, primaire) ;
    /// - **Windows 7** : comme Vista, `$MFTMirr` ramené au **LCN 2**.
    ///
    /// Vista et 7 gardent le modèle d'avant le chantier 48 : leur `FORMAT`
    /// n'est pas dans le code consulté, et ce que XP fait ne les engage pas.
    /// Pour les trois, les données ordinaires se posent **devant** `$MFT`,
    /// dans les premiers gigaoctets : c'est ce que fait le pilote de XP, qui
    /// ne réserve que la zone (`bitmpsup.c:3872-3905`), et ce que montre un
    /// `fsutil` moderne.
    public enum Formatting: Sendable {
        case nt, xp, vista, win7

        /// Le miroir au milieu du volume, ou près du début.
        var mirrorInTheMiddle: Bool { self != .win7 }
        /// `$MFT` loin du début (à 3 Gio sur un grand volume), ou en tête.
        var mftAtThreeGibibytes: Bool { self != .nt }
        /// La zone MFT : une part du volume, ou 200 Mo renouvelables.
        var renewableZoneBytes: UInt64? { self == .vista || self == .win7 ? 200 << 20 : nil }
        /// Enregistrements d'une MFT neuve : `FIRST_USER_FILE_NUMBER`, 16,
        /// sous XP (`format.cxx:552, 685`, `ntfs.h:406`) ; 32 ailleurs, une
        /// valeur du modèle.
        public var initialMFTRecords: UInt64 { self == .xp ? 16 : 32 }
    }

    public let ntfs: NTFSProfile
    public var profile: any FileSystemProfile { ntfs }
    public internal(set) var bitmap: ClusterBitmap

    /// `$MFT` vu comme ce qu'il est : un fichier, qui grandit et qui peut se
    /// fragmenter.
    public internal(set) var mft: FileEntry
    public private(set) var mftMirror: Extent
    /// `$LogFile` : le journal, de taille fixe et immobile.
    public private(set) var logFile: Extent
    /// `$Bitmap` : la table d'occupation, un bit par cluster — au milieu du
    /// volume sous XP, derrière la zone MFT ailleurs (`Layout.bitmap`).
    public private(set) var volumeBitmap: Extent
    /// Les métafichiers que seul `FORMAT` de XP pose ici : la bitmap de la
    /// MFT, `$AttrDef` et `$UpCase`. Vide ailleurs.
    public let formatExtras: [Extent]
    /// L'allocation de l'index de la racine que `FORMAT` de XP a posée au
    /// milieu du volume : elle appartient au répertoire racine, que le
    /// simulateur crée plus tard (`Allocator.formattedRootIndex`). `nil`
    /// ailleurs, où la racine prend ses clusters comme tout répertoire.
    public let formattedRootIndex: Extent?
    /// `$Boot` : les huit premiers kilo-octets du volume.
    public private(set) var bootExtent: Extent
    /// Enregistrements en service — ceux des fichiers vivants.
    public private(set) var mftRecordCount: UInt64
    /// Plus grand nombre d'enregistrements simultanés jamais atteint. La MFT ne
    /// rétrécit pas : une fois qu'elle a dû grandir, elle reste grande, même si
    /// les fichiers qui l'ont fait gonfler ont disparu depuis longtemps.
    public private(set) var mftPeakRecords: UInt64

    /// Plage réservée à la croissance de la MFT — la zone **courante**, celle
    /// que renverrait `FSCTL_GET_NTFS_VOLUME_DATA`. Hors XP, juste derrière la
    /// MFT, et elle ne fait que rétrécir (sauf la tranche neuve de Vista et
    /// 7). Sous XP, recalculée à chaque montage, réduite, regonflée ou
    /// reposée ailleurs (`xpInitializeMftZone`, `xpReduceZone`).
    public internal(set) var mftZone: Range<UInt32>
    /// Combien de fois la zone a cédé la moitié de sa queue libre.
    public internal(set) var mftZoneHalvings = 0
    /// La zone a-t-elle déjà cédé de la place aux données ?
    public var mftZoneBreached: Bool { mftZoneHalvings > 0 }

    /// Plus haut cluster jamais alloué, plus un : la frontière de l'espace
    /// vierge.
    public internal(set) var highWater: UInt32

    /// Modèle d'avant, hors XP (qui n'a ni curseur ni bornes).
    ///
    /// Les bornes de la recherche de trous : quatre constantes introduites pour
    /// le coût de calcul, qui règlent aussi la fragmentation (voir l'en-tête).
    /// Les valeurs de la galerie sont `standard` ; les autres ne servent qu'à
    /// mesurer ce qu'elles pèsent.
    public struct SearchBounds: Sendable, Equatable {
        /// Un trou n'est repris que si sa taille ne dépasse pas ce multiple du
        /// besoin. Au-delà, l'allocateur préfère l'espace vierge plutôt que de
        /// couper un grand bloc en deux.
        public var reuseTolerance: UInt32
        /// Trous examinés avant de se décider. NTFS ne connaît pas l'état
        /// complet de son volume à chaque écriture : il tient un cache partiel
        /// de sa table d'occupation et prend le meilleur trou qu'il y voit.
        /// C'est ce que fait cette fenêtre — et sans elle, chaque allocation
        /// parcourrait les dizaines de milliers de trous d'un volume de 80 Go.
        public var window: Int
        /// Distance maximale parcourue dans la bitmap à la recherche d'un trou :
        /// 65 536 clusters, soit 8 Ko de table d'occupation — l'ordre de
        /// grandeur de ce qu'un pilote garde en cache, sans source qui le
        /// chiffre. Au-delà, l'allocateur renonce et va prendre de l'espace
        /// vierge. C'est la borne qui décide du coût de la génération : sans
        /// elle, chaque écriture traverse les zones pleines qui séparent les
        /// trous, et un volume de 80 Go devient quadratique.
        public var horizon: UInt32
        /// Fenêtres d'un `horizon` que le dernier recours parcourt, quand il n'y
        /// a plus de vierge, avant de répartir le fichier sur les plus gros
        /// morceaux (`scatter`). Seize fois 65 536 clusters, c'est 4 Go sur un
        /// volume en clusters de 4 Ko.
        public var fallbackWindows: Int

        public init(reuseTolerance: UInt32, window: Int, horizon: UInt32, fallbackWindows: Int) {
            self.reuseTolerance = reuseTolerance
            self.window = window
            self.horizon = horizon
            self.fallbackWindows = fallbackWindows
        }

        public static let standard = SearchBounds(reuseTolerance: 2, window: 64,
                                                  horizon: 1 << 16, fallbackWindows: 16)
    }

    public let search: SearchBounds
    private var reuseTolerance: UInt32 { search.reuseTolerance }
    private var searchWindow: Int { search.window }
    private var searchHorizon: UInt32 { search.horizon }

    /// Bloc par lequel `$MFT` s'agrandit hors de sa zone, hors XP : huit
    /// clusters, **un ordre de grandeur du modèle d'avant**. XP l'étend par
    /// seize enregistrements (`MFT_EXTEND_GRANULARITY`, `ntfs.h:415`), soit
    /// quatre clusters à 4 Ko, dans la zone comme ailleurs
    /// (`mftGranularityRecords`).
    private let mftGrowthClusters: UInt32 = 8

    /// Modèle d'avant, hors XP (qui n'a ni curseur ni bornes).
    ///
    /// Point de départ du prochain parcours. Il avance avec les allocations, ce
    /// qui évite que toutes les écritures se disputent les mêmes trous en tête
    /// de volume.
    private var searchCursor: UInt32 = 0

    /// Modèle d'avant, hors XP (qui n'a ni curseur ni bornes).
    ///
    /// Premier cluster derrière le dernier extent du fichier qu'on agrandit,
    /// le temps d'une extension. C'est là, et non au curseur, que la recherche
    /// commence : un système de fichiers qui étend un fichier cherche près de
    /// lui (voir l'en-tête).
    private var extensionHint: UInt32?

    /// Modèle d'avant, hors XP (qui n'a ni curseur ni bornes).
    ///
    /// Où en est l'écriture des fichiers système. Une installation de Windows
    /// pose quarante-cinq mille fichiers à la suite : elle ne redémarre pas du
    /// début du volume à chaque fichier. Le regroupement des fichiers de
    /// démarrage en tête de volume n'est pas le fait de l'allocateur, c'est
    /// celui du défragmenteur, qui repasse plus tard avec `Layout.ini` en main.
    private var systemCursor: UInt32 = 0

    // MARK: - L'état du pilote de XP (`NTFSAllocator+XP.swift`)

    /// Le volume est-il servi par l'allocateur de XP ? Les autres systèmes
    /// gardent le modèle d'avant.
    public let followsXP: Bool
    /// Le cache des runs libres (`NTFS_CACHED_RUNS`).
    var cache = NTFSFreeRunCache()
    /// Les clusters libérés depuis le dernier point de contrôle, masqués aux
    /// recherches (`DeallocatedClusterListHead`).
    var pending: [Extent] = []
    var pendingClusters: UInt32 = 0
    /// Où commence le dernier recours pour un fichier neuf
    /// (`Vcb->LastBitmapHint`).
    var lastBitmapHint: UInt32 = 0
    /// Ce qu'il a fait depuis le formatage.
    public internal(set) var xpCounters = NTFSXPCounters()
    /// La zone a été réduite sous un seizième d'espace libre
    /// (`VCB_STATE_REDUCED_MFT`).
    var reducedMFT = false
    /// Clusters libérés, et le plus long run libéré, depuis le dernier
    /// balayage de la bitmap (`ClustersRecentlyFreed`, `LongestFreedRun`).
    var recentlyFreedClusters: UInt32 = 0
    var longestFreedRun: UInt32 = 0
    /// La bitmap de la MFT (son attribut `$BITMAP`) : un bit par
    /// enregistrement en service, les seize du système compris.
    var recordBits: [UInt64] = [0xFFFF]
    /// Le plus petit enregistrement peut-être libre
    /// (`RecordAllocationContext.StartingHint`).
    var recordHint: UInt32 = 16
    var recordsInUse: UInt32 = 16

    public init(profile: NTFSProfile = NTFSProfile(),
                clusterCount: UInt32,
                initialMFTRecords: UInt64? = nil,
                formatting: Formatting = .xp,
                search: SearchBounds = .standard) {
        precondition(profile.supports(clusterCount: clusterCount))
        let initialMFTRecords = initialMFTRecords ?? formatting.initialMFTRecords
        self.ntfs = profile
        self.search = search
        self.bitmap = ClusterBitmap(clusterCount: clusterCount)
        self.mftRecordCount = initialMFTRecords
        self.mftPeakRecords = initialMFTRecords

        let layout = Self.layout(profile: profile, clusterCount: clusterCount,
                                 formatting: formatting,
                                 initialMFTRecords: initialMFTRecords)
        self.renewableZoneClusters = formatting.renewableZoneBytes.map { profile.clusters(forBytes: $0) } ?? 0
        self.frontRange = layout.dataFront
        bitmap.allocate(layout.boot)
        self.mftMirror = layout.mirror
        bitmap.allocate(self.mftMirror)
        self.logFile = layout.logFile
        bitmap.allocate(self.logFile)

        let mftStart = layout.mftStart
        let mftClusters = layout.mftClusters
        bitmap.allocate(start: mftStart, length: mftClusters)
        self.mft = FileEntry(id: 0,
                             logicalSize: initialMFTRecords * 1_024,
                             extents: [Extent(start: mftStart, length: mftClusters)],
                             hint: .system)
        self.bootExtent = layout.boot

        let zoneStart = mftStart + mftClusters
        self.mftZone = zoneStart..<max(layout.mftZoneEnd, zoneStart)
        self.volumeBitmap = layout.bitmap
        bitmap.allocate(layout.bitmap)
        let extras = [layout.mftBitmap, layout.attrDef, layout.upCase].filter { !$0.isEmpty }
        for extent in extras { bitmap.allocate(extent) }
        self.formatExtras = extras
        if let root = layout.rootIndex, !root.isEmpty {
            bitmap.allocate(root)
            self.formattedRootIndex = root
        } else {
            self.formattedRootIndex = nil
        }
        // Le premier vierge est devant la MFT quand `FORMAT` l'a posée à
        // 3 Gio : c'est là que les données commencent.
        self.highWater = layout.dataFront.isEmpty
            ? max(zoneStart, self.mftMirror.end, self.logFile.end, layout.bitmap.end)
            : layout.dataFront.lowerBound
        self.followsXP = formatting == .xp
        // Le volume est monté dès qu'il est formaté.
        if followsXP { xpMount() }
    }

    /// La zone MFT renouvelable de Vista et de Windows 7, en clusters ; 0 pour
    /// une zone en part du volume.
    private let renewableZoneClusters: UInt32
    /// Les clusters devant `$MFT` où les données ont le droit d'aller.
    private let frontRange: Range<UInt32>

    /// Où `FORMAT` pose les métafichiers d'un volume neuf.
    ///
    /// La règle est publique parce qu'elle a deux lecteurs : l'allocateur, qui
    /// y réserve les clusters, et le modèle de volume du simulateur
    /// (`PartitionGeometry`), qui doit aller lire et écrire **au même endroit**
    /// — sans quoi le montage lirait la MFT là où le générateur a posé le
    /// miroir.
    public struct Layout: Sendable, Equatable {
        /// `$Boot` : les huit premiers kilo-octets du volume.
        public let boot: Extent
        /// `$MFTMirr` : la copie des quatre premiers enregistrements de la MFT.
        public let mirror: Extent
        /// `$LogFile` : le journal des métadonnées.
        public let logFile: Extent
        /// L'attribut `$BITMAP` de `$MFT` : un bit par enregistrement, que
        /// l'analyse de `dfrgntfs` lit avant la MFT. Sous XP, le cluster qui
        /// précède `$MFT` ; vide ailleurs, où le modèle ne le pose pas.
        public let mftBitmap: Extent
        /// Premier cluster de `$MFT`.
        public let mftStart: UInt32
        /// Taille initiale de `$MFT`, en clusters.
        public let mftClusters: UInt32
        /// Fin de la zone MFT d'origine, la place qu'elle réserve comprise.
        public let mftZoneEnd: UInt32
        /// `$Bitmap` : un bit par cluster, arrondi à huit octets
        /// (`bitfrs.cxx:185-199`). Sous XP, **au milieu du volume**, derrière
        /// `$MFTMirr` et `$AttrDef` : `FORMAT` la crée sans place imposée,
        /// et son allocateur la pose là où il en est (`format.cxx:991`,
        /// `ntfsbit.cxx:452-460, 585`). Ailleurs, derrière la zone MFT, là
        /// où `mkntfs` pose ses métafichiers non résidents
        /// (`allocate_scattered_clusters`, qui part de `g_mft_zone_end`).
        /// C'est là que le simulateur lit et écrit la table.
        public let bitmap: Extent
        /// `$AttrDef` (2 560 octets, `attrdef.cxx:451`) et `$UpCase`
        /// (128 Ko, `upcase.hxx:248, 272`), posés par `FORMAT` de XP autour
        /// de `$Bitmap`. Vides ailleurs.
        public let attrDef: Extent
        public let upCase: Extent
        /// L'allocation de l'index racine (un tampon de 4 Ko,
        /// `SMALL_INDEX_BUFFER_SIZE`), la dernière chose que `FORMAT` de XP
        /// pose au milieu (`format.cxx:1175`). `nil` ailleurs.
        public let rootIndex: Extent?
        /// Les clusters devant `$MFT` où les données ordinaires se posent :
        /// les premiers gigaoctets d'un volume XP, Vista ou 7, le journal et
        /// la bitmap de la MFT compris sous XP ; rien sous NT.
        public let dataFront: Range<UInt32>
    }

    public static func layout(profile: NTFSProfile, clusterCount: UInt32,
                              formatting: Formatting,
                              initialMFTRecords: UInt64? = nil) -> Layout {
        let initialMFTRecords = initialMFTRecords ?? formatting.initialMFTRecords
        // $Boot occupe les huit premiers kilo-octets du volume — deux clusters
        // à 4 Ko, et non un (`BYTES_IN_BOOT_AREA`, `untfs.hxx:67`). La copie
        // du secteur d'amorçage, au tout dernier secteur du volume, ne coûte
        // aucun cluster, et le pilote ne la lit que si le secteur 0 est
        // illisible (`fsctrl.c:5015-5046`).
        let bootClusters = max(profile.clusters(forBytes: 8 * 1_024), 1)
        let mftClusters = max(profile.clusters(forBytes: initialMFTRecords * 1_024), 1)
        let zoneClusters = formatting.renewableZoneBytes.map { profile.clusters(forBytes: $0) }
            ?? UInt32(Double(clusterCount) * profile.mftZoneShare)

        // $MFTMirr : la copie des **quatre premiers enregistrements** de la
        // MFT, soit 4 Ko, soit un cluster à 4 Ko — et non quatre. Au milieu du
        // volume de NT 4 à Vista, au LCN 2 depuis Windows 7 (Sedory).
        let mirrorClusters = max(profile.clusters(forBytes: 4 * 1_024), 1)

        if formatting == .xp {
            return xpLayout(profile: profile, clusterCount: clusterCount,
                            bootClusters: bootClusters, mftClusters: mftClusters,
                            zoneClusters: zoneClusters, mirrorClusters: mirrorClusters)
        }

        let mirrorStart: UInt32 = formatting.mirrorInTheMiddle
            ? clusterCount / 2
            : min(2, clusterCount - mirrorClusters)
        let mirror = Extent(start: max(mirrorStart, bootClusters), length: mirrorClusters)

        // Hors XP, le modèle d'avant le chantier 48 : $LogFile suit le miroir,
        // comme le pose `mkntfs`, et sa taille suit les paliers de `mkntfs`
        // — 64 Mio à partir de 12 Gio de volume, 4 Mio en dessous, 2 Mio sous
        // 200 Mio ; le plafond au seizième du volume ne sert qu'aux volumes
        // d'essai de quelques centaines de clusters.
        let volumeBytes = UInt64(clusterCount) * UInt64(profile.clusterBytes)
        let logBytes: UInt64 = volumeBytes >= 12 << 30 ? 64 << 20
            : volumeBytes >= 200 << 20 ? 4 << 20
            : 2 << 20
        let logClusters = max(min(profile.clusters(forBytes: logBytes), clusterCount / 16), 1)
        let logFile = Extent(start: mirror.end, length: logClusters)

        // $MFT : à 3 Gio sous Vista et 7 — au huitième du volume quand il
        // fait moins, une règle du modèle —, et en tête sous NT. Ce qui
        // précède (le journal en tête sous Windows 7) la repousse d'autant.
        let head = formatting.mirrorInTheMiddle ? bootClusters : max(logFile.end, bootClusters)
        let threeGibibytes = UInt32(min(UInt64(3) << 30 / UInt64(profile.clusterBytes),
                                        UInt64(clusterCount / 8)))
        let mftStart = formatting.mftAtThreeGibibytes ? max(head, threeGibibytes) : head
        let zoneEnd = min(clusterCount, mftStart + max(zoneClusters, mftClusters))
        let bitmapClusters = volumeBitmapClusters(profile: profile, clusterCount: clusterCount)
        let bitmapStart = min(zoneEnd, clusterCount - min(bitmapClusters, clusterCount))
        // Les clusters libres devant la MFT : entre ce que `$Boot`, le miroir
        // et le journal occupent en tête, et la MFT. Vide sous NT.
        let front = head..<mftStart
        let none = Extent(start: mftStart, length: 0)
        return Layout(boot: Extent(start: 0, length: bootClusters),
                      mirror: mirror, logFile: logFile,
                      mftBitmap: none, mftStart: mftStart,
                      mftClusters: mftClusters, mftZoneEnd: zoneEnd,
                      bitmap: Extent(start: bitmapStart, length: bitmapClusters),
                      attrDef: none, upCase: none, rootIndex: nil,
                      dataFront: front)
    }

    /// `$Bitmap` : ceil(clusters/8) octets, arrondis à huit, puis au cluster
    /// (`bitfrs.cxx:185-199`).
    private static func volumeBitmapClusters(profile: NTFSProfile, clusterCount: UInt32) -> UInt32 {
        let bytes = ((UInt64(clusterCount) + 7) / 8 + 7) / 8 * 8
        return max(profile.clusters(forBytes: bytes), 1)
    }

    /// La taille de `$LogFile` que choisit `FORMAT` de XP
    /// (`NTFS_LOG_FILE::QueryDefaultSize`, `logfile.cxx:48-56, 869-888`) :
    /// 1 % du volume jusqu'à 400 Mo, au moins 2 Mo ; au-delà, 4 Mo plus un
    /// deux-centième de ce qui dépasse 400 Mo, plafonné à 64 Mo ; arrondi à
    /// 16 Ko. Une rampe, pas des paliers : 12 Mo sur 2 Go, 43 Mo sur 8 Go,
    /// le plafond vers 12,1 Gio. Au-delà de 2³² secteurs, 64 Mo d'office.
    public static func xpLogFileBytes(volumeBytes: UInt64) -> UInt64 {
        let maximum: UInt64 = 0x400_0000, minimum: UInt64 = 0x20_0000
        let slowdown: UInt64 = 400 * 1_024 * 1_024
        guard volumeBytes / 512 < 1 << 32 else { return maximum }
        var size: UInt64
        if volumeBytes <= slowdown {
            size = max(volumeBytes / 100, minimum)
        } else {
            size = min((volumeBytes - slowdown) / 200 + slowdown / 100, maximum)
        }
        return (size + 0x3FFF) & ~UInt64(0x3FFF)
    }

    /// La disposition de `FORMAT` sous XP SP1, dans l'ordre où il alloue
    /// (`NTFS_SA::Create`, `format.cxx:490-1175`). Son allocateur
    /// (`NTFS_BITMAP::AllocateClusters`) cherche vers l'avant à partir de
    /// la place qu'on lui donne, ou de `_NextAlloc`, qui avance derrière
    /// chaque allocation (`ntfsbit.cxx:452-460, 585`) :
    ///
    /// 1. `$Boot`, les huit premiers kilo-octets ;
    /// 2. `$MFT`, 16 enregistrements (`FIRST_USER_FILE_NUMBER`), à 3 Gio
    ///    sur un volume d'au moins 6 Gio, à 1 Gio de 2 à 6 Gio, au tiers
    ///    en dessous (`format.cxx:585-593`) ;
    /// 3. la bitmap de la MFT, un cluster juste devant elle
    ///    (`_FirstLcn - ClustersInMftBitmap`, `mftfile.cxx:289-293`) ;
    /// 4. `$LogFile`, qui finit à `MftLcn` moins les 8 Ko réservés à la
    ///    bitmap de la MFT (`LogFileNearLcn`, `format.cxx:617-618`) :
    ///    `SetNextAlloc(NearLcn - ClustersInData)` le pose là
    ///    (`logfile.cxx:223-233`). À 4 Ko, un cluster libre le sépare de la
    ///    bitmap de la MFT ;
    /// 5. `$MFTMirr` au milieu (`(secteurs/2)/facteur`, `mftref.cxx:177-182`) ;
    /// 6. sans place imposée, donc derrière lui : `$AttrDef` (904),
    ///    `$Bitmap` (991), `$UpCase` (1131), puis l'allocation de l'index
    ///    racine quand l'index est sauvé (1175). Le schéma en tête de la
    ///    fonction dit le même ordre (`format.cxx:329-341`).
    ///
    /// Le secteur des paliers est celui du volume, `clusterCount ×` secteurs
    /// par cluster, à un cluster près. Ce que le modèle ajoute : le plafond
    /// du journal au seizième du volume, pour les volumes d'essai de
    /// quelques centaines de clusters, et le saut par-dessus la MFT quand le
    /// milieu tombe dessus (un volume de 2 ou de 6 Gio tout juste), que
    /// l'allocateur de `FORMAT` fait en cherchant vers l'avant.
    private static func xpLayout(profile: NTFSProfile, clusterCount: UInt32,
                                 bootClusters: UInt32, mftClusters: UInt32,
                                 zoneClusters: UInt32, mirrorClusters: UInt32) -> Layout {
        let clusterBytes = UInt64(profile.clusterBytes)
        let clusterSectors = max(clusterBytes / 512, 1)
        let volumeSectors = UInt64(clusterCount) * clusterSectors + 1
        let oneGibibyte: UInt64 = 1 << 30
        let lcn: UInt64
        if volumeSectors < 2 * oneGibibyte / 512 {
            lcn = volumeSectors / 3 / clusterSectors
        } else if volumeSectors < 6 * oneGibibyte / 512 {
            lcn = oneGibibyte / clusterBytes
        } else {
            lcn = 3 * oneGibibyte / clusterBytes
        }
        let volumeBytes = UInt64(clusterCount) * clusterBytes
        let logClusters = max(min(profile.clusters(forBytes: xpLogFileBytes(volumeBytes: volumeBytes)),
                                  clusterCount / 16), 1)
        let reserved = max(profile.clusters(forBytes: 8 * 1_024), 1)   // MFT_BITMAP_INITIAL_SIZE
        let mftStart = max(UInt32(min(lcn, UInt64(clusterCount / 2))),
                           bootClusters + logClusters + reserved)
        let mftBitmap = Extent(start: mftStart - 1, length: 1)
        let logFile = Extent(start: mftStart - reserved - logClusters, length: logClusters)

        // Le milieu, puis ce que `_NextAlloc` pose derrière lui.
        let mftEnd = mftStart + mftClusters
        var next = clusterCount / 2
        func take(_ length: UInt32) -> Extent {
            if next < mftEnd, next + length > mftBitmap.start { next = mftEnd }
            defer { next += length }
            return Extent(start: next, length: length)
        }
        let mirror = take(mirrorClusters)
        let attrDef = take(max(profile.clusters(forBytes: 2_560), 1))
        let bitmap = take(volumeBitmapClusters(profile: profile, clusterCount: clusterCount))
        let upCase = take(max(profile.clusters(forBytes: 0x10000 * 2), 1))
        let rootIndex = take(max(profile.clusters(forBytes: 4_096), 1))

        let zoneEnd = min(clusterCount, mftStart + max(zoneClusters, mftClusters))
        return Layout(boot: Extent(start: 0, length: bootClusters),
                      mirror: mirror, logFile: logFile,
                      mftBitmap: mftBitmap, mftStart: mftStart,
                      mftClusters: mftClusters, mftZoneEnd: zoneEnd,
                      bitmap: bitmap, attrDef: attrDef, upCase: upCase,
                      rootIndex: rootIndex,
                      dataFront: bootClusters..<mftStart)
    }

    // MARK: - Zones

    /// `$Boot`, la MFT, `$MFTMirr`, `$LogFile` et `$Bitmap` — et, sous XP, la
    /// bitmap de la MFT, `$AttrDef` et `$UpCase` : tout ce que le volume
    /// occupe sans qu'aucun fichier du catalogue ne le décrive.
    public var systemExtents: [Extent] {
        [bootExtent] + mft.extents + [mftMirror, logFile, volumeBitmap] + formatExtras
    }

    public var metadataExtents: [Extent] { systemExtents }

    /// La zone MFT a-t-elle encore toute sa taille d'origine ?
    public var mftZoneIsProtected: Bool { !mftZoneBreached }

    /// Plages dans lesquelles les données ordinaires ont le droit d'aller :
    /// tout le volume **sauf la zone courante** — ce qui la précède d'abord
    /// (les 3 premiers Gio et `$MFT` depuis XP), puis ce qui la suit.
    ///
    /// La plage de devant finit au début de la zone courante, et non au début
    /// de `$MFT` (B#8, `AUDIT_REALISME.md`) : quand Vista ou 7 réservent une
    /// tranche neuve derrière le vierge, tout le milieu du volume, entre
    /// l'ancienne zone et la nouvelle, reste de l'espace de données. XP ne
    /// réserve que `MftZoneStart..MftZoneEnd` (`bitmpsup.c:3872-3905`).
    private var dataRanges: [Range<UInt32>] {
        let end = bitmap.clusterCount
        guard !mftZone.isEmpty else {
            return frontRange.isEmpty ? [0..<end] : [frontRange, 0..<end]
        }
        let back = mftZone.upperBound..<end
        // Sous NT, `$MFT` est en tête : rien de libre devant la zone qu'elle
        // n'ait déjà pris.
        let start = frontRange.isEmpty ? mft.extents[0].end : frontRange.lowerBound
        return mftZone.lowerBound > start ? [start..<mftZone.lowerBound, back] : [back]
    }

    /// Le reste du volume est plein : la zone rend la moitié de sa queue.
    ///
    /// La queue est ce que la MFT n'a pas encore occupé. C'est la seule règle
    /// que publient les descriptions de NTFS (« each time the rest of the disk
    /// becomes full, the buffer size is halved », documentation Linux-NTFS) ;
    /// Microsoft ne détaille pas l'algorithme. La moitié rendue est la plus
    /// éloignée de la MFT, pour que celle-ci garde de quoi grandir d'un seul
    /// tenant.
    ///
    /// Si la MFT a déjà débordé de sa zone, aucun de ses extents n'y finit, et
    /// la moitié se compte depuis le début de la zone : elle cède la moitié de
    /// ce qui lui reste, pas tout.
    ///
    /// - Returns: `false` si la zone n'a plus rien à rendre.
    mutating func yieldMFTZone() -> Bool {
        let mftEnd = mft.extents.map(\.end).filter { mftZone.contains($0) }.max()
            ?? mftZone.lowerBound
        let tailStart = max(mftZone.lowerBound, mftEnd)
        guard mftZone.upperBound > tailStart else {
            guard !mftZone.isEmpty else { return false }
            mftZone = mftZone.lowerBound..<mftZone.lowerBound
            mftZoneHalvings += 1
            return true
        }
        let tail = mftZone.upperBound - tailStart
        let upper = tailStart + tail / 2
        mftZone = mftZone.lowerBound..<(upper > tailStart ? upper : mftZone.lowerBound)
        mftZoneHalvings += 1
        return true
    }

    // MARK: - Allocation

    public mutating func allocate(clusterCount count: UInt32, hint: AllocationHint) -> [Extent] {
        guard count > 0, count <= bitmap.freeCount else { return [] }
        if followsXP {
            // Un fichier neuf, de taille connue : exactement ce qu'il faut.
            // XP n'a pas d'indice « système » ; seul le fichier d'échange a
            // sa règle (`.reservedContiguous`, que seul `pagefile.sys` porte
            // sur un volume de XP).
            return xpAllocateClusters(core: count, desired: count, preceding: nil,
                                      paging: hint == .reservedContiguous) ?? []
        }
        // Tant que la place manque hors de la zone, la zone cède de moitié. Un
        // échec de placement hors zone n'arrive que si le reste du volume n'a
        // plus assez de clusters libres : `scatter` prend n'importe quels
        // morceaux.
        while true {
            for range in dataRanges {
                let extents = place(count, hint: hint, in: range)
                if !extents.isEmpty { return extents }
            }
            guard yieldMFTZone() else { return [] }
        }
    }

    private mutating func place(_ count: UInt32, hint: AllocationHint,
                                in range: Range<UInt32>) -> [Extent] {
        switch hint {
        case .reservedContiguous:
            // `pagefile.sys` à taille fixe, `hiberfil.sys` : d'un seul tenant
            // tant que le volume a un bloc capable de les accueillir.
            if let run = contiguousRun(for: count, in: range) {
                return commit([run])
            }

        case .system:
            // Les fichiers système s'écrivent à la suite les uns des autres, en
            // tête de la zone de données, là où les pistes sont les plus
            // rapides.
            let from = max(systemCursor, range.lowerBound)
            if let run = bitmap.firstFitRun(minLength: count, maxLength: count, from: from),
               run.end <= range.upperBound {
                systemCursor = run.end
                return commit([run])
            }
            // Le curseur système avance même quand il ne trouve rien : sinon
            // chaque mise à jour rebalaie la même zone pleine depuis le début.
            // La tête du volume est pleine ; ce fichier-ci est traité comme les
            // autres, et le suivant cherchera plus loin.
            systemCursor = min(max(systemCursor, range.lowerBound) &+ searchHorizon,
                               range.upperBound)

        case .normal:
            break
        }

        if let run = preferredRun(for: count, in: range) {
            return commit([run])
        }
        return commit(scatter(count, in: range))
    }

    /// Choix du trou : best-fit d'abord, mais sans casser un grand bloc pour un
    /// petit fichier tant qu'il reste du vierge derrière le `highWater`.
    ///
    /// Le parcours commence au curseur pour un fichier neuf, derrière le
    /// dernier extent du fichier pour une extension.
    private func preferredRun(for count: UInt32, in range: Range<UInt32>) -> Extent? {
        let origin = extensionHint ?? searchCursor

        // Le best-fit ne travaille que sur la partie du volume déjà servie :
        // au-delà du `highWater` il n'y a qu'un seul trou, celui qui reste, et
        // le confronter aux autres n'a aucun sens.
        let used = range.lowerBound..<min(max(highWater, range.lowerBound), range.upperBound)
        // Un trou plus grand que le double du besoin n'intéresse pas cette
        // recherche : l'allocateur préférera l'espace vierge plutôt que de
        // couper un grand bloc en deux. Le dire à la bitmap lui évite de mesurer
        // ces trous-là jusqu'au bout.
        let (doubled, overflow) = count.multipliedReportingOverflow(by: reuseTolerance)
        let tolerable = overflow ? UInt32.max : doubled

        if used.lowerBound < used.upperBound,
           let fit = bitmap.bestFitRun(minLength: count, in: used,
                                       from: origin,
                                       maxRunsExamined: searchWindow,
                                       maxClustersScanned: searchHorizon,
                                       measureLimit: tolerable),
           fit.length <= tolerable {
            return Extent(start: fit.start, length: count)
        }

        // Espace vierge : au-delà du `highWater`, il n'y a qu'un seul trou, et
        // le fichier se pose à son début. Une plage entièrement derrière le
        // `highWater` — les 3 Gio devant la MFT, une fois remplis — n'en a
        // plus.
        let virginStart = max(highWater, range.lowerBound)
        let virgin = virginStart..<max(range.upperBound, virginStart)
        if virgin.lowerBound < virgin.upperBound,
           let run = bitmap.firstFitRun(minLength: count, maxLength: count,
                                        from: virgin.lowerBound),
           run.start < virgin.upperBound, run.end <= virgin.upperBound {
            return Extent(start: run.start, length: count)
        }

        // Plus de vierge : on reprend le volume par fenêtres successives. Pour
        // un fichier neuf, depuis le début de la zone de données ; pour une
        // extension, depuis le fichier, en revenant au début une fois la fin
        // du volume atteinte. Rescanner tout le volume à chaque écriture
        // coûterait, sur un disque de 2007, plus d'une minute pour une seule
        // génération — et surtout, aucun pilote ne fait cela.
        var probe = range.lowerBound
        var wrapped = true
        if let hint = extensionHint, hint > range.lowerBound, hint < range.upperBound {
            probe = hint
            wrapped = false
        }
        var windows = 0
        while windows < search.fallbackWindows {
            if probe >= range.upperBound {
                guard !wrapped else { break }
                wrapped = true
                probe = range.lowerBound
            }
            if let fit = bitmap.bestFitRun(minLength: count, in: range,
                                           from: probe,
                                           maxRunsExamined: searchWindow,
                                           maxClustersScanned: searchHorizon,
                                           measureLimit: tolerable) {
                return Extent(start: fit.start, length: count)
            }
            probe = probe &+ searchHorizon
            windows += 1
        }
        return nil
    }

    /// Dernier recours : le volume n'a plus un seul bloc assez grand, le fichier
    /// est réparti sur les plus gros morceaux disponibles. C'est ce qui arrive
    /// à tout ce qu'on écrit sur un volume à 95 %.
    private func scatter(_ count: UInt32, in range: Range<UInt32>) -> [Extent] {
        var extents: [Extent] = []
        var remaining = count
        var position = range.lowerBound

        while remaining > 0, position < range.upperBound {
            guard let run = bitmap.nextFreeRun(from: position, limit: remaining) else { break }
            guard run.start < range.upperBound else { break }
            let take = min(run.length, remaining, range.upperBound - run.start)
            guard take > 0 else { break }
            extents.appendRun(start: run.start, length: take)
            remaining -= take
            position = run.start + run.length
        }
        return remaining == 0 ? extents : []
    }

    private mutating func commit(_ extents: [Extent]) -> [Extent] {
        for extent in extents { commit(extent) }
        return extents
    }

    private mutating func commit(_ extent: Extent) {
        bitmap.allocate(extent)
        highWater = max(highWater, extent.end)
        // Le curseur suit l'écriture : la place suivante est cherchée à
        // partir d'ici, pas depuis le début du volume.
        searchCursor = extent.end < bitmap.clusterCount ? extent.end : 0
    }

    /// Prolonger d'abord, chercher ensuite. C'est toute la différence de texture
    /// avec FAT sur les fichiers réécrits.
    @discardableResult
    public mutating func extend(file: inout FileEntry, byClusters count: UInt32) -> Bool {
        guard count > 0 else { return true }
        if followsXP {
            // `PrecedingLcn` : le dernier cluster du fichier. Le prolongement
            // n'est pas une étape à part : c'est le run du cache qui commence
            // juste derrière lui, s'il y est.
            guard let added = xpAllocateClusters(core: count, desired: count,
                                                 preceding: file.extents.last.map { $0.end - 1 },
                                                 paging: file.hint == .reservedContiguous)
            else { return false }
            for extent in added { file.extents.appendRun(start: extent.start, length: extent.length) }
            return true
        }
        var remaining = count
        var prolonged: Extent?

        if let last = file.extents.last, last.end < bitmap.clusterCount {
            let contiguous = min(bitmap.freeRunLength(at: last.end, limit: remaining), remaining)
            if contiguous > 0 {
                let run = Extent(start: last.end, length: contiguous)
                commit(run)
                prolonged = run
                remaining -= contiguous
            }
        }

        if remaining > 0 {
            // Le complément est cherché à partir du fichier : c'est le « last
            // allocated cluster » du pilote de Linux, et non la position
            // courante de l'allocateur.
            extensionHint = file.extents.last.map { prolonged?.end ?? $0.end }
            let added = allocate(clusterCount: remaining, hint: file.hint)
            extensionHint = nil
            guard !added.isEmpty else {
                // Le complément n'a pas pu être placé : on rend ce qui venait
                // d'être pris, pour que le fichier ressorte intact.
                if let prolonged { bitmap.free(prolonged) }
                return false
            }
            if let prolonged { file.extents.appendRun(start: prolonged.start, length: prolonged.length) }
            for extent in added { file.extents.appendRun(start: extent.start, length: extent.length) }
            return true
        }

        if let prolonged { file.extents.appendRun(start: prolonged.start, length: prolonged.length) }
        return true
    }

    /// La libération est immédiate — l'espace est rendu, le compte est juste —
    /// mais le curseur de recherche ne recule pas pour autant. C'est la
    /// « réutilisation paresseuse » de NTFS : un trou qui vient de s'ouvrir
    /// n'est pas repris à l'écriture suivante, il attend que le parcours
    /// repasse devant. D'où ces trous qui persistent au milieu d'un volume par
    /// ailleurs contigu, et qu'aucun FAT ne produit jamais.
    ///
    /// Sous XP, la libération est immédiate dans la bitmap, mais les clusters
    /// restent masqués jusqu'au point de contrôle (`NtfsDeallocateClusters`,
    /// `bitmpsup.c:1750-1798`).
    public mutating func free(_ extents: [Extent]) {
        if followsXP {
            xpRelease(extents)
            return
        }
        bitmap.free(extents)
    }

    /// Un fichier que son programme écrit sans en connaître la taille : sous
    /// XP, l'extension à l'écriture et le surplus rendu à la fermeture
    /// (`xpStream`) ; ailleurs, les paquets de 64 Ko du modèle d'avant.
    @discardableResult
    public mutating func stream(file: inout FileEntry, clusters count: UInt32) -> Bool {
        followsXP ? xpStream(file: &file, clusters: count) : streamByPackets(file: &file, clusters: count)
    }

    /// Sous XP, le plus petit enregistrement libre à partir du seizième
    /// (`FIRST_USER_FILE_NUMBER`) : `RtlFindClearBits` depuis `StartingHint`,
    /// que chaque libération ramène vers le bas (`bitmpsup.c:5339, 5777,
    /// 7819-7822`). Un fichier créé après une suppression prend la place du
    /// disparu (`ntfs-alloc-12`).
    public mutating func takeRecord() -> UInt32? {
        guard followsXP else { return nil }
        var word = Int(recordHint >> 6)
        while word < recordBits.count, recordBits[word] == ~0 { word += 1 }
        if word == recordBits.count { recordBits.append(0) }
        let masked = recordBits[word] | (word == Int(recordHint >> 6) ? (UInt64(1) << UInt64(recordHint & 63)) &- 1 : 0)
        var bit = (~masked).trailingZeroBitCount
        if bit == 64 {
            // Les bits sous l'indice étaient libres mais masqués : le mot est
            // plein au-delà, le suivant a la place.
            word += 1
            while word < recordBits.count, recordBits[word] == ~0 { word += 1 }
            if word == recordBits.count { recordBits.append(0) }
            bit = (~recordBits[word]).trailingZeroBitCount
        }
        recordBits[word] |= UInt64(1) << UInt64(bit)
        recordsInUse += 1
        let record = UInt32(word << 6 + bit)
        recordHint = record + 1
        return record
    }

    public mutating func releaseRecord(_ record: UInt32) {
        guard followsXP, record >= 16, Int(record >> 6) < recordBits.count else { return }
        let mask = UInt64(1) << UInt64(record & 63)
        guard recordBits[Int(record >> 6)] & mask != 0 else { return }
        recordBits[Int(record >> 6)] &= ~mask
        recordsInUse -= 1
        recordHint = min(recordHint, record)
    }

    /// Le volume est monté : sous XP, le cache des runs libres est rebâti de
    /// la bitmap (`NTFSAllocator+XP.swift`).
    public mutating func mount() {
        if followsXP { xpMount() }
    }

    /// Un point de contrôle du journal : sous XP, les clusters libérés depuis
    /// le précédent entrent dans le cache.
    public mutating func checkpoint() {
        if followsXP { xpCheckpoint() }
    }

    /// L'enregistrement du fichier disparu retourne au pot commun.
    public mutating func noteFileDeleted() {
        if mftRecordCount > 0 { mftRecordCount -= 1 }
    }

    /// Prise d'une plage imposée, pour un défragmenteur.
    @discardableResult
    public mutating func claim(_ extent: Extent) -> Bool {
        guard bitmap.isFree(extent) else { return false }
        if followsXP {
            // Un `FSCTL_MOVE_FILE` vers des clusters tout juste libérés lève
            // `STATUS_DELETE_PENDING` ; le pilote vide alors le journal, rend
            // tous les clusters retenus et recommence (`bitmpsup.c:9046-9067`,
            // `deviosup.c:10360-10390`).
            if pending.contains(where: { $0.start < extent.end && extent.start < $0.end }) {
                xpCheckpoint()
            }
            xpTake(extent)
            return true
        }
        bitmap.allocate(extent)
        highWater = max(highWater, extent.end)
        return true
    }

    // MARK: - Croissance de la MFT

    /// Un fichier de plus, c'est un enregistrement MFT de plus — qu'il soit
    /// résident ou non. Vingt mille fichiers source font vingt mégaoctets de
    /// MFT, et c'est cette table-là, pas les données, qui domine un volume de
    /// développeur.
    public mutating func noteFileCreated(logicalSize: UInt64) {
        mftRecordCount += 1
        guard mftRecordCount > mftPeakRecords else { return }
        mftPeakRecords = mftRecordCount

        if followsXP {
            let granularity = mftGranularityRecords
            let records = (mftPeakRecords + granularity - 1) / granularity * granularity
            let needed = ntfs.clusters(forBytes: records * ntfs.directoryEntryBytes)
            mft.logicalSize = mftPeakRecords * ntfs.directoryEntryBytes
            if needed > mft.clusterCount { xpExtendMFT(byClusters: needed - mft.clusterCount) }
            return
        }
        let needed = ntfs.clusters(forBytes: mftPeakRecords * ntfs.directoryEntryBytes)
        let owned = mft.clusterCount
        mft.logicalSize = mftPeakRecords * ntfs.directoryEntryBytes
        guard needed > owned else { return }

        var remaining = needed - owned

        // La MFT grandit d'abord dans sa zone réservée, donc d'un seul tenant.
        if let last = mft.extents.last, last.end < bitmap.clusterCount {
            let room = min(bitmap.freeRunLength(at: last.end, limit: remaining), remaining)
            if room > 0 {
                let run = Extent(start: last.end, length: room)
                takeForMFT(run)
                highWater = max(highWater, run.end)
                mft.extents.appendRun(start: run.start, length: run.length)
                remaining -= room
            }
        }

        // Vista et Windows 7 : la zone est de 200 Mo, et quand la MFT l'a
        // remplie « the MFT will create another 200MB zone to grow into »
        // (KB 961095) — une tranche neuve, contiguë, réservée derrière le
        // vierge, où la MFT continue d'un seul tenant.
        if remaining > 0, renewableZoneClusters > 0,
           let run = bitmap.firstFitRun(minLength: renewableZoneClusters,
                                        maxLength: renewableZoneClusters,
                                        from: max(highWater, mftZone.upperBound)),
           run.end <= bitmap.clusterCount {
            let taken = Extent(start: run.start, length: min(remaining, run.length))
            takeForMFT(taken)
            highWater = max(highWater, run.end)
            mft.extents.appendRun(start: taken.start, length: taken.length)
            mftZone = taken.end..<run.end
            remaining -= taken.length
            if remaining == 0 { return }
        }

        // Sa zone est pleine ou entamée : la MFT part chercher de la place
        // ailleurs, et se fragmente. C'est le symptôme classique d'un volume
        // NTFS qu'on a laissé se remplir. Reste à se fragmenter comme elle le
        // faisait, et non comme un ramasse-miettes.
        //
        // Deux choses la cassaient. Un `bestFitRun(minLength: 1)` sur tout le
        // volume rend le **plus petit trou du disque**, presque toujours d'un
        // cluster ; et il était appelé à chaque fichier créé, parce qu'un
        // fichier de plus ne réclame qu'un cluster de table. La MFT de
        // `dev-2003` sortait ainsi en 348 extents pour 4 653 clusters, quand un
        // volume maltraité pendant des années en montre quelques dizaines.
        //
        // Un vrai NTFS fait l'inverse des deux : il agrandit `$MFT` par
        // **paquets**, et il les pose **au plus près de la table**. Le premier
        // point espace les demandes ; le second est celui qui compte vraiment,
        // parce que deux paquets pris à la suite dans le même grand trou se
        // touchent, et que `coalesced()` n'en fait alors qu'un seul extent. Un
        // best-fit, lui, les disperse par construction : il cherche le trou le
        // plus juste, donc un trou différent à chaque fois.
        //
        // Le premier trou venu se lit dans la bitmap par mots de soixante-quatre
        // bits sans mesurer ce qu'il enjambe : les bornes `searchWindow` et
        // `searchHorizon`, qui existent pour brider un best-fit, n'ont ici rien
        // à brider.
        while remaining > 0 {
            // Hors zone, la MFT prend un paquet entier même si elle a moins que
            // cela à placer ; dans sa zone, au contraire, elle ne prend que ce
            // qu'il lui faut — la place y est déjà à elle.
            let block = max(remaining, mftGrowthClusters)
            let floor = min(block, mftGrowthClusters)
            let nearest = mft.extents.last?.end ?? 0
            var wanted = block
            var found: Extent?
            while found == nil, wanted >= floor {
                found = bitmap.firstFitRun(minLength: wanted, maxLength: wanted, from: nearest)
                    ?? bitmap.firstFitRun(minLength: wanted, maxLength: wanted, from: 0)
                if found == nil { wanted /= 2 }
            }
            // Plus rien qui tienne un paquet entier : le volume n'a plus que
            // des miettes, et la MFT prend la plus grosse.
            guard let run = found ?? bitmap.largestFreeRun() else { break }
            let take = min(run.length, block)
            guard take > 0 else { break }
            let extent = Extent(start: run.start, length: take)
            takeForMFT(extent)
            highWater = max(highWater, extent.end)
            mft.extents.appendRun(start: extent.start, length: extent.length)
            remaining -= min(take, remaining)
        }
        mft.extents = mft.extents.coalesced()
    }

    /// Les clusters que `$MFT` prend : la bitmap, et sous XP le cache des
    /// runs libres, qui ne doit plus les offrir.
    private mutating func takeForMFT(_ extent: Extent) {
        bitmap.allocate(extent)
        if followsXP {
            cache.remove(extent)
            unpend(extent)
        }
    }
}
