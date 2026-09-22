import Foundation

/// Géométrie d'un disque dur à plateaux avec enregistrement zoné (ZBR).
///
/// Le cylindre 0 est le plus **externe** : c'est lui qui porte le plus de secteurs
/// par piste et qui héberge les LBA les plus bas. C'est pour cette raison que les
/// fichiers système d'un Windows fraîchement installé se retrouvent sur les
/// cylindres extérieurs, et que le bruit de démarrage reste confiné à une zone
/// étroite du disque.
public struct DriveGeometry: Sendable {

    public struct Zone: Sendable {
        public let firstCylinder: Int
        public let sectorsPerTrack: Int

        public init(firstCylinder: Int, sectorsPerTrack: Int) {
            self.firstCylinder = firstCylinder
            self.sectorsPerTrack = sectorsPerTrack
        }
    }

    public struct Position: Sendable {
        public let cylinder: Int
        public let head: Int
        public let sector: Int

        public init(cylinder: Int, head: Int, sector: Int) {
            self.cylinder = cylinder
            self.head = head
            self.sector = sector
        }
    }

    public static let bytesPerSector = 512

    public let model: String
    public let cylinders: Int
    public let heads: Int
    public let rpm: Double
    public let zones: [Zone]
    /// Diamètre des plateaux, en pouces : il ne change rien à l'adressage, mais
    /// la vitesse de l'air au bord — donc le souffle — en dépend.
    public let platterInches: Double

    private let sectorsPerTrackByCylinder: [Int]
    /// LBA du premier secteur de chaque cylindre, `cylinders + 1` entrées.
    private let cylinderStartLBA: [Int]

    public init(model: String, cylinders: Int, heads: Int, rpm: Double, zones: [Zone],
                platterInches: Double = 3.5) {
        precondition(cylinders > 1 && heads > 0)
        precondition(!zones.isEmpty && zones[0].firstCylinder == 0)

        self.model = model
        self.cylinders = cylinders
        self.heads = heads
        self.rpm = rpm
        self.zones = zones
        self.platterInches = platterInches

        var spt = [Int](repeating: 0, count: cylinders)
        var zoneIndex = 0
        for cylinder in 0..<cylinders {
            while zoneIndex + 1 < zones.count && zones[zoneIndex + 1].firstCylinder <= cylinder {
                zoneIndex += 1
            }
            spt[cylinder] = zones[zoneIndex].sectorsPerTrack
        }
        self.sectorsPerTrackByCylinder = spt

        var starts = [Int](repeating: 0, count: cylinders + 1)
        var accumulator = 0
        for cylinder in 0..<cylinders {
            starts[cylinder] = accumulator
            accumulator += spt[cylinder] * heads
        }
        starts[cylinders] = accumulator
        self.cylinderStartLBA = starts
    }

    // MARK: - Dérivés

    /// Durée d'un tour de plateau. 8,33 ms à 7 200 tr/min.
    public var revolutionDuration: Double { 60.0 / rpm }

    public var totalSectors: Int { cylinderStartLBA[cylinders] }

    public var capacityBytes: Int { totalSectors * Self.bytesPerSector }

    public var capacityDescription: String {
        FrenchUnits.megabytes(UInt64(max(capacityBytes, 0)))
    }

    public func sectorsPerTrack(cylinder: Int) -> Int {
        sectorsPerTrackByCylinder[min(max(cylinder, 0), cylinders - 1)]
    }

    public func sectorsPerCylinder(_ cylinder: Int) -> Int {
        sectorsPerTrack(cylinder: cylinder) * heads
    }

    /// Conversion LBA → (cylindre, tête, secteur) par recherche dichotomique
    /// dans la table des cylindres — le zonage interdit une formule fermée.
    public func position(ofLBA lba: Int) -> Position {
        let clamped = min(max(lba, 0), totalSectors - 1)

        var low = 0
        var high = cylinders - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if cylinderStartLBA[mid] <= clamped { low = mid } else { high = mid - 1 }
        }

        let cylinder = low
        let offset = clamped - cylinderStartLBA[cylinder]
        let spt = sectorsPerTrackByCylinder[cylinder]
        return Position(cylinder: cylinder, head: offset / spt, sector: offset % spt)
    }

    /// L'inverse de `position(ofLBA:)`.
    public func lba(of position: Position) -> Int {
        cylinderStartLBA[min(max(position.cylinder, 0), cylinders)]
            + position.head * sectorsPerTrack(cylinder: position.cylinder)
            + position.sector
    }

    public func lba(ofFraction fraction: Double) -> Int {
        let f = min(max(fraction, 0), 0.999_999)
        return Int(f * Double(totalSectors))
    }

    /// Cylindre de parcage du bras, moteur à l'arrêt, pour un disque à
    /// contact (*contact start-stop*) : le diamètre intérieur, sur la zone
    /// d'atterrissage. Un disque qu'on allume en part pour chercher sa piste 0
    /// (`DiskMechanics.start`). Un disque à rampe se parque **au bord**, pas
    /// au moyeu : `parkCylinder(rampLoad:)`.
    ///
    /// Une passe sur un plateau qui tourne déjà part aussi de là, et ce n'est
    /// **pas** un fait : aucun disque de bureau de la période ne parquait au
    /// repos, et le bras est resté où le dernier accès l'a laissé. Le modèle ne
    /// le sait pas ; le moyeu est une convention, qui fait du premier accès
    /// d'une passe une course presque complète.
    public var parkCylinder: Int { cylinders - 1 }

    /// Le cylindre de parcage selon le mécanisme : sur un 3,5 pouces à
    /// *load/unload*, la rampe est au **diamètre extérieur** — le bras y monte
    /// depuis la piste 0 et en redescend ; un tel disque ne commence ni ne
    /// finit sa vie par une pleine course. La convention du moyeu ne vaut
    /// que pour les têtes qui se posent sur le plateau.
    public func parkCylinder(rampLoad: Bool) -> Int { rampLoad ? 0 : parkCylinder }

    /// Décalage angulaire du secteur 0 d'une piste à la suivante : le *skew*,
    /// tel que ces disques étaient formatés en usine.
    ///
    /// Une lecture qui franchit une piste paie d'abord le déplacement — une
    /// commutation de tête, ou un pas de piste — et pendant ce temps le plateau
    /// continue de tourner. Si le secteur 0 de toutes les pistes était au même
    /// angle, il serait déjà passé : il faudrait attendre un tour presque
    /// entier à chaque piste, et un disque ne lirait jamais plus vite qu'une
    /// piste par tour. Le formatage décale donc chaque piste de ce que coûte
    /// exactement le franchissement, et la lecture séquentielle ne paie rien.
    ///
    /// Les deux décalages ne sont pas le même : `head` couvre la commutation de
    /// tête à l'intérieur d'un cylindre, `track` le pas de piste vers le
    /// cylindre suivant. Les grandeurs sont en **tours**, parce que c'est ainsi
    /// qu'elles s'ajoutent à un angle.
    public struct TrackSkew: Sendable, Equatable {
        public let track: Double
        public let head: Double

        public init(track: Double, head: Double) {
            self.track = track
            self.head = head
        }

        /// Pas de décalage : le secteur 0 au même angle sur toutes les pistes.
        /// C'est l'hypothèse qu'aucun disque à plateaux n'a jamais vérifiée, et
        /// elle ne sert qu'à mesurer ce que le skew rend.
        public static let none = TrackSkew(track: 0, head: 0)
    }

    /// Le skew de ce disque, déduit de sa loi de seek : ce que coûte un pas de
    /// piste et une commutation de tête, comptés en tours de plateau.
    public func skew(seekModel: SeekModel) -> TrackSkew {
        let revolution = revolutionDuration
        guard revolution > 0 else { return .none }
        return TrackSkew(track: seekModel.duration(distance: 1) / revolution,
                         head: seekModel.headSwitchDuration / revolution)
    }

    /// Angle, en tours depuis l'index, auquel un secteur passe sous la tête.
    ///
    /// C'est **la** fonction qui dit où est un secteur : la latence
    /// rotationnelle d'une requête comme le franchissement de piste au milieu
    /// d'un transfert s'y réfèrent, et ne peuvent donc plus se contredire.
    ///
    /// Le décalage d'un cylindre au suivant absorbe en plus le retour de la
    /// dernière tête à la première : on quitte la piste `(c, heads-1)` et on
    /// rejoint `(c+1, 0)`, ce qui défait `heads-1` décalages de tête. Sans ce
    /// terme, la continuité serait vraie d'une tête à l'autre et fausse d'un
    /// cylindre à l'autre — soit l'incohérence qu'on corrige.
    public func angleOf(_ position: Position, skew: TrackSkew) -> Double {
        let spt = Double(sectorsPerTrack(cylinder: position.cylinder))
        let cylinderSkew = skew.track + Double(heads - 1) * skew.head
        let angle = Double(position.sector) / spt
            + Double(position.cylinder) * cylinderSkew
            + Double(position.head) * skew.head
        return angle - angle.rounded(.down)
    }

    /// Rayon physique normalisé : 1,0 au bord (cylindre 0), 0,42 au moyeu.
    public func normalizedRadius(cylinder: Int) -> Double {
        normalizedRadius(cylinder: Double(cylinder))
    }

    /// La même chose pour une position continue : pendant un seek comme pendant
    /// un transfert séquentiel, le bras est entre deux cylindres.
    public func normalizedRadius(cylinder: Double) -> Double {
        let last = Double(cylinders - 1)
        let f = min(max(cylinder, 0), last) / last
        return 1.0 - f * (1.0 - 0.42)
    }
}

extension DriveGeometry {

    /// Nombre de têtes au-delà duquel un disque à plateaux de cette période
    /// n'existe pas. Cinq plateaux dans un boîtier 3,5 pouces d'un pouce de
    /// haut, c'est le maximum qu'on ait vu en production.
    private static let maximumHeads = 10

    /// Écart de densité linéaire toléré avant de corriger la surface.
    ///
    /// Deux disques d'une même année n'ont pas exactement la même densité : à
    /// nombre de plateaux égal, les modèles du haut d'une gamme poussent le
    /// canal de 20 à 40 % au-dessus de ceux du bas. Tant que l'écart tient dans
    /// cette marge, c'est donc la densité qui absorbe la capacité demandée.
    /// Au-delà, elle ne le peut plus — le canal de lecture est ce qu'il est
    /// cette année-là — et c'est le nombre de pistes qui bouge.
    private static let densityHeadroom = 1.20

    /// Plancher de pistes. En deçà, la bande de données ne serait plus qu'un
    /// anneau de quelques dixièmes de millimètre : aucun disque ne ressemble à
    /// cela, et une capacité si faible pour son époque se décrit mieux par une
    /// densité relâchée que par une surface absurde.
    private static let minimumCylinders = 256

    /// Nombre de zones d'enregistrement. Les disques de la période en
    /// comptaient de huit à une trentaine ; seize donne un escalier de débit
    /// assez fin pour qu'un balayage de tout le volume s'entende descendre.
    private static let zoneCount = 16

    /// Géométrie plausible pour un disque dont on ne connaît que la fiche
    /// commerciale : une capacité, un régime, une année.
    ///
    /// Le modèle n'a qu'une idée, et elle vient des fiches réunies dans
    /// `DriveCatalog` : ce qui progresse avec le temps, ce n'est pas « la
    /// densité » en général, ce sont **deux** grandeurs qui progressent à des
    /// rythmes différents — le nombre de pistes par face et la capacité d'une
    /// face. La première fixe la course du bras, donc l'acoustique des seeks ;
    /// la seconde, combinée à la capacité demandée, fixe le nombre de faces.
    /// Les secteurs par piste ne sont pas un troisième paramètre libre : ils
    /// tombent du quotient des deux.
    ///
    /// C'est ce qui manquait au modèle précédent, qui faisait tout porter à la
    /// densité linéaire : il donnait 640 cylindres à un disque de 1993 qui en
    /// avait 2 111, et 235 000 à un 320 Go de 2007 qui en a 160 000 — dans les
    /// deux cas la course était fausse d'un facteur trois.
    ///
    /// La capacité obtenue est **au moins** celle demandée : un volume ne doit
    /// jamais déborder du disque qui le porte.
    ///
    /// - Parameters:
    ///   - year: année de mise en service. C'est elle qui choisit la densité,
    ///     et elle seule : deux disques de même capacité mais de cinq ans
    ///     d'écart n'ont ni la même course, ni le même débit, ni le même bruit.
    ///   - heads: nombre de faces, quand on veut l'imposer. Sinon il est déduit
    ///     de la capacité demandée et de ce que porte une face cette année-là.
    ///   - rpm: le régime fait tourner le plateau, et à 10 000 tr/min depuis
    ///     2008 il en change aussi la taille (`DriveCatalog.mechanics`).
    public static func era(model: String,
                           capacityBytes: UInt64,
                           rpm: Int,
                           year: Int,
                           heads forcedHeads: Int? = nil,
                           zbr: Bool = true) -> DriveGeometry {
        let mechanics = DriveCatalog.mechanics(rpm: rpm, year: year)
        return zoned(model: model, capacityBytes: capacityBytes, rpm: rpm,
                     density: mechanics.density,
                     heads: forcedHeads, zbr: zbr,
                     platterInches: mechanics.platterInches)
    }

    /// La même construction, pour une densité donnée plutôt que celle d'une
    /// année : celle d'une fiche qui ne suit pas la courbe des époques.
    public static func zoned(model: String,
                             capacityBytes: UInt64,
                             rpm: Int,
                             density: (tracksPerFace: Double, bytesPerFace: Double, innerRatio: Double),
                             heads forcedHeads: Int? = nil,
                             zbr: Bool = true,
                             platterInches: Double = 3.5) -> DriveGeometry {
        precondition(capacityBytes > 0 && rpm > 0)

        var cylinders = max(Int(density.tracksPerFace.rounded()), 2)
        let sectors = Int((Double(capacityBytes) / Double(bytesPerSector)).rounded(.up))

        // La densité linéaire est une propriété de l'époque, pas du modèle : à
        // une année donnée, tous les disques écrivent à peu près le même nombre
        // de bits par pouce de piste, parce que c'est le canal de lecture qui
        // le décide. On choisit donc le nombre de faces qui approche au mieux
        // cette densité-là — et non le plus petit qui suffirait.
        let referenceSPT = density.bytesPerFace / Double(bytesPerSector) / density.tracksPerFace
        let heads = forcedHeads ?? bestHeadCount(capacityBytes: capacityBytes,
                                                 bytesPerFace: density.bytesPerFace)

        // Les secteurs par piste ne se choisissent pas : ce sont ceux qu'il
        // faut pour que la capacité demandée tienne sur les pistes disponibles.
        var meanSPT = Double(sectors) / Double(heads * cylinders)

        // Reste le cas des capacités qui n'existaient pas cette année-là : un
        // 6,4 Go en 2003 ne tient pas sur un plateau entier, un 6,4 Go en 1996
        // n'y tient pas même sur cinq. Là, ce n'est plus la densité qui cède —
        // elle est fixée par la technologie — c'est la surface : le disque a
        // moins de pistes, ou plus qu'il n'était possible d'en graver. Le
        // modèle le dit plutôt que de décrire un plateau à moitié vide.
        if meanSPT > referenceSPT * densityHeadroom {
            cylinders = Int((Double(cylinders) * meanSPT / (referenceSPT * densityHeadroom)).rounded(.up))
        } else if meanSPT < referenceSPT / densityHeadroom {
            cylinders = max(Int((Double(cylinders) * meanSPT * densityHeadroom / referenceSPT).rounded(.up)),
                            minimumCylinders)
        }
        meanSPT = Double(sectors) / Double(heads * cylinders)

        let outerSPT = zbr ? meanSPT * 2 / (1 + density.innerRatio) : meanSPT

        func zones(outer: Double) -> [Zone] {
            guard zbr else {
                return [Zone(firstCylinder: 0, sectorsPerTrack: max(Int(outer.rounded()), 1))]
            }
            return (0..<zoneCount).map { index in
                let taper = (1 - density.innerRatio) * Double(index) / Double(zoneCount - 1)
                return Zone(firstCylinder: cylinders * index / zoneCount,
                            sectorsPerTrack: max(Int((outer * (1 - taper)).rounded()), 1))
            }
        }

        // Les secteurs par piste sont des entiers et les bornes de zones
        // tombent sur des cylindres entiers : la capacité réelle s'écarte de
        // quelques pour mille. On la mesure et on serre la densité d'un secteur
        // à la fois jusqu'à couvrir ce qui est demandé — jamais l'inverse.
        var outer = outerSPT
        var drive = DriveGeometry(model: model, cylinders: cylinders, heads: heads,
                                  rpm: Double(rpm), zones: zones(outer: outer),
                                  platterInches: platterInches)
        var attempts = 0
        while drive.totalSectors < sectors && attempts < 16 {
            outer += 1
            drive = DriveGeometry(model: model, cylinders: cylinders, heads: heads,
                                  rpm: Double(rpm), zones: zones(outer: outer),
                                  platterInches: platterInches)
            attempts += 1
        }

        // Filet de sécurité : sur un disque de très peu de pistes, un secteur
        // de plus par piste ne rattrape presque rien et l'escalier des zones
        // peut rester court. On allonge alors la surface, ce qui converge
        // toujours — un volume ne doit jamais déborder du disque qui le porte.
        while drive.totalSectors < sectors {
            let deficit = sectors - drive.totalSectors
            cylinders += max(deficit / max(drive.sectorsPerCylinder(cylinders - 1), 1), 1)
            drive = DriveGeometry(model: model, cylinders: cylinders, heads: heads,
                                  rpm: Double(rpm), zones: zones(outer: outer),
                                  platterInches: platterInches)
        }
        return drive
    }
}

extension DriveGeometry {

    /// Nombre de faces qui rapproche le plus la densité linéaire de celle de
    /// l'époque. L'écart se mesure en rapport et non en différence : une face
    /// de trop divise la densité, une face de moins la multiplie, et c'est le
    /// même défaut des deux côtés.
    private static func bestHeadCount(capacityBytes: UInt64, bytesPerFace: Double) -> Int {
        let ideal = Double(capacityBytes) / bytesPerFace
        var best = 1
        var bestError = Double.infinity
        for heads in 1...maximumHeads {
            let error = abs(log(ideal / Double(heads)))
            if error < bestError {
                bestError = error
                best = heads
            }
        }
        return best
    }
}

extension DriveGeometry {

    /// Débit **brut** d'une piste, en Mo/s : ses secteurs à chaque tour, une
    /// fois la tête posée. Tout le tour est de la donnée — non parce que les
    /// rafales servo et les en-têtes n'existent pas, mais parce que les
    /// secteurs par piste sont déduits de la capacité, et que ce sont donc déjà
    /// des secteurs de données. Une lecture séquentielle paie en plus ses
    /// commutations de tête et ses pas de piste : c'est elle, et non ce débit,
    /// que mesure le « sustained data transfer rate » d'un manuel
    /// (`DriveReference`), et que ce débit borne par le haut.
    public func sustainedMBs(cylinder: Int) -> Double {
        Double(sectorsPerTrack(cylinder: cylinder)) * Double(Self.bytesPerSector) * rpm / 60 / 1_000_000
    }

    public var outerSustainedMBs: Double { sustainedMBs(cylinder: 0) }
    public var innerSustainedMBs: Double { sustainedMBs(cylinder: cylinders - 1) }
}
