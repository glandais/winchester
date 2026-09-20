import Foundation

/// Allocateur NTFS.
///
/// Trois mécanismes le séparent de FAT, et ce sont eux qui donnent aux volumes
/// de 2003 et 2007 leur allure bien plus propre :
///
/// - **best-fit** plutôt que premier trou venu : un fichier va dans le trou qui
///   lui convient, pas dans le premier rencontré ;
/// - **zone MFT**, 12,5 % du volume tenus à l'écart des données ordinaires. Tant
///   qu'il reste de la place ailleurs, l'allocateur n'y touche pas. Quand le
///   reste du volume est plein, NTFS **rend la moitié de ce qui reste libre de
///   la zone**, et recommence à chaque fois que le reste se remplit à nouveau.
///   La MFT, dont la réserve fond, finit par se fragmenter à son tour ;
/// - **prolongement en place** : agrandir un fichier, c'est d'abord essayer les
///   clusters qui suivent immédiatement son dernier extent. Un `.doc`
///   réenregistré reste contigu là où FAT en aurait fait trois morceaux. Et
///   quand la place derrière lui est prise, le complément est cherché **à
///   partir de lui**, pas à la position courante de l'allocateur : c'est ce
///   que fait le pilote NTFS de Linux (`ntfs_attr_extend_allocation`, « we
///   want to begin allocating clusters starting at the last allocated cluster
///   to reduce fragmentation »), qui ne prend la position courante que pour un
///   fichier qui n'a encore rien.
///
/// **Quatre bornes de recherche règlent la fragmentation** (`SearchBounds`),
/// et c'est la seule entorse du noyau au principe qu'elle n'est jamais un
/// paramètre. Elles existent pour le coût de calcul ; chacune se défend — voir
/// leurs commentaires —, et **aucune ne vient d'une source** : ni la
/// documentation de NTFS, ni le pilote de Linux, ni `mkntfs` ne disent jusqu'où
/// Windows cherche un trou. Ce qu'elles pèsent est mesuré, une à la fois, en
/// fichiers fragmentés parmi les fragmentables — la table que régénère
/// `CalibrationTests.ntfsSearchBoundsWeighOnFragmentation` :
///
/// | réglage                      | `famille-2003` | `secretaire-2003` | `dev-2007` | `famille-2007` |
/// |------------------------------|-------:|-------:|------:|-------:|
/// | tel quel (2, 64, 65 536)      | 7,6 %  | 13,6 % | 9,1 % | 21,1 % |
/// | `reuseTolerance` = 4          | 9,4 %  | 12,4 % | 9,2 % | 20,2 % |
/// | `reuseTolerance` = `.max`     | 5,8 %  | 13,1 % | 8,1 % | 16,5 % |
/// | `window` = 16                 | 12,8 % | 13,6 % | 7,6 % | 18,3 % |
/// | `window` = 256                | 11,1 % | 14,2 % | 8,6 % | 19,8 % |
/// | `horizon` = 16 384            | 21,2 % | 14,7 % | 6,9 % | 21,6 % |
/// | `horizon` = 262 144           | 4,6 %  | 12,6 % | 7,2 % | 12,9 % |
///
/// La quatrième, les seize fenêtres du dernier recours (`fallbackWindows`),
/// n'est pas dans la table : elle ne joue que sur un volume sans espace vierge.
///
/// Ce qui en sort :
///
/// - **elles ne poussent pas toutes vers la contiguïté.** Élargir la tolérance
///   jusqu'au best-fit pur, ou l'horizon, *réduit* la fragmentation : ce que
///   la borne fait, c'est renoncer au trou juste qui était un peu plus loin.
///   Seuls un horizon plus court ou une fenêtre changée la font monter sur
///   `famille-2003` ;
/// - **l'horizon décide le plus** : de 4,6 à 21,2 % sur `famille-2003`, quand
///   la tolérance ne va que de 5,8 à 9,4. Un facteur quatre tient à une borne
///   de recherche, et c'est ce qu'il faut dire quand on cite ce que le modèle
///   produit sur ce volume ;
/// - **ce volume est chaotique** : trois cents clusters de `$Bitmap` posés
///   derrière la zone MFT suffisent à le faire passer de 10,5 à 7,6 %. Au-delà
///   du premier chiffre, son taux ne dit rien ; les volumes moins pleins
///   bougent d'un point ou deux ;
/// - **aucune ne rejoint la cible** de 40 à 60 % sur `famille-2003`
///   (`CalibrationTests`). Le manque est ailleurs — dans l'écriture en
///   séquence de la chronologie, que l'entrelacement lèverait
///   (`DiskGenerator.runsProgramsConcurrently`).
///
/// Leur coût, lui, est sans ambiguïté : sans tolérance, la génération de
/// `dev-2007` est huit fois plus longue.
///
/// La « réutilisation paresseuse » des clusters libérés est modélisée par une
/// préférence pour l'espace jamais servi : la libération, elle, est immédiate,
/// et l'espace rendu reste disponible. Un trou n'est repris que s'il convient
/// vraiment au fichier à placer, ou quand le vierge est épuisé — d'où des trous
/// qui persistent longtemps au milieu d'un volume par ailleurs contigu, ce
/// qu'aucun FAT ne produit jamais.
public struct NTFSAllocator: Allocator {

    /// Position de `$MFTMirr`, la copie de secours des premiers enregistrements
    /// de la MFT.
    public enum MirrorPlacement: Sendable {
        /// Au milieu du volume : NT 3.1 à Windows 2000.
        case volumeMiddle
        /// Ramené près du début : XP et au-delà.
        case nearStart
    }

    public let ntfs: NTFSProfile
    public var profile: any FileSystemProfile { ntfs }
    public private(set) var bitmap: ClusterBitmap

    /// `$MFT` vu comme ce qu'il est : un fichier, qui grandit et qui peut se
    /// fragmenter.
    public private(set) var mft: FileEntry
    public private(set) var mftMirror: Extent
    /// `$LogFile` : le journal, de taille fixe et immobile.
    public private(set) var logFile: Extent
    /// `$Bitmap` : la table d'occupation, un bit par cluster, posée derrière
    /// la zone MFT.
    public private(set) var volumeBitmap: Extent
    /// `$Boot` : les huit premiers kilo-octets du volume.
    public private(set) var bootExtent: Extent
    /// Enregistrements en service — ceux des fichiers vivants.
    public private(set) var mftRecordCount: UInt64
    /// Plus grand nombre d'enregistrements simultanés jamais atteint. La MFT ne
    /// rétrécit pas : une fois qu'elle a dû grandir, elle reste grande, même si
    /// les fichiers qui l'ont fait gonfler ont disparu depuis longtemps.
    public private(set) var mftPeakRecords: UInt64

    /// Plage réservée à la croissance de la MFT, juste derrière celle-ci — la
    /// zone **courante**, celle que renverrait `FSCTL_GET_NTFS_VOLUME_DATA`.
    /// Elle ne fait que rétrécir.
    public private(set) var mftZone: Range<UInt32>
    /// Combien de fois la zone a cédé la moitié de sa queue libre.
    public private(set) var mftZoneHalvings = 0
    /// La zone a-t-elle déjà cédé de la place aux données ?
    public var mftZoneBreached: Bool { mftZoneHalvings > 0 }

    /// Plus haut cluster jamais alloué, plus un : la frontière de l'espace
    /// vierge.
    public private(set) var highWater: UInt32

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

    /// Bloc par lequel `$MFT` s'agrandit hors de sa zone. NTFS n'étend jamais
    /// la table d'un enregistrement à la fois : il en demande un paquet — au
    /// moins huit — et cherche de quoi le poser d'un seul tenant. Huit clusters
    /// couvrent ce minimum quelle que soit la taille de cluster du volume.
    /// **Un ordre de grandeur**, sans source citée.
    private let mftGrowthClusters: UInt32 = 8

    /// Point de départ du prochain parcours. Il avance avec les allocations, ce
    /// qui évite que toutes les écritures se disputent les mêmes trous en tête
    /// de volume.
    private var searchCursor: UInt32 = 0

    /// Premier cluster derrière le dernier extent du fichier qu'on agrandit,
    /// le temps d'une extension. C'est là, et non au curseur, que la recherche
    /// commence : un système de fichiers qui étend un fichier cherche près de
    /// lui (voir l'en-tête).
    private var extensionHint: UInt32?

    /// Où en est l'écriture des fichiers système. Une installation de Windows
    /// pose quarante-cinq mille fichiers à la suite : elle ne redémarre pas du
    /// début du volume à chaque fichier. Le regroupement des fichiers de
    /// démarrage en tête de volume n'est pas le fait de l'allocateur, c'est
    /// celui du défragmenteur, qui repasse plus tard avec `Layout.ini` en main.
    private var systemCursor: UInt32 = 0

    public init(profile: NTFSProfile = NTFSProfile(),
                clusterCount: UInt32,
                initialMFTRecords: UInt64 = 32,
                mirrorPlacement: MirrorPlacement = .nearStart,
                search: SearchBounds = .standard) {
        precondition(profile.supports(clusterCount: clusterCount))
        self.ntfs = profile
        self.search = search
        self.bitmap = ClusterBitmap(clusterCount: clusterCount)
        self.mftRecordCount = initialMFTRecords
        self.mftPeakRecords = initialMFTRecords

        let layout = Self.layout(profile: profile, clusterCount: clusterCount,
                                 mirrorPlacement: mirrorPlacement,
                                 initialMFTRecords: initialMFTRecords)
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
        self.highWater = max(zoneStart, self.mftMirror.end, self.logFile.end, layout.bitmap.end)
    }

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
        /// Premier cluster de `$MFT`.
        public let mftStart: UInt32
        /// Taille initiale de `$MFT`, en clusters.
        public let mftClusters: UInt32
        /// Fin de la zone MFT d'origine, la place qu'elle réserve comprise.
        public let mftZoneEnd: UInt32
        /// `$Bitmap` : un bit par cluster, arrondi à huit octets comme le pose
        /// `mkntfs`, et **derrière la zone MFT** — la première place libre qui
        /// ne soit pas réservée à la MFT. C'est là que `mkntfs` pose ses
        /// métafichiers non résidents (`allocate_scattered_clusters`, qui part
        /// de `g_mft_zone_end`), et là que le simulateur lit et écrit la
        /// table.
        public let bitmap: Extent
    }

    public static func layout(profile: NTFSProfile, clusterCount: UInt32,
                              mirrorPlacement: MirrorPlacement,
                              initialMFTRecords: UInt64 = 32) -> Layout {
        // $Boot occupe les huit premiers kilo-octets du volume — deux clusters
        // à 4 Ko, et non un. La copie du secteur d'amorçage, elle, est au tout
        // dernier secteur du volume : elle ne coûte aucun cluster ici,
        // seulement un accès isolé au fond du disque au montage
        // (`PartitionGeometry.mountAccesses`).
        let bootClusters = max(profile.clusters(forBytes: 8 * 1_024), 1)

        // $MFTMirr : la copie des **quatre premiers enregistrements** de la
        // MFT, soit 4 Ko, soit un cluster à 4 Ko — et non quatre. Au milieu du
        // volume jusqu'à Windows 2000, ramené près du début ensuite : au
        // milieu, il impose un aller-retour à chaque écriture de métadonnées,
        // c'est audible, et c'est pour cela qu'il a été déplacé.
        //
        // « Près du début », c'est derrière `$Boot`, à l'endroit où vivent les
        // premiers métafichiers — de l'ordre du cluster 16 —, et non à la
        // frontière de la zone MFT : posé là, il tombait à 31 Go du début d'un
        // volume de 250 Go, sur le premier cluster où les données ont le droit
        // d'aller, qu'il coupait en deux.
        let mirrorClusters = max(profile.clusters(forBytes: 4 * 1_024), 1)
        let mirrorStart: UInt32 = switch mirrorPlacement {
        case .volumeMiddle: clusterCount / 2
        case .nearStart:    min(16, clusterCount - mirrorClusters)
        }
        let mirror = Extent(start: max(mirrorStart, bootClusters), length: mirrorClusters)

        // $LogFile suit le miroir, comme le pose `mkntfs`, qui reproduit la
        // disposition de Windows : au milieu du volume avec lui jusqu'à
        // Windows 2000, en tête ensuite. Sa taille est fixée au formatage et ne
        // change plus — 64 Mio à partir de 12 Gio de volume, ce que tous les
        // NTFS de la galerie dépassent. En dessous, `mkntfs` le réduit, et le
        // modèle prend sa valeur (4 Mio, 2 Mio sous 200 Mio) ; le plafond au
        // seizième du volume ne sert qu'aux volumes d'essai de quelques
        // centaines de clusters.
        let volumeBytes = UInt64(clusterCount) * UInt64(profile.clusterBytes)
        let logBytes: UInt64 = volumeBytes >= 12 << 30 ? 64 << 20
            : volumeBytes >= 200 << 20 ? 4 << 20
            : 2 << 20
        let logClusters = max(min(profile.clusters(forBytes: logBytes), clusterCount / 16), 1)
        let logFile = Extent(start: mirror.end, length: logClusters)

        // La MFT suit ce qui la précède : `$Boot` seul quand le miroir et le
        // journal sont au milieu du volume, `$Boot`, le miroir et le journal
        // quand ils sont près du début.
        let mftStart = mirrorPlacement == .nearStart
            ? max(logFile.end, bootClusters)
            : bootClusters
        let mftClusters = max(profile.clusters(forBytes: initialMFTRecords * 1_024), 1)
        let zoneEnd = min(clusterCount,
                          mftStart + max(UInt32(Double(clusterCount) * profile.mftZoneShare),
                                         mftClusters))
        let bitmapBytes = ((UInt64(clusterCount) + 7) / 8 + 7) / 8 * 8
        let bitmapClusters = max(profile.clusters(forBytes: bitmapBytes), 1)
        let bitmapStart = min(zoneEnd, clusterCount - min(bitmapClusters, clusterCount))
        return Layout(boot: Extent(start: 0, length: bootClusters),
                      mirror: mirror, logFile: logFile, mftStart: mftStart,
                      mftClusters: mftClusters, mftZoneEnd: zoneEnd,
                      bitmap: Extent(start: bitmapStart, length: bitmapClusters))
    }

    // MARK: - Zones

    /// `$Boot`, la MFT, `$MFTMirr`, `$LogFile` et `$Bitmap` : tout ce que le
    /// volume occupe sans qu'aucun fichier du catalogue ne le décrive.
    public var systemExtents: [Extent] {
        [bootExtent] + mft.extents + [mftMirror, logFile, volumeBitmap]
    }

    public var metadataExtents: [Extent] { systemExtents }

    /// La zone MFT a-t-elle encore toute sa taille d'origine ?
    public var mftZoneIsProtected: Bool { !mftZoneBreached }

    /// Plage dans laquelle les données ordinaires ont le droit d'aller : tout
    /// ce qui suit la zone courante. Devant elle, il n'y a que `$Boot` et la
    /// MFT.
    private var dataRange: Range<UInt32> {
        mftZone.isEmpty
            ? 0..<bitmap.clusterCount
            : mftZone.upperBound..<bitmap.clusterCount
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
    private mutating func yieldMFTZone() -> Bool {
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
        // Tant que la place manque hors de la zone, la zone cède de moitié. Un
        // échec de placement hors zone n'arrive que si le reste du volume n'a
        // plus assez de clusters libres : `scatter` prend n'importe quels
        // morceaux.
        while true {
            let extents = place(count, hint: hint, in: dataRange)
            if !extents.isEmpty { return extents }
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
        // le fichier se pose à son début.
        let virgin = max(highWater, range.lowerBound)..<range.upperBound
        if virgin.lowerBound < virgin.upperBound,
           let run = bitmap.firstFitRun(minLength: count, maxLength: count,
                                        from: virgin.lowerBound),
           run.start < virgin.upperBound {
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
    public mutating func free(_ extents: [Extent]) {
        bitmap.free(extents)
    }

    /// L'enregistrement du fichier disparu retourne au pot commun.
    public mutating func noteFileDeleted() {
        if mftRecordCount > 0 { mftRecordCount -= 1 }
    }

    /// Prise d'une plage imposée, pour un défragmenteur.
    @discardableResult
    public mutating func claim(_ extent: Extent) -> Bool {
        guard bitmap.isFree(extent) else { return false }
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
                bitmap.allocate(run)
                highWater = max(highWater, run.end)
                mft.extents.appendRun(start: run.start, length: run.length)
                remaining -= room
            }
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
            bitmap.allocate(extent)
            highWater = max(highWater, extent.end)
            mft.extents.appendRun(start: extent.start, length: extent.length)
            remaining -= min(take, remaining)
        }
        mft.extents = mft.extents.coalesced()
    }
}
