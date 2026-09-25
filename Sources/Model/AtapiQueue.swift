import Foundation
import DiskCore

/// La file de commandes du pilote de port IDE de Windows XP (`atapi`), telle
/// que son code la sert.
///
/// Le disque n'a pas de file à lui : `atapi` déclare `TaggedQueuing = FALSE`
/// (`atapi/init.c:207`) et `CommandQueueing = FALSE` (`chanfdo.c:1741`), une
/// commande à la fois par unité, et XP SP1 n'a pas de pilote AHCI. Mais les
/// requêtes qui arrivent pendant qu'une commande est en cours attendent dans
/// une file **triée**, et non dans l'ordre d'arrivée : `classpnp` pose la LBA
/// comme clé (`Srb.QueueSortKey = logicalBlockAddr`, `classpnp/xferpkt.c:399-406`,
/// « sort the SRBs by the logical block address so that disk seeks are
/// minimized »), `atapi` insère par clé (`KeInsertByKeyDeviceQueue`,
/// `devpdo.c:2051`) et, à chaque fin de commande, retire la première requête
/// de clé au moins égale à `CurrentKey`, sinon la première de la file
/// (`KeRemoveByKeyDeviceQueue`, `internal.c:3877-3878` ; `ke/devquobj.c:320-333`).
/// `CurrentKey` devient alors la clé retirée, **plus un** — contre la
/// famine de requêtes qui visent le même secteur (`internal.c:3959-3965`).
/// C'est un ascenseur à sens unique : C-LOOK.
///
/// Deux détails de ce code décident de l'ordre, et le modèle les suit :
///
/// - une requête qui arrive **disque au repos** part aussitôt : l'insertion
///   rend `FALSE`, la file n'était pas occupée, et `CurrentKey` n'est pas
///   touchée — elle ne l'est qu'au retrait (`devpdo.c:2051-2056`) ;
/// - `CurrentKey` est remise à zéro à la mise sous tension du disque
///   (`pdopower.c:322`).
///
/// Le simulateur sert les requêtes une à une, dans l'ordre du plan
/// (`DiskMechanics`) : la file est donc jouée ici, par le planificateur, sur
/// ce qu'il sait **émis ensemble** — un lot du préchargeur, les fils du *lazy
/// writer*. Une requête du premier plan qui arriverait pendant qu'un lot
/// attend passe, dans le modèle, après lui : la file la trierait avec les
/// autres. C'est la limite de la traduction.
///
/// Vista et 7 ont un autre pilote (et l'AHCI, le NCQ) que ce code ne décrit
/// pas : ils gardent la file dans l'ordre du plan.
struct AtapiQueue: Sendable {

    /// `LogicalUnit->CurrentKey`.
    private(set) var currentKey = 0

    init(currentKey: Int = 0) {
        self.currentKey = currentKey
    }

    /// Une rafale : des requêtes émises ensemble, disque au repos, et dont
    /// aucune n'attend l'autre pour partir — `MmPrefetchPages` émet toutes
    /// ses lectures avant d'en attendre une (`pfsup.c:318-338, 370-388`),
    /// `classpnp` soumet tous les morceaux d'une requête d'un coup
    /// (`class.c:2274-2328`).
    ///
    /// La première émise part aussitôt ; les autres sont servies dans l'ordre
    /// de l'ascenseur. Rend l'ordre de service.
    mutating func serve<T>(burst: [T], key: (T) -> Int) -> [T] {
        guard burst.count > 1 else { return burst }
        var waiting = SortedByKey()
        for index in 1..<burst.count { waiting.insert(key: key(burst[index]), item: index) }
        var order = [0]
        order.reserveCapacity(burst.count)
        while let index = waiting.remove(from: currentKey) {
            currentKey = key(burst[index]) + 1
            order.append(index)
        }
        return order.map { burst[$0] }
    }

    /// Des fils qui écrivent chacun une suite de requêtes **synchrones** —
    /// une à la fois, la suivante émise quand la précédente est finie —,
    /// `workers` à la fois : les fils de travail du *lazy writer*, dont
    /// chacun vide un flux dans l'ordre de ses offsets
    /// (`cachesub.c:3211, 3479-3481` ; `lazyrite.c:728-742`).
    ///
    /// Au départ, les fils prennent les premières suites dans l'ordre et
    /// émettent chacun leur première requête : la première part aussitôt, les
    /// autres attendent. À chaque fin de commande, la file retire parmi ce qui
    /// attend ; le fil dont la commande vient de finir émet sa suivante
    /// **après** ce retrait — il est réveillé par la fin de sa requête, bien
    /// après que le pilote a lancé la suivante. Un fil qui a fini sa suite
    /// prend la suivante non commencée.
    mutating func serve<T>(streams: [[T]], workers: Int, key: (T) -> Int) -> [T] {
        let streams = streams.filter { !$0.isEmpty }
        guard !streams.isEmpty else { return [] }
        var waiting = SortedByKey()
        var nextStream = 0
        var order: [T] = []
        order.reserveCapacity(streams.reduce(0) { $0 + $1.count })

        // Une requête en attente est désignée par sa suite et son rang.
        typealias Slot = (stream: Int, rank: Int)
        var tickets: [Slot] = []
        func enqueue(_ slot: Slot) {
            tickets.append(slot)
            waiting.insert(key: key(streams[slot.stream][slot.rank]), item: tickets.count - 1)
        }

        // Le premier fil part aussitôt ; les autres attendent.
        var serving: Slot? = nil
        while nextStream < min(max(workers, 1), streams.count) {
            let slot = (stream: nextStream, rank: 0)
            if serving == nil { serving = slot } else { enqueue(slot) }
            nextStream += 1
        }

        while let current = serving {
            order.append(streams[current.stream][current.rank])
            // La fin de commande : le pilote retire la suivante...
            serving = nil
            if let next = waiting.remove(from: currentKey) {
                let chosen = tickets[next]
                currentKey = key(streams[chosen.stream][chosen.rank]) + 1
                serving = chosen
            }
            // ... puis le fil réveillé émet sa requête suivante, ou prend une
            // autre suite.
            var slot = (stream: current.stream, rank: current.rank + 1)
            if slot.rank >= streams[slot.stream].count {
                guard nextStream < streams.count else { continue }
                slot = (stream: nextStream, rank: 0)
                nextStream += 1
            }
            if serving == nil { serving = slot } else { enqueue(slot) }
        }
        return order
    }

    /// Les requêtes en attente, par clé croissante ; à clé égale, dans
    /// l'ordre d'arrivée (`KeInsertByKeyDeviceQueue` insère derrière les clés
    /// inférieures ou égales).
    private struct SortedByKey {
        private var keys: [Int] = []
        private var items: [Int] = []

        mutating func insert(key: Int, item: Int) {
            var low = 0
            var high = keys.count
            while low < high {
                let mid = (low + high) / 2
                if keys[mid] <= key { low = mid + 1 } else { high = mid }
            }
            keys.insert(key, at: low)
            items.insert(item, at: low)
        }

        /// La première de clé au moins égale à `from`, sinon la première de
        /// la file ; `nil` si la file est vide.
        mutating func remove(from: Int) -> Int? {
            guard !keys.isEmpty else { return nil }
            var low = 0
            var high = keys.count
            while low < high {
                let mid = (low + high) / 2
                if keys[mid] < from { low = mid + 1 } else { high = mid }
            }
            let index = low < keys.count ? low : 0
            keys.remove(at: index)
            return items.remove(at: index)
        }
    }
}
