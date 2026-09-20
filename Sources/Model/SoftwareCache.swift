import Foundation
import DiskCore

/// Les caches du système, entre le programme qui lit et le disque.
///
/// Trois caches se superposent sur une machine d'époque — celui du disque,
/// celui du pilote, celui du système — et c'est le premier qui décide de ce que
/// les deux autres voient. Le premier est dans `DiskMechanics`. Ceux-ci sont
/// ceux du démarrage : ils ne dépendent que de la suite des lectures, pas du
/// temps, et se décident donc au moment où le démarrage est planifié.

// MARK: - Une file au plus anciennement servi

/// Des pages, dont la moins récemment servie cède la place.
///
/// Deux sortes d'entrées : des pages **nommées**, qu'on relira peut-être — une
/// page de table FAT, un élément de `SMARTDRV` —, et du **volume anonyme**, les
/// données des fichiers, qu'un démarrage ne relit jamais mais qui occupent la
/// même mémoire et poussent les autres dehors.
struct PageLRU {

    /// Pages que le cache tient. `Int.max` : il ne cède jamais.
    let capacity: Int

    private struct Entry {
        var key: Int?
        var stamp: Int
        var count: Int
    }

    private var queue: [Entry] = []
    private var head = 0
    private var stampOf: [Int: Int] = [:]
    private var used = 0
    private var clock = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// La page est-elle dans le cache ?
    func contains(_ key: Int) -> Bool { stampOf[key] != nil }

    /// Sert la page : elle devient la plus récente. Rend `true` si elle y était.
    @discardableResult
    mutating func touch(_ key: Int) -> Bool {
        clock += 1
        let present = stampOf[key] != nil
        stampOf[key] = clock
        queue.append(Entry(key: key, stamp: clock, count: 1))
        if !present {
            used += 1
            evict()
        }
        return present
    }

    /// Des pages qu'on ne relira pas, et qui prennent leur place.
    mutating func fill(anonymous pages: Int) {
        guard pages > 0, capacity != .max else { return }
        clock += 1
        queue.append(Entry(key: nil, stamp: clock, count: pages))
        used += pages
        evict()
    }

    private mutating func evict() {
        while used > capacity, head < queue.count {
            let entry = queue[head]
            if let key = entry.key {
                if stampOf[key] == entry.stamp {
                    stampOf[key] = nil
                    used -= 1
                }
                head += 1
            } else {
                let excess = used - capacity
                if entry.count > excess {
                    queue[head].count -= excess
                    used -= excess
                } else {
                    used -= entry.count
                    head += 1
                }
            }
        }
        if head > 1_024 && head * 2 > queue.count {
            queue.removeFirst(head)
            head = 0
        }
    }
}

// MARK: - SMARTDRV

/// `SMARTDRV`, le cache de MS-DOS 6.22, que le démarrage de 1993 charge dans
/// `AUTOEXEC.BAT`.
///
/// Tout vient de l'aide de MS-DOS 6.22 (`HELP SMARTDRV`) :
///
/// - il lit et garde le disque par **éléments** de 8 192 octets
///   (« /E:ElementSize […] The default value is 8192 ») ;
/// - après chaque lecture qui va au disque, il lit **16 Ko d'avance**
///   (« /B:BufferSize […] The default size of the read-ahead buffer is 16K ») ;
/// - sa taille dépend de la mémoire étendue, et **rétrécit quand Windows
///   démarre** : jusqu'à 4 Mo de mémoire étendue, 1 Mo sous MS-DOS et 512 Ko
///   sous Windows (`InitCacheSize`, `WinCacheSize`) ;
/// - il met en cache les écritures des disques durs, et les écrit « after each
///   command completes ». Le modèle les laisse partir aussitôt : un démarrage
///   n'enchaîne pas assez de commandes pour que le délai s'entende.
///
/// **La mémoire de la machine est une hypothèse** : 4 Mo, dont 3 de mémoire
/// étendue, la configuration courante d'un 486 sous Windows 3.1 en 1993. Aucun
/// profil ne dit la sienne.
struct SmartDrive {

    static let elementSectors = 8_192 / DriveGeometry.bytesPerSector
    static let readAheadSectors = 16_384 / DriveGeometry.bytesPerSector
    /// 1 Mo sous MS-DOS, 512 Ko sous Windows, en éléments.
    static let dosElements = 1_048_576 / 8_192
    static let windowsElements = 524_288 / 8_192

    /// Premier acte où il est chargé, premier acte sous Windows.
    let loadedFromAct: Int
    let windowsFromAct: Int

    private var dos = PageLRU(capacity: SmartDrive.dosElements)
    private var windows = PageLRU(capacity: SmartDrive.windowsElements)
    private var underWindows = false

    /// Éléments servis sans aller au disque, et éléments lus.
    private(set) var hits = 0
    private(set) var misses = 0

    init(loadedFromAct: Int, windowsFromAct: Int) {
        self.loadedFromAct = loadedFromAct
        self.windowsFromAct = windowsFromAct
    }

    func isActive(inAct act: Int) -> Bool { act >= loadedFromAct }

    /// Ce qu'une lecture demande vraiment au disque : les éléments qu'il n'a
    /// pas, plus sa lecture anticipée, en plages contiguës.
    mutating func read(lba: Int, sectors: Int, act: Int) -> [(lba: Int, sectors: Int)] {
        // Une lecture vide ne demande rien au disque — et `first...last`
        // serait une plage à l'envers.
        guard sectors > 0 else { return [] }
        if act >= windowsFromAct && !underWindows {
            // Windows démarre : le cache rétrécit à sa taille Windows, en
            // gardant ce qu'il servait le plus récemment.
            underWindows = true
            windows = dos.shrunk(to: SmartDrive.windowsElements)
        }
        let element = Self.elementSectors
        let first = lba / element
        let last = (lba + sectors - 1) / element
        var missing: [Int] = []
        for index in first...last {
            if cache.touch(index) { hits += 1 } else { missing.append(index) }
        }
        guard let lastMissing = missing.last else { return [] }
        // La lecture anticipée suit ce qui est allé au disque.
        for index in (lastMissing + 1)...(lastMissing + Self.readAheadSectors / element)
        where !cache.contains(index) {
            cache.touch(index)
            missing.append(index)
        }
        misses += missing.count
        var runs: [(lba: Int, sectors: Int)] = []
        for index in missing {
            if let previous = runs.last, previous.lba + previous.sectors == index * element {
                runs[runs.count - 1].sectors += element
            } else {
                runs.append((index * element, element))
            }
        }
        return runs
    }

    private var cache: PageLRU {
        get { underWindows ? windows : dos }
        set { if underWindows { windows = newValue } else { dos = newValue } }
    }
}

private extension PageLRU {
    /// Le même cache, ramené à une taille plus petite : on ne sait pas ce que
    /// `SMARTDRV` garde en rétrécissant ; le modèle ne garde rien. C'est le cas
    /// le plus défavorable, et il ne coûte que les éléments relus sous Windows.
    func shrunk(to capacity: Int) -> PageLRU { PageLRU(capacity: capacity) }
}

// MARK: - VCACHE

/// VCACHE, le cache de Windows 95 et 98, vu du suivi de chaîne FAT32.
///
/// Le pilote lit la table par pages de 4 Ko au fil des chaînes qu'il suit
/// (chantier 22) ; ces pages vivent dans VCACHE avec les données des fichiers,
/// et en sortent quand les données les poussent. Un Windows 98 qui lit cent
/// mégaoctets au démarrage revient donc **périodiquement** à la table pour des
/// pages qu'il avait lues au début.
///
/// **Sa taille est une hypothèse.** VCACHE est dynamique : Microsoft dit
/// seulement qu'il se dimensionne sur la mémoire présente au démarrage. Le seul
/// chiffre d'époque est la règle de réglage — « un quart de la mémoire, 16 Mo au
/// plus » pour `MaxFileCache` —, et c'est elle que prend le modèle, sur une
/// machine de 64 Mo en 1999 et de 16 Mo en 1996. Sa sensibilité est mesurée
/// (`LEDGER.md`, chantier 26).
enum VCache {

    static let pageBytes = 4_096

    /// Mémoire de la machine, en mégaoctets, par système.
    static func machineMB(os: String) -> Int? {
        switch os {
        case "win95-osr1": 16
        case "win98se":    64
        default:           nil
        }
    }

    /// Pages que VCACHE tient, ou `nil` si ce système n'a pas de VCACHE.
    static func pages(os: String) -> Int? {
        guard let megabytes = machineMB(os: os) else { return nil }
        let bytes = min(megabytes * 1_048_576 / 4, 16 * 1_048_576)
        return bytes / pageBytes
    }
}
