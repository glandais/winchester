import Foundation

/// Un disque dur réellement vendu, tel que sa fiche le décrit.
///
/// Ces fiches ne sont pas des exemples : ce sont les **points d'ancrage** du
/// modèle de géométrie. `DriveGeometry.era` n'invente pas une densité, elle
/// interpole entre ces disques-là, et un test vérifie qu'elle les retrouve.
///
/// Deux familles de sources, qui ne publient pas les mêmes nombres :
///
/// - les fiches des années 90 (TULARC) donnent la géométrie **native** —
///   cylindres et têtes — d'où se déduit le nombre de secteurs par piste ;
/// - les manuels constructeur (Seagate) donnent les **densités** — pistes par
///   pouce, bits par pouce — et le nombre de plateaux, d'où se déduit la
///   capacité d'une face.
///
/// Les deux se rejoignent sur un couple `(pistes par face, octets par face)`,
/// et c'est ce couple, et lui seul, que le modèle interpole.
///
/// Une fiche n'entre ici qu'après vérification croisée par le débit : les
/// secteurs de la piste externe multipliés par le régime doivent retomber sur
/// le taux de transfert annoncé. C'est ce contrôle qui a fait écarter la
/// géométrie « native » du Quantum Fireball ST 6.4AT, qui donnerait 6,5 Mo/s
/// là où sa fiche en annonce 16 — les 13 328 cylindres publiés sont ceux d'une
/// translation, pas des pistes.
public struct DriveReference: Sendable {

    public let model: String
    /// Nom court, pour la ligne d'écran où le disque est nommé.
    public let shortName: String
    /// Année de mise sur le marché.
    public let year: Int
    /// Capacité formatée annoncée, en octets décimaux — c'est la convention
    /// des fabricants, et les « secteurs garantis » des manuels la confirment.
    public let capacityBytes: UInt64
    /// Têtes de lecture-écriture, c'est-à-dire faces utilisées.
    public let heads: Int
    /// Pistes par face. Publiée directement dans les années 90, déduite de la
    /// densité de pistes ensuite.
    public let tracksPerFace: Int
    public let rpm: Int
    public let averageSeekMs: Double
    public let trackToTrackMs: Double
    /// Débit soutenu sur la piste externe, quand la fiche l'annonce. Sert de
    /// vérification croisée : il n'entre dans aucun calcul.
    public let sustainedOuterMBs: Double?
    /// Point d'ancrage de l'interpolation, ou simple variante de gamme.
    ///
    /// Une gamme décline la même mécanique en plusieurs capacités — un, deux ou
    /// quatre plateaux de densité identique. Une seule de ces variantes ancre
    /// la courbe des densités ; les autres sont là pour être citées, et pour
    /// servir de contrôle supplémentaire aux tests.
    public let isAnchor: Bool
    public let source: String
    /// Le tampon du disque et ce qu'il en fait : une donnée de fiche, comme le
    /// régime. C'est elle qui date un disque autant que lui.
    public let buffer: DriveBuffer

    public init(model: String, shortName: String, year: Int, capacityBytes: UInt64, heads: Int,
                tracksPerFace: Int, rpm: Int, averageSeekMs: Double,
                trackToTrackMs: Double, sustainedOuterMBs: Double? = nil,
                isAnchor: Bool = true,
                source: String,
                buffer: DriveBuffer) {
        self.model = model
        self.shortName = shortName
        self.year = year
        self.capacityBytes = capacityBytes
        self.heads = heads
        self.tracksPerFace = tracksPerFace
        self.rpm = rpm
        self.averageSeekMs = averageSeekMs
        self.trackToTrackMs = trackToTrackMs
        self.sustainedOuterMBs = sustainedOuterMBs
        self.isAnchor = isAnchor
        self.source = source
        self.buffer = buffer
    }

    /// Octets sur une face du plateau.
    public var bytesPerFace: Double { Double(capacityBytes) / Double(heads) }

    /// Secteurs par piste, en moyenne sur la face.
    public var meanSectorsPerTrack: Double {
        bytesPerFace / Double(DriveGeometry.bytesPerSector) / Double(tracksPerFace)
    }
}

/// Le tampon d'un disque, et la politique que son constructeur y appliquait à
/// la mise sous tension.
///
/// Tout y est de fiche ou de manuel, et les valeurs diffèrent d'un disque à
/// l'autre : 64 Ko de lecture anticipée seule sur le Conner de 1993, 128 Ko dont
/// 76 Ko de cache sur le Fireball, 2 Mo sur les Barracuda de 2001 et 2003, 16 Mo
/// sur le 7200.10. C'est la taille du tampon qui date un disque autant que son
/// régime.
///
/// **La segmentation** n'a pas de champ à elle : un seul manuel du catalogue la
/// décrit, celui du Fireball TM — « adaptive segmentation […] the cache can be
/// flexibly divided into several segments […] each segment contains one cache
/// entry », une entrée étant la lecture demandée plus sa lecture anticipée —, et
/// celui du Conner Cougar de 1992 annonce un tampon « segmentable » géré au
/// plus anciennement utilisé. Les manuels Seagate n'en disent rien. Le modèle
/// applique donc la règle du Fireball à tous : autant d'entrées que la taille en
/// loge, la moins récemment servie cède la place. Le nombre de flux servis
/// n'est pas posé ; il tombe de la taille du tampon devant celle d'une piste —
/// une seule sur le Fireball, dont la piste externe fait 69 Ko, une trentaine
/// sur le 7200.10.
public struct DriveBuffer: Sendable, Equatable {

    /// Taille du tampon, en kilo-octets.
    public let bufferKB: Int
    /// Ce qui en sert de cache. Le reste tient le microcode et les tables du
    /// contrôleur : 76 Ko sur 128 pour le Fireball ; les autres manuels ne
    /// distinguent pas, et donnent le tampon entier pour cache.
    public let cacheKB: Int
    /// La lecture anticipée est-elle active à la mise sous tension ?
    public let readAhead: Bool
    /// Le cache d'écriture l'est-il ?
    public let writeCache: Bool
    /// Lecture sans latence : une requête qui tient sur la piste commence au
    /// secteur qui se présente, et le tampon remet les morceaux dans l'ordre.
    public let zeroLatencyRead: Bool
    /// Débit le plus élevé de l'interface côté disque, en Mo/s : le mode le
    /// plus rapide que le disque accepte. La machine peut en imposer un plus
    /// lent.
    public let interfaceMBs: Double
    /// Ce que coûte une commande hors mécanique — décodage, interruption,
    /// mise en place du transfert —, en millisecondes.
    public let commandOverheadMs: Double
    /// D'où viennent ces valeurs.
    public let source: String

    public init(bufferKB: Int, cacheKB: Int? = nil, readAhead: Bool, writeCache: Bool,
                zeroLatencyRead: Bool, interfaceMBs: Double, commandOverheadMs: Double,
                source: String) {
        self.bufferKB = bufferKB
        self.cacheKB = cacheKB ?? bufferKB
        self.readAhead = readAhead
        self.writeCache = writeCache
        self.zeroLatencyRead = zeroLatencyRead
        self.interfaceMBs = interfaceMBs
        self.commandOverheadMs = commandOverheadMs
        self.source = source
    }

    /// Le coût de commande de toutes les fiches depuis 1996 : **la seule mesure
    /// de la période** qui l'isole. Microsoft Research, *IDE Ultra/33
    /// Performance: Intel PIIX4E* (1999), sur un Pentium II : « The DMA setup /
    /// cleanup activity takes approximately 200 µs » par requête en lecture,
    /// moins de 50 µs en écriture. Le modèle prend 200 µs dans les deux sens ;
    /// aucune source ne donne ce coût sur les machines de 2003 et 2007, plus
    /// rapides, où il est sans doute surestimé.
    public static let measuredOverheadMs = 0.2
}

/// Les disques sur lesquels le modèle est calibré, de 1993 à 2008.
///
/// Quinze ans qui couvrent toute la période des scénarios embarqués, avec un
/// point tous les deux ou trois ans — c'est la résolution qu'il faut, la
/// densité doublant environ chaque année sur la fin des années 90.
public enum DriveCatalog {

    /// Largeur de la bande de données d'un plateau 3,5 pouces, en pouces.
    ///
    /// Les données n'occupent pas tout le plateau : il reste un moyeu au
    /// centre et une garde au bord. Cette largeur est le seul paramètre du
    /// modèle qui ne vienne pas d'une fiche — elle vaut environ 28 mm sur
    /// toute la période, et c'est elle qui convertit une densité de pistes en
    /// nombre de cylindres. Réglée à 1,10 pouce, elle fait retomber le débit
    /// externe du Barracuda 7200.7 et du 7200.10 sur celui de leurs manuels à
    /// 5 % près, alors que le débit n'entre pas dans le calage.
    public static let dataBandInches = 1.10

    /// Rayon externe de la zone de données d'un plateau 3,5 pouces, en pouces.
    public static let outerRadiusInches = 1.831

    public static let all: [DriveReference] = [

        DriveReference(
            model: "Conner CFA170A",
            shortName: "Conner CFA170A",
            year: 1993, capacityBytes: 170_000_000, heads: 4,
            tracksPerFace: 1_806, rpm: 4_011,
            averageSeekMs: 13.0, trackToTrackMs: 3.0,
            source: "TULARC — 1 806 cylindres natifs, 4 têtes, RLL 1/7",
            buffer: DriveBuffer(
                bufferKB: 64, readAhead: true, writeCache: false, zeroLatencyRead: false,
                interfaceMBs: 7.0, commandOverheadMs: 0.5,
                source: "TULARC — « 64 KB READ-AHEAD », 7,0 Mo/s externe ; aucun cache "
                      + "d'écriture annoncé. Coût de commande : manuel Conner Cougar CP30204 "
                      + "(1992, même constructeur), « Controller Overhead < 500 µs »")),

        DriveReference(
            model: "Quantum Fireball 1080AT",
            shortName: "Fireball 1080AT",
            year: 1996, capacityBytes: 1_082_130_432, heads: 4,
            tracksPerFace: 3_835, rpm: 5_400,
            averageSeekMs: 12.0, trackToTrackMs: 3.0,
            source: "TULARC — 3 835 cylindres natifs, 4 têtes, PRML 16/17",
            buffer: DriveBuffer(
                bufferKB: 128, cacheKB: 76, readAhead: true, writeCache: true,
                zeroLatencyRead: true,
                interfaceMBs: 16.67, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "TULARC — « 128 KB READ/WRITE », PIO mode 4. Le détail vient du "
                      + "manuel du Fireball TM 1080AT (81-111394-02, 1996), celui du "
                      + "540/1080AT de 1995 étant introuvable : 76 Ko de cache à "
                      + "segmentation adaptative, « read look-ahead, and write cache "
                      + "enabled » à la mise sous tension, « Read-on-arrival firmware »")),

        DriveReference(
            model: "Seagate U8 ST38410A",
            shortName: "Seagate U8",
            year: 1999, capacityBytes: 8_420_000_000, heads: 2,
            tracksPerFace: 20_570, rpm: 5_400,
            averageSeekMs: 8.9, trackToTrackMs: 1.5,
            source: "Manuel Seagate U8 — 18,7 kTPI, 349 kBPI, 1 plateau",
            buffer: DriveBuffer(
                bufferKB: 512, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 66.6, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate U8 (SG35226-001, rév. A, 1999) — « Cache buffer "
                      + "512 Kbytes », Ultra DMA mode 4, « Power-on default has the read "
                      + "look-ahead and write caching features enabled »")),

        DriveReference(
            model: "Seagate Barracuda ATA IV ST340016A",
            shortName: "Barracuda ATA IV",
            year: 2001, capacityBytes: 40_020_664_320, heads: 2,
            tracksPerFace: 63_800, rpm: 7_200,
            averageSeekMs: 9.0, trackToTrackMs: 0.95,
            source: "Manuel Seagate Barracuda ATA IV — 58 kTPI, 540 kBPI, 1 plateau, "
                  + "seek moyen de la variante à un plateau",
            buffer: DriveBuffer(
                bufferKB: 2_048, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 100, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda ATA IV (100129212, rév. B) — « Cache "
                      + "buffer 2 Mbytes », Ultra DMA mode 5, lecture anticipée et cache "
                      + "d'écriture actifs à la mise sous tension")),

        // Même mécanique et même densité que le précédent, sur une seule face :
        // c'est le disque de 20 Go de 2001, celui du scénario de démarrage.
        DriveReference(
            model: "Seagate Barracuda ATA IV ST320011A",
            shortName: "Barracuda ATA IV",
            year: 2001, capacityBytes: 20_010_332_160, heads: 1,
            tracksPerFace: 63_800, rpm: 7_200,
            averageSeekMs: 9.0, trackToTrackMs: 0.95,
            isAnchor: false,
            source: "Manuel Seagate Barracuda ATA IV — 39 102 336 secteurs garantis, "
                  + "1 tête, 1 plateau",
            buffer: DriveBuffer(
                bufferKB: 2_048, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 100, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda ATA IV (100129212, rév. B) — « Cache "
                      + "buffer 2 Mbytes », Ultra DMA mode 5, lecture anticipée et cache "
                      + "d'écriture actifs à la mise sous tension")),

        DriveReference(
            model: "Seagate Barracuda 7200.7 ST340014A",
            shortName: "Barracuda 7200.7",
            year: 2003, capacityBytes: 40_020_664_320, heads: 1,
            tracksPerFace: 104_060, rpm: 7_200,
            averageSeekMs: 8.5, trackToTrackMs: 1.0,
            sustainedOuterMBs: 58,
            source: "Manuel Seagate Barracuda 7200.7 — 94,6 kTPI, 595 kBPI, 1 plateau",
            buffer: DriveBuffer(
                bufferKB: 2_048, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 100, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda 7200.7 (100217279, rév. N) — 2 Mo pour "
                      + "le ST340014A (8 Mo pour les variantes en …3A), Ultra DMA mode 5, "
                      + "lecture anticipée et cache d'écriture actifs à la mise sous tension")),

        DriveReference(
            model: "Seagate Barracuda 7200.10 ST3320620A",
            shortName: "Barracuda 7200.10",
            year: 2006, capacityBytes: 320_072_933_376, heads: 4,
            tracksPerFace: 159_500, rpm: 7_200,
            averageSeekMs: 8.5, trackToTrackMs: 1.0,
            sustainedOuterMBs: 78,
            source: "Manuel Seagate Barracuda 7200.10 — 145 kTPI, 813 kBPI, "
                  + "enregistrement perpendiculaire, 2 plateaux",
            buffer: DriveBuffer(
                bufferKB: 16_384, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 100, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda 7200.10 PATA (100402369, rév. F), table 2 "
                      + "— 16 Mo pour le ST3320620A (8 Mo pour le ST3320820A), Ultra DMA "
                      + "mode 5, lecture anticipée et cache d'écriture actifs par défaut")),

        DriveReference(
            model: "Seagate Barracuda 7200.11 ST31000340AS",
            shortName: "Barracuda 7200.11",
            year: 2008, capacityBytes: 1_000_204_886_016, heads: 8,
            tracksPerFace: 165_000, rpm: 7_200,
            averageSeekMs: 8.5, trackToTrackMs: 1.0,
            sustainedOuterMBs: 105,
            source: "Manuel Seagate Barracuda 7200.11 — 150 kTPI, 1 090 kBPI, 4 plateaux",
            buffer: DriveBuffer(
                bufferKB: 32_768, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 300, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda 7200.11 (100452348, rév. E), table 1 — "
                      + "32 Mo pour le ST31000340AS, Serial ATA à 300 Mo/s, lecture "
                      + "anticipée et cache d'écriture actifs par défaut")),
    ]

    /// Rapport entre les secteurs de la piste interne et ceux de la piste
    /// externe, par époque.
    ///
    /// Ce rapport ne suit pas la capacité mais l'élargissement de la bande de
    /// données vers le moyeu : un disque des années 90 n'écrit que sur une
    /// couronne étroite, un disque de 2003 descend bien plus bas. C'est lui qui
    /// fixe l'écart de débit entre le début et la fin d'un volume — donc la
    /// différence de texture entre une lecture en tête de disque et la même en
    /// fin de disque.
    static let innerRatioByYear: [(year: Int, ratio: Double)] = [
        (1993, 0.67), (1996, 0.67), (1999, 0.60), (2001, 0.55), (2003, 0.52), (2008, 0.52),
    ]

    /// Les fiches qui ancrent l'interpolation, une par année, dans l'ordre.
    static var anchors: [DriveReference] {
        all.filter(\.isAnchor).sorted { $0.year < $1.year }
    }

    /// Le disque du catalogue le plus proche d'une année donnée.
    public static func nearest(year: Int) -> DriveReference {
        all.min { abs($0.year - year) < abs($1.year - year) } ?? all[0]
    }
}

// MARK: - Interpolation dans le temps

extension DriveCatalog {

    /// Densité de pistes et capacité par face, à une année donnée.
    ///
    /// Les deux progressent de façon multiplicative — la densité double
    /// environ chaque année sur la fin des années 90, puis ralentit — donc
    /// l'interpolation est géométrique et non linéaire. Hors des bornes du
    /// catalogue, la dernière pente connue est prolongée.
    static func density(year: Int) -> (tracksPerFace: Double, bytesPerFace: Double, innerRatio: Double) {
        let points = anchors
        let (low, high) = bracket(year: year, in: points.map(\.year))

        let a = points[low]
        let b = points[high]
        let span = Double(b.year - a.year)
        let f = span > 0 ? Double(year - a.year) / span : 0

        return (geometric(Double(a.tracksPerFace), Double(b.tracksPerFace), f),
                geometric(a.bytesPerFace, b.bytesPerFace, f),
                innerRatio(year: year))
    }

    private static func innerRatio(year: Int) -> Double {
        let table = innerRatioByYear
        let (low, high) = bracket(year: year, in: table.map(\.year))
        let span = Double(table[high].year - table[low].year)
        let f = span > 0 ? Double(year - table[low].year) / span : 0
        let value = table[low].ratio + (table[high].ratio - table[low].ratio) * f
        return min(max(value, 0.45), 0.75)
    }

    /// Les deux points du catalogue qui encadrent une année. Au-delà des
    /// bornes, les deux derniers — l'interpolation devient extrapolation, et
    /// c'est voulu : un disque de 2011 doit rester plus dense qu'un de 2008.
    private static func bracket(year: Int, in years: [Int]) -> (Int, Int) {
        precondition(years.count >= 2)
        if year <= years[0] { return (0, 1) }
        if year >= years[years.count - 1] { return (years.count - 2, years.count - 1) }
        for index in 0..<(years.count - 1) where years[index] <= year && year <= years[index + 1] {
            return (index, index + 1)
        }
        return (years.count - 2, years.count - 1)
    }

    private static func geometric(_ a: Double, _ b: Double, _ f: Double) -> Double {
        exp(log(a) + f * (log(b) - log(a)))
    }
}

extension DriveCatalog {

    /// Durée d'un seek d'une piste, à une année donnée.
    ///
    /// Elle ne suit pas du tout la même pente que le seek moyen : entre 1993 et
    /// 2003 le seek moyen n'a été divisé que par 1,5, le piste-à-piste par 3.
    /// C'est le rapport des deux qui a changé — les bras se sont allégés et les
    /// asservissements affinés bien plus vite que les courses ne se sont
    /// raccourcies — et c'est exactement ce qui distingue le crépitement serré
    /// d'un disque récent du claquement espacé d'un disque ancien.
    public static func trackToTrackMs(year: Int) -> Double {
        let points = anchors
        let (low, high) = bracket(year: year, in: points.map(\.year))
        let span = Double(points[high].year - points[low].year)
        let f = span > 0 ? Double(year - points[low].year) / span : 0
        let value = points[low].trackToTrackMs
            + (points[high].trackToTrackMs - points[low].trackToTrackMs) * f
        return min(max(value, 0.5), 5.0)
    }

    /// Seek moyen d'un disque de cette année-là, quand la fiche du scénario
    /// n'en donne pas.
    public static func averageSeekMs(year: Int) -> Double {
        let points = anchors
        let (low, high) = bracket(year: year, in: points.map(\.year))
        let span = Double(points[high].year - points[low].year)
        let f = span > 0 ? Double(year - points[low].year) / span : 0
        return points[low].averageSeekMs + (points[high].averageSeekMs - points[low].averageSeekMs) * f
    }
}

// MARK: - D'une fiche au matériel simulé

extension DriveReference {

    /// Régime formaté à la française, espace fine insécable comprise —
    /// « 5 400 tr/min ». Même typographie partout, y compris pour les disques
    /// que la galerie fabrique.
    private var rpmLabel: String {
        rpm >= 1_000
            ? String(format: "%d\u{202F}%03d", rpm / 1_000, rpm % 1_000)
            : "\(rpm)"
    }

    /// Ce que l'écran affiche du disque : son nom et son régime.
    public var label: String { "\(shortName) · \(rpmLabel) tr/min" }

    /// La géométrie de ce disque-là.
    ///
    /// Le nombre de faces n'est pas déduit : il est celui de la fiche. Sur un
    /// disque nommé on le connaît, et c'est lui qui décide des commutations de
    /// tête — un 20 Go de 2001 n'a qu'une seule face, donc pas une seule
    /// commutation de toute la passe.
    public var geometry: DriveGeometry {
        DriveGeometry.era(model: label,
                          capacityBytes: capacityBytes,
                          rpm: rpm,
                          year: year,
                          heads: heads)
    }

    /// La loi de seek de ce disque-là, calée sur les deux durées de sa fiche.
    public var seekModel: SeekModel {
        SeekModel.calibrated(averageSeekMs: averageSeekMs,
                             trackToTrackMs: trackToTrackMs,
                             cylinders: geometry.cylinders)
    }
}

extension DriveCatalog {

    /// Deux fiches nommées, celles sur lesquelles le modèle a été calé et que
    /// les tests mesurent : le 20 Go à une face de 2001, et le 1,08 Go de 1996.
    ///
    /// Elles portaient les deux scénarios livrés, du temps où ceux-ci avaient
    /// leur propre disque ; les démos tournent désormais sur des disques de la
    /// galerie, dont la géométrie est déduite d'une fiche et d'une année. Ces
    /// deux-là restent nommées parce qu'un point de mesure a besoin d'un nom.
    public static let barracuda2001 = all.first { $0.model.hasSuffix("ST320011A") } ?? all[0]
    public static let fireball1996 = all.first { $0.model.hasPrefix("Quantum Fireball") } ?? all[0]
}
