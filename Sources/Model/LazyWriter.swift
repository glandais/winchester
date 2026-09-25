import Foundation
import DiskCore

/// Le *lazy writer* du gestionnaire de cache de Windows XP, tel que son code
/// le joue (`base/ntos/cache/lazyrite.c`, `cachesub.c`), rejoué par un
/// planificateur qui n'a qu'une horloge estimée.
///
/// - **Le réveil** : une fois par seconde tant qu'il reste des pages sales
///   (`LAZY_WRITER_IDLE_DELAY`, `cc.h:380`) ; un passage qui n'en trouve
///   aucune le rend au repos, et la première page salie ensuite ne sera
///   écrite qu'au bout de **3 s** — « to let the app finish saving its
///   file » (`CcFirstDelay`, `cachedat.c:65` ; `lazyrite.c:85-99`).
/// - **Ce qu'un passage écrit** : environ **un huitième** des pages sales
///   du système (`LAZY_WRITER_MAX_AGE_TARGET`, `cc.h:387` ;
///   `lazyrite.c:325-327`), plus le rattrapage qui ramène le total vers
///   `CcDirtyPageTarget` s'il allait le dépasser (`lazyrite.c:329-363`). Ce
///   budget se dépense **flux par flux**, dans l'ordre de la liste des flux
///   sales, à partir du curseur : un flux de métadonnées épinglées — la MFT,
///   `$Bitmap`, un index — s'écrit **en entier** ; le flux qui épuise le
///   budget est écrit lui aussi, et les suivants attendent le passage
///   suivant, qui reprendra sur lui (`lazyrite.c:436-506`). Un flux de
///   données n'écrit que ce qui reste du budget (`CcPagesYetToWrite`,
///   `cachesub.c:3994-3998`), là où il s'était arrêté (`ResumeWritePage`,
///   `cachesub.c:3002-3007, 3296-3320`).
/// - **Comment** : chaque flux est confié à un fil de travail, qui l'écrit
///   dans l'ordre de ses offsets par plages de 64 Ko au plus
///   (`MAX_WRITE_BEHIND`, `cachesub.c:3211, 3479-3481`), une écriture à la
///   fois ; trois fils à la fois sur un poste de travail de plus de 32 Mo
///   (`CcNumberWorkerThreads` = `ExCriticalWorkerThreads` − 2, `fssup.c:145-168` ;
///   cinq fils critiques, `ex/worker.c:312-340` ; `mm/mminit.c:1520-1530`).
///   Leurs requêtes se croisent dans la file d'`atapi` (`AtapiQueue`).
/// - **Le journal d'abord** : avant d'écrire une page de métadonnées, le
///   cache fait poser le journal jusqu'à son LSN (`FlushToLsnRoutine`,
///   `cachesub.c:3619-3622, 3696` ; `ntfs/fsctrl.c:1809, 1813`).
///
/// La mémoire de la machine n'est connue nulle part dans le modèle : le
/// seuil de rattrapage suppose un poste de plus de 220 Mo, dont le cache
/// peut tenir 24 Mo (`mm/mminit.c:1548-1554`) — seuil de pages sales de
/// 22 Mo, cible aux trois quarts (`fssup.c:172-178`). Une hypothèse, que
/// seules des installations de gros fichiers approchent.
struct LazyWriter: Sendable {

    /// Un flux du cache : ce que le *lazy writer* confie à un fil.
    enum Stream: Hashable, Sendable {
        case mft
        case bitmap
        case index(UInt32)
        case data(UInt32)
        case other(Int)

        var isMetadata: Bool {
            if case .data = self { return false }
            return true
        }
    }

    /// Une écriture : `order` range les pages d'un flux dans l'ordre de ses
    /// offsets — la LBA pour une métadonnée, le rang de la page dans le
    /// fichier pour des données.
    struct Write: Sendable {
        let lba: Int
        let sectors: Int
        let stream: Stream
    }

    static let firstDelay = 3.0
    static let idleDelay = 1.0
    static let maxAgeTarget = 8
    static let writeBehindSectors = 128
    static let workers = 3
    static let pageSectors = 8
    /// `CcDirtyPageTarget`, en pages : les trois quarts de 22 Mo.
    static let dirtyPageTarget = (24 - 2) * 1_048_576 / 4_096 * 3 / 4

    /// Les pages sales de chaque flux : rang dans le flux → LBA de la page.
    private var dirty: [Stream: [Int: Int]] = [:]
    /// `CcDirtySharedCacheMapList` : les flux sales, dans l'ordre où ils le
    /// sont devenus.
    private var order: [Stream] = []
    /// `CcLazyWriterCursor` : il est posé devant `order[cursor]`.
    private var cursor = 0
    private var passCount: [Stream: Int] = [:]
    /// Où chaque flux de données reprend (`ResumeWritePage`).
    private var resume: [Stream: Int] = [:]
    private(set) var active = false
    private(set) var nextScan = Double.infinity
    private var pagesWrittenLastTime = 0
    private var dirtyPagesLastScan = 0
    private(set) var pagesWritten = 0
    private(set) var scans = 0

    var isClean: Bool { dirty.isEmpty }
    var dirtyPages: Int { dirty.values.reduce(0) { $0 + $1.count } }

    /// Une page salie à l'instant `time` : la page `rank` du flux, qui est à
    /// `lba` sur le disque.
    mutating func dirty(_ stream: Stream, rank: Int, lba: Int, at time: Double) {
        if dirty[stream] == nil {
            dirty[stream] = [:]
            order.append(stream)
        }
        dirty[stream]?[rank] = lba
        if !active {
            active = true
            nextScan = time + Self.firstDelay
        }
    }

    /// Une métadonnée : les pages de 4 Ko que couvrent ces secteurs, rangées
    /// par leur LBA.
    mutating func dirtyMetadata(_ stream: Stream, lba: Int, sectors: Int, at time: Double) {
        let first = lba / Self.pageSectors
        let last = (lba + max(sectors, 1) - 1) / Self.pageSectors
        for page in first...last {
            dirty(stream, rank: page, lba: page * Self.pageSectors, at: time)
        }
    }

    /// Des pages rendues sans avoir été écrites : un fichier effacé, dont le
    /// cache est purgé.
    mutating func discard(_ stream: Stream) {
        guard dirty.removeValue(forKey: stream) != nil else { return }
        remove(stream)
    }

    /// Un passage : son heure, et les flux qu'il confie aux fils, dans
    /// l'ordre, avec leurs écritures.
    struct Scan: Sendable {
        let time: Double
        let streams: [[Write]]
    }

    /// Les passages échus à l'instant `time`.
    mutating func due(at time: Double) -> [Scan] {
        var result: [Scan] = []
        while active, nextScan <= time {
            let at = nextScan
            let streams = scan()
            if !streams.isEmpty { result.append(Scan(time: at, streams: streams)) }
        }
        return result
    }

    /// Tout ce qui est sale, flux par flux : un vidage explicite
    /// (`CcFlushCache` d'un volume, l'arrêt).
    mutating func flushAll() -> [[Write]] {
        var streams: [[Write]] = []
        for stream in order {
            let writes = runs(of: stream, pages: Int.max)
            if !writes.isEmpty { streams.append(writes) }
        }
        dirty.removeAll()
        order.removeAll()
        cursor = 0
        active = false
        nextScan = .infinity
        return streams
    }

    // MARK: - Un passage

    private mutating func scan() -> [[Write]] {
        scans += 1
        let total = dirtyPages
        guard total > 0 else {
            active = false
            nextScan = .infinity
            return []
        }
        nextScan += Self.idleDelay
        var pagesToWrite = total > Self.maxAgeTarget ? total / Self.maxAgeTarget : total
        let foreground = max(total + pagesWrittenLastTime - dirtyPagesLastScan, 0)
        let estimated = total - pagesToWrite + foreground
        if estimated > Self.dirtyPageTarget { pagesToWrite += estimated - Self.dirtyPageTarget }
        dirtyPagesLastScan = total
        pagesWrittenLastTime = pagesToWrite
        var yetToWrite = pagesToWrite

        var queued: [Stream] = []
        var remaining = pagesToWrite
        let count = order.count
        let start = cursor % max(count, 1)
        var newCursor: Stream?
        var cursorAfter = false
        for step in 0..<count where remaining > 0 {
            let stream = order[(start + step) % count]
            let pages = dirty[stream]?.count ?? 0
            guard pages > 0 else { continue }
            passCount[stream, default: 0] += 1
            queued.append(stream)
            if pages >= remaining {
                newCursor = stream
                cursorAfter = step == 0 && passCount[stream, default: 0] & 0xF == 0
                remaining = 0
            } else {
                remaining -= pages
            }
        }
        // Le curseur reprend sur le flux qui a épuisé le budget, ou sur le
        // suivant tous les seize passages s'il était le premier visité.
        if let newCursor, let index = order.firstIndex(of: newCursor) {
            cursor = cursorAfter ? index + 1 : index
        }

        var result: [[Write]] = []
        for stream in queued {
            let allowed = stream.isMetadata ? Int.max : yetToWrite
            guard allowed > 0 else { continue }
            let writes = runs(of: stream, pages: allowed)
            let pages = writes.reduce(0) { $0 + $1.sectors } / Self.pageSectors
            if !stream.isMetadata { yetToWrite = max(yetToWrite - pages, 0) }
            if !writes.isEmpty { result.append(writes) }
        }
        return result
    }

    /// Les écritures d'un flux, au plus `pages` pages, dans l'ordre de ses
    /// offsets — depuis son point de reprise pour des données —, par plages
    /// contiguës de 64 Ko au plus. Ce qui est écrit n'est plus sale.
    private mutating func runs(of stream: Stream, pages limit: Int) -> [Write] {
        guard var pages = dirty[stream], !pages.isEmpty else { return [] }
        var ranks = pages.keys.sorted()
        if !stream.isMetadata, let from = resume[stream],
           let split = ranks.firstIndex(where: { $0 >= from }) {
            ranks = Array(ranks[split...] + ranks[..<split])
        }
        var writes: [Write] = []
        var taken = 0
        var previous: (rank: Int, lba: Int)?
        for rank in ranks where taken < limit {
            guard let lba = pages[rank] else { continue }
            if let last = writes.last, let previous, rank == previous.rank + 1,
               lba == last.lba + last.sectors, last.sectors < Self.writeBehindSectors {
                writes[writes.count - 1] = Write(lba: last.lba, sectors: last.sectors + Self.pageSectors,
                                                 stream: stream)
            } else {
                writes.append(Write(lba: lba, sectors: Self.pageSectors, stream: stream))
            }
            previous = (rank, lba)
            pages.removeValue(forKey: rank)
            taken += 1
        }
        pagesWritten += taken
        if let previous { resume[stream] = previous.rank + 1 }
        if pages.isEmpty {
            dirty.removeValue(forKey: stream)
            remove(stream)
        } else {
            dirty[stream] = pages
        }
        return writes
    }

    private mutating func remove(_ stream: Stream) {
        guard let index = order.firstIndex(of: stream) else { return }
        order.remove(at: index)
        if index < cursor { cursor -= 1 }
        if cursor > order.count { cursor = order.count }
        passCount.removeValue(forKey: stream)
    }

    // MARK: - Au disque

    /// Les écritures d'un passage dans l'ordre où le disque les reçoit : le
    /// journal d'abord, par le fil qui écrit la première métadonnée ; puis
    /// les fils, trois à la fois, dans la file d'`atapi`.
    static func served(_ streams: [[Write]], log: [Write], queue: inout AtapiQueue) -> [Write] {
        var streams = streams
        if !log.isEmpty {
            if let first = streams.firstIndex(where: { $0.first?.stream.isMetadata ?? false }) {
                streams[first] = log + streams[first]
            } else {
                streams.insert(log, at: 0)
            }
        }
        return queue.serve(streams: streams, workers: workers, key: \.lba)
    }
}
