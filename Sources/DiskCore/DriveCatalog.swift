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
///
/// Le débit qu'un manuel appelle « sustained » est celui d'une lecture
/// séquentielle, qui paie ses commutations de tête et ses pas de piste ; le
/// débit brut de la piste (`DriveGeometry.sustainedMBs`) ne les paie pas, et
/// le borne donc par le haut. C'est la lecture simulée qui se compare à la
/// fiche, à 10 % (`SequentialThroughputTests`).
///
/// Il n'y a pas de facteur de format à appliquer au débit : les secteurs par
/// piste ne sont pas déduits d'une densité de bits, où les rafales servo, les
/// en-têtes et l'ECC prendraient leur part, mais de la capacité et du nombre
/// de pistes — ce sont déjà des secteurs de données. Les manuels Seagate
/// publient d'ailleurs l'autre grandeur, le débit du canal (« internal data
/// transfer rate ») : 85,4 Mo/s sur le 7200.7 pour 58 soutenus, 1 287 Mbit/s
/// sur le 7200.11 pour 105 Mo/s. Leur rapport, 0,65 à 0,68, mêle format,
/// codage et commutations ; ce n'est pas le 0,90 qu'on aurait appliqué.
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
    /// Les seeks d'écriture que publie le manuel, quand il les publie.
    public let writeSeek: WriteSeek?
    /// Diamètre des plateaux, en pouces. 3,5 pour tous les disques de bureau de
    /// la période ; 2,5 pour les 10 000 tr/min, dont les plateaux sont réduits
    /// pour que la vitesse au bord reste celle d'un 7 200 tr/min.
    public let platterInches: Double
    /// Rapport entre les secteurs de la piste interne et ceux de la piste
    /// externe, quand une mesure le donne. Sinon, celui de l'époque.
    public let innerRatio: Double?
    /// Les têtes se garent sur une rampe hors du plateau au lieu de s'y poser :
    /// ni décollage à la mise en route, ni atterrissage à la coupure.
    public let rampLoad: Bool

    public init(model: String, shortName: String, year: Int, capacityBytes: UInt64, heads: Int,
                tracksPerFace: Int, rpm: Int, averageSeekMs: Double,
                trackToTrackMs: Double, sustainedOuterMBs: Double? = nil,
                isAnchor: Bool = true,
                platterInches: Double = 3.5,
                innerRatio: Double? = nil,
                rampLoad: Bool = false,
                source: String,
                buffer: DriveBuffer,
                writeSeek: WriteSeek? = nil) {
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
        self.writeSeek = writeSeek
        self.platterInches = platterInches
        self.innerRatio = innerRatio
        self.rampLoad = rampLoad
    }

    /// Une fiche de 3,5 pouces suit la courbe des densités de son époque ; une
    /// autre a sa propre mécanique, et sa géométrie vient de sa fiche seule.
    public var followsEra: Bool { platterInches == 3.5 }

    /// Octets sur une face du plateau.
    public var bytesPerFace: Double { Double(capacityBytes) / Double(heads) }

    /// Secteurs par piste, en moyenne sur la face.
    public var meanSectorsPerTrack: Double {
        bytesPerFace / Double(DriveGeometry.bytesPerSector) / Double(tracksPerFace)
    }
}

/// Les seeks d'écriture d'une fiche, avec ceux de lecture **de la même table**.
///
/// Les manuels publient deux colonnes, « Read » et « Write » : le seek moyen et
/// le piste-à-piste d'une écriture sont d'une à deux millisecondes plus longs,
/// parce que la tête doit être mieux posée avant d'écrire (`SeekModel.writeLaw`).
/// Le modèle en garde les **rapports** et non les valeurs : la colonne de
/// lecture d'une table n'est pas toujours le chiffre commercial retenu par la
/// fiche — le U8 annonce 8,9 ms en tête de manuel et 10,5 dans sa table de
/// seeks —, et c'est ainsi qu'un disque de la galerie, qui a son propre seek
/// moyen, reçoit le supplément de la fiche la plus proche.
public struct WriteSeek: Sendable, Equatable {
    public let readAverageMs: Double
    public let writeAverageMs: Double
    public let readTrackToTrackMs: Double
    public let writeTrackToTrackMs: Double
    public let source: String

    public init(readAverageMs: Double, writeAverageMs: Double,
                readTrackToTrackMs: Double, writeTrackToTrackMs: Double, source: String) {
        self.readAverageMs = readAverageMs
        self.writeAverageMs = writeAverageMs
        self.readTrackToTrackMs = readTrackToTrackMs
        self.writeTrackToTrackMs = writeTrackToTrackMs
        self.source = source
    }

    public var averageRatio: Double { writeAverageMs / readAverageMs }
    public var trackToTrackRatio: Double { writeTrackToTrackMs / readTrackToTrackMs }

    /// Une loi de lecture, et le seek d'écriture qui va avec.
    public func applied(to seek: SeekModel, averageSeekMs: Double, trackToTrackMs: Double,
                        cylinders: Int) -> SeekModel {
        seek.withWriteSeek(averageSeekMs: averageSeekMs * averageRatio,
                           trackToTrackMs: trackToTrackMs * trackToTrackRatio,
                           cylinders: cylinders)
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
/// loge, **la plus ancienne cède la place**. C'est une file et non la gestion
/// « au plus anciennement utilisé » du Conner : une entrée relue n'est pas
/// rajeunie. L'écart n'a pas été mesuré. Le nombre de flux servis
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
    ///
    /// **Une hypothèse, pour toutes les fiches qui l'ont.** Aucun manuel du
    /// catalogue ne décrit ce réordonnancement. Le « Read-on-arrival » du
    /// Fireball TM, qui a longtemps servi de source, qualifie un **temps de
    /// seek** — « Seek times: Read-on-arrival, Typical 12.0 ms », contre 14,0
    /// pour une écriture : la lecture commence dès que la tête arrive, avant la
    /// fin de l'asservissement — et le même manuel le désactive pour tenir ses
    /// taux d'erreur. Le mécanisme est plausible pour un disque à tampon
    /// segmenté ; il n'est pas sourcé. Le Conner de 1993 ne l'a pas.
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
    /// rapides, où il est sans doute surestimé, ni sur le Fireball de 1996, trois
    /// ans avant la mesure et derrière un bus PIO — où il est sans doute
    /// sous-estimé. **Une mesure d'un point**, étendue à dix ans.
    public static let measuredOverheadMs = 0.2

    /// Interface série : plus rapide que l'Ultra DMA/133, le dernier mode du
    /// bus parallèle. Un disque SATA ne se branche pas sur une nappe IDE, et la
    /// machine qui le porte a un contrôleur SATA.
    public var isSerial: Bool { interfaceMBs > 133 }
}

/// Les disques sur lesquels le modèle est calibré, de 1993 à 2012.
///
/// Vingt ans qui couvrent toute la période des scénarios embarqués, avec un
/// point tous les deux ou trois ans — c'est la résolution qu'il faut, la
/// densité doublant environ chaque année sur la fin des années 90.
public enum DriveCatalog {

    /// Largeur de la bande de données d'un plateau 3,5 pouces, en pouces.
    ///
    /// Les données n'occupent pas tout le plateau : il reste un moyeu au
    /// centre et une garde au bord. Cette largeur est le seul paramètre du
    /// modèle qui ne vienne pas d'une fiche — elle vaut environ 28 mm sur
    /// toute la période, et c'est elle qui convertit une densité de pistes en
    /// nombre de cylindres. Réglée à 1,10 pouce, elle faisait retomber le débit
    /// externe brut du Barracuda 7200.7 et du 7200.10 sur celui de leurs
    /// manuels à 5 % près — contre la fiche du 7200.10 d'alors, qui portait les
    /// 78 Mo/s des 750 Go. Contre la bonne, 72 Mo/s, le brut la dépasse de
    /// 10 % ; c'est la lecture simulée, commutations comprises, qui se compare
    /// aux manuels (`SequentialThroughputTests`). Le débit n'entre pas dans le
    /// calage.
    public static let dataBandInches = 1.10

    /// Rayon externe de la zone de données d'un plateau 3,5 pouces, en pouces.
    public static let outerRadiusInches = 1.831

    /// Rayon externe de la zone de données, selon le diamètre des plateaux.
    ///
    /// Un plateau de 2,5 pouces mesure 65 mm contre 95 : sa bande de données
    /// s'arrête vers 1,25 pouce du centre, dans le même rapport. C'est ce rayon
    /// qui fixe la vitesse de l'air au bord, donc le souffle.
    public static func outerRadiusInches(platterInches: Double) -> Double {
        platterInches < 3 ? 1.25 : outerRadiusInches
    }

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
                      + "enabled » à la mise sous tension. La lecture sans latence n'y est "
                      + "pas : « Read-on-arrival » y qualifie un seek (voir `zeroLatencyRead`)"),
            writeSeek: WriteSeek(
                readAverageMs: 12.0, writeAverageMs: 14.0,
                readTrackToTrackMs: 3.0, writeTrackToTrackMs: 3.0,
                source: "Manuel Fireball TM (81-111394-02), table 4-3 — « Random Average "
                      + "(Write) 14.0 ms for one-disk drives » contre 12,0 en lecture ; le "
                      + "piste-à-piste n'a pas de colonne d'écriture")),

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
                      + "look-ahead and write caching features enabled »"),
            writeSeek: WriteSeek(
                readAverageMs: 10.5, writeAverageMs: 11.5,
                readTrackToTrackMs: 1.5, writeTrackToTrackMs: 2.1,
                source: "Manuel Seagate U8, §1.5 — « Track-to-track 1.5 / 2.1 », "
                      + "« Average 10.5 / 11.5 » (lecture / écriture)")),

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
                      + "d'écriture actifs à la mise sous tension"),
            writeSeek: WriteSeek(
                readAverageMs: 9.0, writeAverageMs: 10.0,
                readTrackToTrackMs: 1.0, writeTrackToTrackMs: 1.2,
                source: "Manuel Seagate Barracuda ATA IV, table 1 — « Average seek, write "
                      + "10.0 » contre 9,0 pour un plateau, « 1.0 (read), 1.2 (write) » en "
                      + "piste-à-piste. La table du §1.5 donne 0,95 / 0,76, l'écriture sous "
                      + "la lecture : c'est la table 1 qui est retenue")),

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
                      + "d'écriture actifs à la mise sous tension"),
            writeSeek: WriteSeek(
                readAverageMs: 9.0, writeAverageMs: 10.0,
                readTrackToTrackMs: 1.0, writeTrackToTrackMs: 1.2,
                source: "Manuel Seagate Barracuda ATA IV, table 1 — « Average seek, write "
                      + "10.0 » contre 9,0 pour un plateau, « 1.0 (read), 1.2 (write) » en "
                      + "piste-à-piste. La table du §1.5 donne 0,95 / 0,76, l'écriture sous "
                      + "la lecture : c'est la table 1 qui est retenue")),

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
                      + "lecture anticipée et cache d'écriture actifs à la mise sous tension"),
            writeSeek: WriteSeek(
                readAverageMs: 8.5, writeAverageMs: 9.5,
                readTrackToTrackMs: 1.0, writeTrackToTrackMs: 1.2,
                source: "Manuel Seagate Barracuda 7200.7, §2.7 — « Track-to-track <1.0 / "
                      + "<1.2 », « Average 8.5 / 9.5 » (lecture / écriture)")),

        DriveReference(
            model: "Seagate Barracuda 7200.10 ST3320620A",
            shortName: "Barracuda 7200.10",
            year: 2006, capacityBytes: 320_072_933_376, heads: 4,
            tracksPerFace: 159_500, rpm: 7_200,
            averageSeekMs: 11.0, trackToTrackMs: 0.8,
            sustainedOuterMBs: 72,
            source: "Manuel Seagate Barracuda 7200.10 — 145 kTPI, 813 kBPI, "
                  + "enregistrement perpendiculaire, 2 plateaux. Seeks et débit de la "
                  + "table 2 (400 et 320 Go) : « <0.8 (read) », « Average seek, read "
                  + "<11.0 », 72 Mo/s soutenus — les 78 Mo/s et 8,5 ms sont ceux des "
                  + "750 et 500 Go",
            buffer: DriveBuffer(
                bufferKB: 16_384, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 100, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda 7200.10 PATA (100402369, rév. F), table 2 "
                      + "— 16 Mo pour le ST3320620A (8 Mo pour le ST3320820A), Ultra DMA "
                      + "mode 5, lecture anticipée et cache d'écriture actifs par défaut"),
            writeSeek: WriteSeek(
                readAverageMs: 11.0, writeAverageMs: 12.0,
                readTrackToTrackMs: 0.8, writeTrackToTrackMs: 1.0,
                source: "Manuel Seagate Barracuda 7200.10 PATA, table 2 — « <0.8 (read), "
                      + "<1.0 (write) », « Average seek, read <11.0 », « write <12.0 »")),

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
                      + "anticipée et cache d'écriture actifs par défaut"),
            writeSeek: WriteSeek(
                readAverageMs: 8.5, writeAverageMs: 9.5,
                readTrackToTrackMs: 1.0, writeTrackToTrackMs: 1.2,
                source: "Manuel Seagate Barracuda 7200.11, §2.5 — « Track-to-track <1.0 / "
                      + "<1.2 » (1 To), « Average <8.5 / <9.5 » (lecture / écriture)")),

        // Le disque de bureau de 2012 : un plateau de 1 To, deux têtes. Le
        // premier du catalogue à garer ses têtes sur une rampe — son manuel
        // compte des « Load/Unload cycles », là où celui du 7200.10 comptait
        // des « Contact start-stop cycles ».
        DriveReference(
            model: "Seagate Barracuda 7200.14 ST1000DM003",
            shortName: "Barracuda 7200.14",
            year: 2012, capacityBytes: 1_000_204_886_016, heads: 2,
            tracksPerFace: 387_200, rpm: 7_200,
            averageSeekMs: 8.5, trackToTrackMs: 1.0,
            sustainedOuterMBs: 210,
            rampLoad: true,
            source: "Manuel Seagate Barracuda 7200.14 (100686584, rév. G, octobre 2012), "
                  + "table 1 — 352 ktracks/in, 1 807 kFCI, 1 plateau et 2 têtes pour le "
                  + "ST1000DM003, 210 Mo/s soutenus au bord, 300 000 cycles de chargement",
            buffer: DriveBuffer(
                bufferKB: 65_536, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 600, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Manuel Seagate Barracuda 7200.14 (100686584, rév. G), table 1 — "
                      + "« Cache buffer 64MB », « I/O data-transfer rate (max) 600MB/s » "
                      + "(SATA 6 Gb/s). Le manuel ne dit rien de l'état du cache à la mise "
                      + "sous tension : celui des manuels Seagate précédents"),
            writeSeek: WriteSeek(
                readAverageMs: 8.5, writeAverageMs: 9.5,
                readTrackToTrackMs: 1.0, writeTrackToTrackMs: 1.2,
                source: "Manuel Seagate Barracuda 7200.14, §2.6 — « Track-to-track 1.0 / 1.2 », "
                      + "« Average 8.5 / 9.5 » (lecture / écriture)")),
    ]

    /// Les disques qu'on choisit par leur nom, hors de la courbe des époques.
    ///
    /// Ils ne sont ni des ancres ni des voisins d'une année : un 10 000 tr/min
    /// à plateaux de 2,5 pouces n'est pas « le disque de 2012 », c'est un
    /// disque de niche, et le prendre pour son époque tordrait la densité, le
    /// seek et le tampon de tous les disques déduits d'une année.
    public static let named: [DriveReference] = [

        // Trois plateaux de 334 Go, six têtes (base de plateaux rml527). Le
        // manuel ne publie ni seek ni densité : les deux viennent du test de
        // Tom's Hardware (2012) sur ce disque-là. Débit mesuré 209,1 Mo/s au
        // bord et 114,7 au moyeu, d'où le rapport interne et, par la capacité,
        // les pistes par face ; accès aléatoire en lecture 6,78 ms, dont 3,0 ms
        // de latence moyenne à 10 000 tr/min. Le piste-à-piste est celui de la
        // génération précédente, la seule fiche VelociRaptor qui le publie.
        DriveReference(
            model: "Western Digital VelociRaptor WD1000DHTZ",
            shortName: "VelociRaptor",
            year: 2012, capacityBytes: 1_000_204_886_016, heads: 6,
            tracksPerFace: 171_600, rpm: 10_000,
            averageSeekMs: 3.8, trackToTrackMs: 0.7,
            sustainedOuterMBs: 200,
            isAnchor: false,
            platterInches: 2.5,
            innerRatio: 0.55,
            rampLoad: true,
            source: "Fiche WD 2879-701284-A05 (avril 2012) — 1 953 525 168 secteurs, "
                  + "10 000 tr/min, 200 Mo/s soutenus, 30 dBA au repos et 37 en seek "
                  + "(puissance acoustique), rampe NoTouch. Tom's Hardware (2012) — "
                  + "209,1 → 114,7 Mo/s, accès en lecture 6,78 ms. Fiche WD "
                  + "2879-701284-A00 (2008, WD3000HLFS) — piste-à-piste 0,7 ms",
            buffer: DriveBuffer(
                bufferKB: 65_536, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 600, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Fiche WD 2879-701284-A05 — « Cache (MB) 64 », SATA 6 Gb/s. La "
                      + "fiche de 2008 annonce la lecture « adaptive » et le cache "
                      + "d'écriture actif ; celle de 2012 n'en dit rien de plus")),

        // Le même, sur deux plateaux et trois têtes (base rml527) : la
        // capacité qu'on achetait pour un disque système. Même densité par
        // face, même bras, même tampon ; la fiche de 2012 couvre les trois
        // capacités d'une colonne chacune.
        DriveReference(
            model: "Western Digital VelociRaptor WD5000HHTZ",
            shortName: "VelociRaptor",
            year: 2012, capacityBytes: 500_107_862_016, heads: 3,
            tracksPerFace: 171_600, rpm: 10_000,
            averageSeekMs: 3.8, trackToTrackMs: 0.7,
            sustainedOuterMBs: 200,
            isAnchor: false,
            platterInches: 2.5,
            innerRatio: 0.55,
            rampLoad: true,
            source: "Fiche WD 2879-701284-A05 (avril 2012) — 976 773 168 secteurs, les "
                  + "mêmes 10 000 tr/min, 200 Mo/s et 64 Mo que le WD1000DHTZ. Base de "
                  + "plateaux rml527 — 2 plateaux de 334 Go, 3 têtes. Seeks et débit au "
                  + "moyeu : ceux du WD1000DHTZ, même mécanique",
            buffer: DriveBuffer(
                bufferKB: 65_536, readAhead: true, writeCache: true, zeroLatencyRead: true,
                interfaceMBs: 600, commandOverheadMs: DriveBuffer.measuredOverheadMs,
                source: "Fiche WD 2879-701284-A05 — « Cache (MB) 64 », SATA 6 Gb/s")),
    ]

    /// Un disque du catalogue ou de la liste nommée, par son modèle ou son nom
    /// court.
    public static func reference(named name: String) -> DriveReference? {
        (named + all).first { $0.model == name || $0.shortName == name }
    }

    /// Rapport entre les secteurs de la piste interne et ceux de la piste
    /// externe, par époque.
    ///
    /// Ce rapport ne suit pas la capacité mais l'élargissement de la bande de
    /// données vers le moyeu : un disque des années 90 n'écrit que sur une
    /// couronne étroite, un disque de 2003 descend bien plus bas. C'est lui qui
    /// fixe l'écart de débit entre le début et la fin d'un volume — donc la
    /// différence de texture entre une lecture en tête de disque et la même en
    /// fin de disque.
    ///
    /// Le point de 2012 est le seul tiré d'un manuel : le 7200.14 publie un
    /// débit moyen (156 Mo/s) à côté du débit au bord (210), et sur une bande
    /// où les secteurs par piste décroissent linéairement, la moyenne vaut
    /// bord × (1 + rapport) / 2 — d'où 0,486.
    static let innerRatioByYear: [(year: Int, ratio: Double)] = [
        (1993, 0.67), (1996, 0.67), (1999, 0.60), (2001, 0.55), (2003, 0.52), (2008, 0.52),
        (2012, 0.486),
    ]

    /// Les fiches qui ancrent l'interpolation, une par année, dans l'ordre.
    static var anchors: [DriveReference] {
        all.filter(\.isAnchor).sorted { $0.year < $1.year }
    }

    /// Le disque du catalogue le plus proche d'une année donnée.
    public static func nearest(year: Int) -> DriveReference {
        all.min { abs($0.year - year) < abs($1.year - year) } ?? all[0]
    }

    /// Les seeks d'écriture d'un disque de cette année : ceux de sa fiche si
    /// elle les publie, sinon ceux de la fiche la plus proche qui les publie.
    ///
    /// Le Conner de 1993 est le seul du catalogue à ne pas en avoir — le
    /// manuel du Cougar, son voisin, ne publie qu'un seek moyen. Les disques
    /// de 1993 reçoivent donc le rapport du Fireball de 1996 : **une
    /// hypothèse**, celle qu'un disque de 1993 n'écrivait pas plus vite qu'il
    /// ne lisait, ce qu'aucun disque à asservissement ne fait.
    public static func writeSeek(year: Int, reference: DriveReference? = nil) -> WriteSeek? {
        if let own = reference?.writeSeek { return own }
        return all.filter { $0.writeSeek != nil }
            .min { abs($0.year - year) < abs($1.year - year) }?.writeSeek
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

    /// La mécanique d'un disque déduit de son régime et de son année : la
    /// densité de ses faces, et la taille de ses plateaux.
    ///
    /// Jusqu'à 7 200 tr/min, c'est la courbe des époques sur des plateaux de
    /// 3,5 pouces. **À 10 000 tr/min à partir de 2008**, c'est celle du
    /// VelociRaptor : des plateaux de 2,5 pouces, dont les faces portent, par
    /// rapport à celles du disque de bureau de la même année, ce que le
    /// WD1000DHTZ portait par rapport au 7200.14 en 2012 — 44 % des pistes et
    /// un tiers des octets. Un 10 000 tr/min déduit de 2012 retrouve donc
    /// exactement la fiche du VelociRaptor ; un de 2009, la même mécanique à la
    /// densité de 2009. **Une seule fiche** porte cette règle : aucune autre ne
    /// donne à la fois le débit au bord et au moyeu d'un 10 000 tr/min de
    /// bureau.
    ///
    /// Avant 2008, un 10 000 tr/min est un Raptor, à plateaux de 3,5 pouces :
    /// il reste sur la courbe, faute d'une fiche qui dise la taille de ses
    /// plateaux. Il en sort plus bruyant, ce que les Raptor étaient.
    static func mechanics(rpm: Int, year: Int)
        -> (density: (tracksPerFace: Double, bytesPerFace: Double, innerRatio: Double),
            platterInches: Double) {
        let era = density(year: year)
        guard let small = smallPlatter(rpm: rpm, year: year) else { return (era, 3.5) }
        let then = density(year: small.year)
        return ((era.tracksPerFace * Double(small.tracksPerFace) / then.tracksPerFace,
                 era.bytesPerFace * small.bytesPerFace / then.bytesPerFace,
                 small.innerRatio ?? era.innerRatio),
                small.platterInches)
    }

    /// La fiche dont un disque déduit prend la mécanique, quand ce n'est pas
    /// la courbe des 3,5 pouces : le VelociRaptor, pour un 10 000 tr/min
    /// d'après 2008.
    public static func smallPlatter(rpm: Int, year: Int) -> DriveReference? {
        guard rpm >= 10_000, year >= smallPlatterYear else { return nil }
        return named.first
    }

    /// L'année des premiers VelociRaptor, les premiers 10 000 tr/min de
    /// bureau à plateaux de 2,5 pouces (fiche WD 2879-701284-A00, 2008).
    public static let smallPlatterYear = 2008

    /// Le rapport entre les secteurs de la piste interne et ceux de la piste
    /// externe pour un disque de cette année (`innerRatioByYear`, interpolé).
    public static func innerRatio(year: Int) -> Double {
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
    ///
    /// Hors de la courbe des époques — des plateaux qui ne sont pas de 3,5
    /// pouces —, la densité n'est pas celle de l'année mais celle de la fiche.
    public var geometry: DriveGeometry {
        guard !followsEra else {
            return DriveGeometry.era(model: label,
                                     capacityBytes: capacityBytes,
                                     rpm: rpm,
                                     year: year,
                                     heads: heads)
        }
        return DriveGeometry.zoned(model: label,
                                   capacityBytes: capacityBytes,
                                   rpm: rpm,
                                   density: (Double(tracksPerFace), bytesPerFace,
                                             innerRatio ?? DriveCatalog.density(year: year).innerRatio),
                                   heads: heads,
                                   platterInches: platterInches)
    }

    /// La loi de seek de ce disque-là, calée sur les deux durées de sa fiche,
    /// et sur celles d'écriture quand elle les publie.
    public var seekModel: SeekModel {
        let cylinders = geometry.cylinders
        let read = SeekModel.calibrated(averageSeekMs: averageSeekMs,
                                        trackToTrackMs: trackToTrackMs,
                                        cylinders: cylinders)
        return DriveCatalog.writeSeek(year: year, reference: self)?
            .applied(to: read, averageSeekMs: averageSeekMs, trackToTrackMs: trackToTrackMs,
                     cylinders: cylinders) ?? read
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
