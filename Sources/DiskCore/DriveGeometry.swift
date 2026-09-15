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

    private let sectorsPerTrackByCylinder: [Int]
    /// LBA du premier secteur de chaque cylindre, `cylinders + 1` entrées.
    private let cylinderStartLBA: [Int]

    public init(model: String, cylinders: Int, heads: Int, rpm: Double, zones: [Zone]) {
        precondition(cylinders > 1 && heads > 0)
        precondition(!zones.isEmpty && zones[0].firstCylinder == 0)

        self.model = model
        self.cylinders = cylinders
        self.heads = heads
        self.rpm = rpm
        self.zones = zones

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
        let gb = Double(capacityBytes) / 1_000_000_000
        return String(format: "%.1f Go", gb)
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

    public func lba(ofFraction fraction: Double) -> Int {
        let f = min(max(fraction, 0), 0.999_999)
        return Int(f * Double(totalSectors))
    }

    /// Rayon physique normalisé : 1,0 au bord (cylindre 0), 0,42 au moyeu.
    public func normalizedRadius(cylinder: Int) -> Double {
        let f = Double(min(max(cylinder, 0), cylinders - 1)) / Double(cylinders - 1)
        return 1.0 - f * (1.0 - 0.42)
    }

    // MARK: - Modèle par défaut

    /// Disque IDE générique de 2001 : 7 200 tr/min, 4 têtes, 12 zones.
    public static let defaultDrive = DriveGeometry(
        model: "IDE 20 Go · 7 200 tr/min",
        cylinders: 24_000,
        heads: 4,
        rpm: 7_200,
        zones: [
            Zone(firstCylinder: 0,      sectorsPerTrack: 468),
            Zone(firstCylinder: 2_000,  sectorsPerTrack: 448),
            Zone(firstCylinder: 4_000,  sectorsPerTrack: 428),
            Zone(firstCylinder: 6_000,  sectorsPerTrack: 408),
            Zone(firstCylinder: 8_000,  sectorsPerTrack: 388),
            Zone(firstCylinder: 10_000, sectorsPerTrack: 368),
            Zone(firstCylinder: 12_000, sectorsPerTrack: 348),
            Zone(firstCylinder: 14_000, sectorsPerTrack: 328),
            Zone(firstCylinder: 16_000, sectorsPerTrack: 308),
            Zone(firstCylinder: 18_000, sectorsPerTrack: 288),
            Zone(firstCylinder: 20_000, sectorsPerTrack: 268),
            Zone(firstCylinder: 22_000, sectorsPerTrack: 248),
        ]
    )
}

extension DriveGeometry {

    /// Disque IDE de milieu des années 90, celui sur lequel tournait un
    /// défragmenteur Windows 95 : 876 Mo, 4 500 tr/min, 2 000 cylindres,
    /// 8 zones. Le débit va de 9,8 Mo/s au bord à 6,6 Mo/s au moyeu — haut de
    /// la fourchette pour l'époque, mais c'est ce qui donne à la passe une
    /// durée auditionnable.
    public static let win95Drive = DriveGeometry(
        model: "IDE 876 Mo · 4 500 tr/min",
        cylinders: 2_000,
        heads: 4,
        rpm: 4_500,
        zones: [
            Zone(firstCylinder: 0,     sectorsPerTrack: 256),
            Zone(firstCylinder: 250,   sectorsPerTrack: 244),
            Zone(firstCylinder: 500,   sectorsPerTrack: 232),
            Zone(firstCylinder: 750,   sectorsPerTrack: 220),
            Zone(firstCylinder: 1_000, sectorsPerTrack: 208),
            Zone(firstCylinder: 1_250, sectorsPerTrack: 196),
            Zone(firstCylinder: 1_500, sectorsPerTrack: 184),
            Zone(firstCylinder: 1_750, sectorsPerTrack: 172),
        ]
    )
}

extension DriveGeometry {

    /// Rapport entre la piste la plus interne et la plus externe. 0,67 sur le
    /// disque de 1996 modélisé ci-dessus, et l'ordre de grandeur tient pour
    /// toute la période : c'est le rapport des rayons, pas la technologie, qui
    /// le fixe.
    private static let innerTrackRatio = 0.67
    private static let zoneCount = 8

    /// Densité de référence : le disque de 1996 porte 256 secteurs sur sa piste
    /// externe pour 0,8297 Gio de capacité.
    private static let referenceGibibytes = 0.829_7
    private static let referenceSectorsPerTrack = 256.0
    /// La densité linéaire ne suit pas la capacité : elle croît bien plus
    /// lentement, le reste venant du nombre de cylindres et de plateaux.
    /// Cet exposant place le disque de 2001 (17,6 Gio, 468 secteurs) à 2 % près.
    private static let densityExponent = 0.20

    /// Géométrie plausible pour un disque dont on ne connaît que la fiche :
    /// capacité, régime et présence d'un enregistrement zoné.
    ///
    /// Les deux disques modélisés à la main ci-dessus servent de points
    /// d'ancrage : même forme de zonage, même rapport bord/moyeu, densité
    /// interpolée sur la capacité. La capacité obtenue est **au moins** celle
    /// demandée — un volume ne doit jamais déborder du disque qui le porte.
    public static func era(model: String,
                           capacityBytes: UInt64,
                           rpm: Int,
                           heads: Int = 4,
                           zbr: Bool = true) -> DriveGeometry {
        precondition(capacityBytes > 0 && heads > 0 && rpm > 0)

        let gibibytes = Double(capacityBytes) / 1_073_741_824
        let outer = (referenceSectorsPerTrack
                     * pow(gibibytes / referenceGibibytes, densityExponent))
            .rounded()
        let outerSPT = Int(min(max(outer, 63), 1_024))

        // Le zonage descend linéairement du bord au moyeu : sa moyenne est la
        // demi-somme des deux extrêmes, ce qui donne une première estimation du
        // nombre de cylindres.
        let meanSPT = Double(outerSPT) * (1 + innerTrackRatio) / 2
        let sectors = Int((Double(capacityBytes) / Double(bytesPerSector)).rounded(.up))

        func zones(_ cylinders: Int) -> [Zone] {
            guard zbr else {
                return [Zone(firstCylinder: 0, sectorsPerTrack: max(Int(meanSPT.rounded()), 1))]
            }
            return (0..<zoneCount).map { index in
                let taper = (1 - innerTrackRatio) * Double(index) / Double(zoneCount - 1)
                return Zone(firstCylinder: cylinders * index / zoneCount,
                            sectorsPerTrack: max(Int((Double(outerSPT) * (1 - taper)).rounded()), 1))
            }
        }

        // Les secteurs par piste sont des entiers et les bornes de zones tombent
        // sur des cylindres entiers : la capacité réelle s'écarte de quelques
        // pour mille de l'estimation. On la mesure et on rallonge le disque
        // jusqu'à ce qu'elle couvre ce qui est demandé — jamais l'inverse, un
        // volume ne doit pas déborder du disque qui le porte.
        var cylinders = max(Int((Double(sectors) / (meanSPT * Double(heads))).rounded(.up)), 2)
        var drive = DriveGeometry(model: model, cylinders: cylinders, heads: heads,
                                  rpm: Double(rpm), zones: zones(cylinders))
        for _ in 0..<4 where drive.totalSectors < sectors {
            let deficit = sectors - drive.totalSectors
            cylinders += max(deficit / (drive.sectorsPerCylinder(cylinders - 1)), 1)
            drive = DriveGeometry(model: model, cylinders: cylinders, heads: heads,
                                  rpm: Double(rpm), zones: zones(cylinders))
        }
        return drive
    }
}
