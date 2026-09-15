import Foundation

/// Allocateur NTFS.
///
/// Trois mécanismes le séparent de FAT, et ce sont eux qui donnent aux volumes
/// de 2003 et 2007 leur allure bien plus propre :
///
/// - **best-fit** plutôt que premier trou venu : un fichier va dans le trou qui
///   lui convient, pas dans le premier rencontré ;
/// - **zone MFT**, 12,5 % du volume tenus à l'écart des données ordinaires. Tant
///   qu'il reste de la place ailleurs, l'allocateur n'y touche pas ; au-delà de
///   87 % de remplissage il commence à la grignoter, et la MFT, qui n'a plus où
///   grandir, se fragmente à son tour. C'est ce basculement qui fait qu'un NTFS
///   plein se dégrade d'un coup et non progressivement ;
/// - **prolongement en place** : agrandir un fichier, c'est d'abord essayer les
///   clusters qui suivent immédiatement son dernier extent. Un `.doc`
///   réenregistré reste contigu là où FAT en aurait fait trois morceaux.
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
    /// Enregistrements en service — ceux des fichiers vivants.
    public private(set) var mftRecordCount: UInt64
    /// Plus grand nombre d'enregistrements simultanés jamais atteint. La MFT ne
    /// rétrécit pas : une fois qu'elle a dû grandir, elle reste grande, même si
    /// les fichiers qui l'ont fait gonfler ont disparu depuis longtemps.
    public private(set) var mftPeakRecords: UInt64

    /// Plage réservée à la croissance de la MFT, juste derrière celle-ci.
    public private(set) var mftZone: Range<UInt32>
    /// La zone MFT a-t-elle déjà été entamée par des données ?
    public private(set) var mftZoneBreached = false

    /// Plus haut cluster jamais alloué, plus un : la frontière de l'espace
    /// vierge.
    public private(set) var highWater: UInt32

    /// Un trou n'est repris que si sa taille ne dépasse pas ce multiple du
    /// besoin. Au-delà, l'allocateur préfère l'espace vierge plutôt que de
    /// couper un grand bloc en deux.
    private let reuseTolerance: UInt32 = 2

    /// Marge cherchée derrière un fichier neuf, pour que ses extensions futures
    /// tombent à sa suite. Elle n'est **pas** allouée : elle ne sert qu'à
    /// choisir le trou.
    private let growthMarginClusters: UInt32 = 16

    /// Trous examinés avant de se décider. NTFS ne connaît pas l'état complet de
    /// son volume à chaque écriture : il tient un cache partiel de sa table
    /// d'occupation et prend le meilleur trou qu'il y voit. C'est ce que fait
    /// cette fenêtre — et sans elle, chaque allocation parcourrait les dizaines
    /// de milliers de trous d'un volume de 80 Go.
    private let searchWindow = 64

    /// Distance maximale parcourue dans la bitmap à la recherche d'un trou :
    /// 65 536 clusters, soit 8 Ko de table d'occupation — l'ordre de grandeur
    /// de ce qu'un pilote garde réellement en cache. Au-delà, l'allocateur
    /// renonce et va prendre de l'espace vierge.
    ///
    /// C'est la borne qui décide du coût de la génération : sans elle, chaque
    /// écriture traverse les zones pleines qui séparent les trous, et un volume
    /// de 80 Go devient quadratique.
    private let searchHorizon: UInt32 = 1 << 16

    /// Point de départ du prochain parcours. Il avance avec les allocations, ce
    /// qui évite que toutes les écritures se disputent les mêmes trous en tête
    /// de volume.
    private var searchCursor: UInt32 = 0

    /// Où en est l'écriture des fichiers système. Une installation de Windows
    /// pose quarante-cinq mille fichiers à la suite : elle ne redémarre pas du
    /// début du volume à chaque fichier. Le regroupement des fichiers de
    /// démarrage en tête de volume n'est pas le fait de l'allocateur, c'est
    /// celui du défragmenteur, qui repasse plus tard avec `Layout.ini` en main.
    private var systemCursor: UInt32 = 0

    public init(profile: NTFSProfile = NTFSProfile(),
                clusterCount: UInt32,
                initialMFTRecords: UInt64 = 32,
                mirrorPlacement: MirrorPlacement = .nearStart) {
        precondition(profile.supports(clusterCount: clusterCount))
        self.ntfs = profile
        self.bitmap = ClusterBitmap(clusterCount: clusterCount)
        self.mftRecordCount = initialMFTRecords
        self.mftPeakRecords = initialMFTRecords

        // $Boot occupe le tout début du volume, la MFT le suit immédiatement.
        let bootClusters: UInt32 = 1
        bitmap.allocate(start: 0, length: bootClusters)

        let mftClusters = max(profile.clusters(forBytes: initialMFTRecords * 1_024), 1)
        bitmap.allocate(start: bootClusters, length: mftClusters)
        self.mft = FileEntry(id: 0,
                             logicalSize: initialMFTRecords * 1_024,
                             extents: [Extent(start: bootClusters, length: mftClusters)],
                             hint: .system)

        let zoneEnd = min(clusterCount,
                          bootClusters + max(UInt32(Double(clusterCount) * profile.mftZoneShare),
                                             mftClusters))
        self.mftZone = (bootClusters + mftClusters)..<max(zoneEnd, bootClusters + mftClusters)
        self.highWater = bootClusters + mftClusters

        // $MFTMirr : quatre clusters, au milieu du volume ou près du début selon
        // l'époque. Au milieu, il impose un aller-retour à chaque écriture de
        // métadonnées — c'est audible, et c'est pour cela qu'il a été déplacé.
        let mirrorStart: UInt32 = switch mirrorPlacement {
        case .volumeMiddle: clusterCount / 2
        case .nearStart:    min(self.mftZone.upperBound, clusterCount - 4)
        }
        self.mftMirror = Extent(start: mirrorStart, length: 4)
        bitmap.allocate(self.mftMirror)
        self.highWater = max(self.highWater, self.mftMirror.end)
    }

    // MARK: - Zones

    /// La zone MFT est-elle encore protégée ? Elle cède quand le volume passe
    /// le seuil, et ne se referme jamais ensuite : une fois des données
    /// installées dedans, la MFT a définitivement perdu sa réserve.
    public var mftZoneIsProtected: Bool {
        !mftZoneBreached && bitmap.fill < ntfs.mftZoneYieldsAt
    }

    /// Plage dans laquelle les données ordinaires ont le droit d'aller.
    private var dataRange: Range<UInt32> {
        mftZoneIsProtected
            ? mftZone.upperBound..<bitmap.clusterCount
            : 0..<bitmap.clusterCount
    }

    // MARK: - Allocation

    public mutating func allocate(clusterCount count: UInt32, hint: AllocationHint) -> [Extent] {
        guard count > 0, count <= bitmap.freeCount else { return [] }
        let range = dataRange

        switch hint {
        case .reservedContiguous:
            // `pagefile.sys` à taille fixe, `hiberfil.sys` : d'un seul tenant
            // tant que le volume a un bloc capable de les accueillir.
            if let run = contiguousRun(for: count, in: range) {
                return commit([run])
            }

        case .boot:
            // Le chargeur d'amorçage veut ses fichiers au plus près du début du
            // volume, et ils sont assez peu nombreux pour qu'un scan complet
            // n'ait aucune importance.
            if let run = bitmap.firstFitRun(minLength: count, maxLength: count,
                                            from: range.lowerBound),
               run.end <= range.upperBound {
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
            systemCursor = min(systemCursor &+ searchHorizon, range.upperBound)
            // La tête du volume est pleine : le fichier système suivant est
            // traité comme les autres.
            systemCursor = range.lowerBound

        case .normal, .temporary:
            break
        }

        if let run = preferredRun(for: count, in: range) {
            return commit([run])
        }
        return commit(scatter(count, in: range))
    }

    /// Choix du trou : best-fit d'abord, mais sans casser un grand bloc pour un
    /// petit fichier tant qu'il reste du vierge derrière le `highWater`.
    private func preferredRun(for count: UInt32, in range: Range<UInt32>) -> Extent? {
        let wanted = count &+ growthMarginClusters

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
                                       from: searchCursor,
                                       maxRunsExamined: searchWindow,
                                       maxClustersScanned: searchHorizon,
                                       measureLimit: tolerable),
           fit.length <= tolerable {
            return Extent(start: fit.start, length: count)
        }

        // Espace vierge : on y cherche de quoi loger le fichier **et** sa marge
        // de croissance, pour que ses extensions futures tombent à sa suite.
        let virgin = max(highWater, range.lowerBound)..<range.upperBound
        if virgin.lowerBound < virgin.upperBound {
            if let run = bitmap.firstFitRun(minLength: wanted, maxLength: wanted,
                                            from: virgin.lowerBound)
                ?? bitmap.firstFitRun(minLength: count, maxLength: count,
                                      from: virgin.lowerBound),
               run.start < virgin.upperBound {
                return Extent(start: run.start, length: count)
            }
        }

        // Plus de vierge : on reprend le volume par fenêtres successives, en
        // repartant de là où le curseur en est. Rescanner tout le volume à
        // chaque écriture coûterait, sur un disque de 2007, plus d'une minute
        // pour une seule génération — et surtout, aucun pilote ne fait cela.
        var probe = range.lowerBound
        var windows = 0
        while probe < range.upperBound, windows < 16 {
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
        guard !extents.isEmpty else { return [] }
        for extent in extents {
            bitmap.allocate(extent)
            highWater = max(highWater, extent.end)
            // Le curseur suit l'écriture : la place suivante est cherchée à
            // partir d'ici, pas depuis le début du volume.
            searchCursor = extent.end < bitmap.clusterCount ? extent.end : 0
            if extent.start < mftZone.upperBound && extent.end > mftZone.lowerBound {
                mftZoneBreached = true
            }
        }
        return extents
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
                _ = commit([run])
                prolonged = run
                remaining -= contiguous
            }
        }

        if remaining > 0 {
            let added = allocate(clusterCount: remaining, hint: file.hint)
            guard !added.isEmpty else {
                // Le complément n'a pas pu être placé : on rend ce qui venait
                // d'être pris, pour que le fichier ressorte intact.
                if let prolonged { bitmap.free(prolonged) }
                return false
            }
            if let prolonged { file.extents.appendRun(start: prolonged.start, length: prolonged.length) }
            file.extents.append(contentsOf: added)
            file.extents = file.extents.coalesced()
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
        if extent.start < mftZone.upperBound && extent.end > mftZone.lowerBound {
            mftZoneBreached = true
        }
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
        // NTFS qu'on a laissé se remplir.
        while remaining > 0 {
            guard let run = bitmap.bestFitRun(minLength: 1, in: 0..<bitmap.clusterCount) else { break }
            let take = min(run.length, remaining)
            let extent = Extent(start: run.start, length: take)
            bitmap.allocate(extent)
            highWater = max(highWater, extent.end)
            mft.extents.appendRun(start: extent.start, length: extent.length)
            remaining -= take
        }
        mft.extents = mft.extents.coalesced()
    }
}
