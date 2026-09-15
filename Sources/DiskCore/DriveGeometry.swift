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
