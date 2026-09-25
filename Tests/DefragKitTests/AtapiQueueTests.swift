import Testing
@testable import DefragKit

/// La file d'`atapi` de XP SP1 : un ascenseur à sens unique, joué comme son
/// code le joue (`KeRemoveByKeyDeviceQueue` depuis `CurrentKey`,
/// `internal.c:3877-3878, 3959-3965`).
@Suite("La file d'atapi")
struct AtapiQueueTests {

    @Test("Une rafale : la première part aussitôt, les autres par LBA croissante depuis la clé")
    func burstIsCLook() {
        var queue = AtapiQueue(currentKey: 500)
        let order = queue.serve(burst: [700, 100, 900, 300, 600], key: { $0 })
        // 700 part disque au repos, sans toucher la clé ; puis ≥ 500 : 600,
        // 900 ; repli sur la plus basse : 100, 300.
        #expect(order == [700, 600, 900, 100, 300])
        #expect(queue.currentKey == 301)
    }

    @Test("La clé n'avance qu'au retrait : la requête partie disque au repos ne la touche pas")
    func immediateStartKeepsKey() {
        var queue = AtapiQueue()
        #expect(queue.serve(burst: [42], key: { $0 }) == [42])
        #expect(queue.currentKey == 0)
    }

    @Test("Deux requêtes au même secteur : la seconde attend le tour suivant")
    func sameKeyWaitsForTheNextSweep() {
        var queue = AtapiQueue()
        // Après 10, la clé vaut 11 : l'autre 10 passe derrière 20.
        let order = queue.serve(burst: [(0, 5), (1, 10), (2, 10), (3, 20)], key: { $0.1 })
        #expect(order.map(\.0) == [0, 1, 3, 2])
    }

    @Test("Des fils synchrones : chacun émet sa suivante après que la file a choisi")
    func synchronousStreams() {
        var queue = AtapiQueue()
        // Deux fils : A = 100, 101 ; B = 50, 51. A part aussitôt ; à sa fin
        // la file n'a que B:50 (A:101 n'est pas encore émise), puis A:101
        // entre. À la fin de B:50, la file n'a que A:101 (B:51 n'est pas
        // encore émise) : les deux fils alternent, chacun dans son ordre.
        let order = queue.serve(streams: [[100, 101], [50, 51]], workers: 2, key: { $0 })
        #expect(order == [100, 50, 101, 51])
    }

    @Test("Un seul fil vide ses suites l'une après l'autre, dans leur ordre")
    func oneWorkerIsSequential() {
        var queue = AtapiQueue()
        let order = queue.serve(streams: [[30, 10], [20]], workers: 1, key: { $0 })
        #expect(order == [30, 10, 20])
    }
}
