import Foundation
import DiskCore

/// Ce qu'une commande coûte hors de la mécanique, et ce que le tampon du disque
/// en fait : le disque **dans sa machine**.
///
/// Le disque apporte sa fiche (`DriveBuffer`) : la taille de son tampon, sa
/// politique à la mise sous tension, le mode le plus rapide de son interface et
/// ce que coûte une commande. La machine apporte son bus, qui peut être plus
/// lent que le disque — et en 1993 c'est lui qui commande.
struct DriveInterface: Sendable, Equatable {

    /// Le tampon, s'il y en a un à simuler. `nil` : un disque qui ne sert que
    /// de la mécanique.
    var buffer: DriveBuffer?
    /// Débit du bus entre le tampon et la mémoire, en octets par seconde.
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
    /// Coût d'une commande hors mécanique, en secondes.
    var commandOverhead: Double

    /// Aucun tampon, aucun coût de commande, un bus infini : exactement la
    /// mécanique d'avant. C'est ce que prennent les tests de la mécanique seule,
    /// et ce qui prouve que le cache, coupé, ne change rien.
    static let direct = DriveInterface(buffer: nil,
                                       readBytesPerSecond: .infinity,
                                       writeBytesPerSecond: .infinity,
                                       commandOverhead: 0)

    /// Un disque de cette fiche, dans une machine de cette année-là.
    init(buffer: DriveBuffer, host: HostBus) {
        self.buffer = buffer
        readBytesPerSecond = min(buffer.interfaceMBs, host.readMBs) * 1_000_000
        writeBytesPerSecond = min(buffer.interfaceMBs, host.writeMBs) * 1_000_000
        commandOverhead = buffer.commandOverheadMs / 1_000
    }

    init(buffer: DriveBuffer?, readBytesPerSecond: Double, writeBytesPerSecond: Double,
         commandOverhead: Double) {
        self.buffer = buffer
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.commandOverhead = commandOverhead
    }

    /// Le disque d'une machine de l'année donnée : la fiche du catalogue la
    /// plus proche, le bus de l'époque.
    static func era(year: Int) -> DriveInterface {
        DriveInterface(buffer: DriveCatalog.nearest(year: year).buffer, host: .era(year: year))
    }

    /// Secteurs que le cache peut tenir. Zéro sans tampon.
    var cacheSectors: Int {
        (buffer?.cacheKB ?? 0) * 1_024 / DriveGeometry.bytesPerSector
    }

    var readAhead: Bool { buffer?.readAhead ?? false }
    var writeCache: Bool { buffer?.writeCache ?? false }
    var zeroLatencyRead: Bool { buffer?.zeroLatencyRead ?? false }

    /// Le même disque, lecture anticipée ou cache d'écriture forcés — pour
    /// mesurer chaque mécanisme seul.
    func with(readAhead: Bool? = nil, writeCache: Bool? = nil,
              zeroLatencyRead: Bool? = nil) -> DriveInterface {
        guard let buffer else { return self }
        var copy = self
        copy.buffer = DriveBuffer(bufferKB: buffer.bufferKB, cacheKB: buffer.cacheKB,
                                  readAhead: readAhead ?? buffer.readAhead,
                                  writeCache: writeCache ?? buffer.writeCache,
                                  zeroLatencyRead: zeroLatencyRead ?? buffer.zeroLatencyRead,
                                  interfaceMBs: buffer.interfaceMBs,
                                  commandOverheadMs: buffer.commandOverheadMs,
                                  source: buffer.source)
        return copy
    }
}

/// Le bus de la machine, entre le disque et la mémoire.
///
/// Le disque annonce le mode le plus rapide qu'il accepte ; c'est la machine qui
/// décide de celui qu'on utilise. Une valeur par époque de la galerie, chacune
/// d'une source :
///
/// | époque | machine | bus | source |
/// |---|---|---|---|
/// | 1993 | 486, contrôleur IDE sur ISA, PIO | 5,0 Mo/s | brevet US 5 678 064 : « The conventional ISA interface can theoretically support burst rates of 5 MByte/sec on the programmed I/O cycles » |
/// | 1996 | Pentium, IDE sur PCI, PIO mode 4 | 16,6 Mo/s | ATA-2, cycle de 120 ns ; Windows 95 OSR1 n'a pas de pilote DMA |
/// | 1999 | Pentium II, PIIX4E, Ultra DMA/33 | 32,6 / 21,9 Mo/s | Microsoft Research, *IDE Ultra/33 Performance: Intel PIIX4E*, 1999 : salves mesurées de l'IDE vers le PCI et en retour |
/// | 2003, 2007 | Ultra DMA/100 | 100 Mo/s | la norme ATA-5 ; aucune mesure de la période |
///
/// En 1999 le chipset est plus lent en écriture qu'en lecture : c'est mesuré, et
/// c'est le seul écart de ce genre qu'une source donne.
struct HostBus: Sendable, Equatable {
    let readMBs: Double
    let writeMBs: Double

    /// Le bus d'une machine de l'année donnée, pour un disque série ou non.
    ///
    /// Un disque SATA impose un contrôleur SATA, quelle que soit l'année du
    /// scénario : 150 Mo/s jusqu'en 2005 (SATA 1,5 Gb/s, l'ICH5 d'Intel en
    /// 2003), 300 Mo/s ensuite (SATA 3 Gb/s, l'ICH8 en 2006), 600 à partir de
    /// 2011 (SATA 6 Gb/s, les chipsets de la série 6). Débits de la norme,
    /// codage 8b/10b déduit ; aucune mesure de la période.
    static func era(year: Int, serial: Bool) -> HostBus {
        guard serial else { return era(year: year) }
        switch year {
        case ..<2006:     return HostBus(readMBs: 150, writeMBs: 150)
        case ..<2011:     return HostBus(readMBs: 300, writeMBs: 300)
        default:          return HostBus(readMBs: 600, writeMBs: 600)
        }
    }

    static func era(year: Int) -> HostBus {
        switch year {
        case ..<1995:     HostBus(readMBs: 5.0, writeMBs: 5.0)
        case ..<1998:     HostBus(readMBs: 16.6, writeMBs: 16.6)
        case ..<2001:     HostBus(readMBs: 32.6, writeMBs: 21.9)
        default:          HostBus(readMBs: 100, writeMBs: 100)
        }
    }
}

// MARK: - Le contenu du tampon

/// Une plage de secteurs que le tampon tient, lue ou écrite.
struct BufferedRange: Sendable, Equatable {
    var start: Int
    var end: Int
    var count: Int { end - start }

    func contains(_ lba: Int) -> Bool { lba >= start && lba < end }
    func overlaps(_ start: Int, _ end: Int) -> Bool { start < self.end && end > self.start }
}

/// Une écriture acquittée, pas encore posée sur le plateau.
struct PendingWrite: Sendable, Equatable {
    var start: Int
    var end: Int
    /// Instant où ses données sont entièrement dans le tampon : un vidage
    /// commencé avant ne peut pas la prendre.
    var acceptedAt: Double
}

/// Une lecture anticipée en cours : la tête continue de lire derrière la
/// dernière requête, sans que personne le lui demande.
struct ReadStream: Sendable, Equatable {
    /// Premier secteur de l'entrée de cache : la requête qui l'a lancée.
    var origin: Int
    /// Prochain secteur que la tête va lire.
    var next: Int
    /// Instant où la tête peut entreprendre le secteur `next` — le lire s'il
    /// est sur la même piste, franchir la piste sinon.
    var time: Double
    /// Instant à partir duquel tout ce qui précède `next` est dans le tampon.
    var ready: Double
    /// Fin de la dernière action engagée : ce qu'un seek devrait attendre.
    var busyUntil: Double
    /// Secteur où la lecture anticipée s'arrête, exclu.
    var stop: Int
}
