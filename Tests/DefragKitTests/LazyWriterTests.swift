import Testing
@testable import DefragKit

/// Le *lazy writer* de XP SP1 (`lazyrite.c`), tel que `LazyWriter` le joue.
@Suite("Le lazy writer de XP")
struct LazyWriterTests {

    @Test("Sorti du repos, le premier passage attend 3 s, puis un par seconde")
    func firstDelayThenEverySecond() {
        var lazy = LazyWriter()
        lazy.dirty(.mft, rank: 0, lba: 0, at: 10)
        // `CcFirstDelay` : rien avant 13 s.
        #expect(lazy.due(at: 12.9).isEmpty)
        #expect(lazy.due(at: 13).count == 1)
        #expect(lazy.isClean)
        // Une page salie pendant qu'il est actif part au passage suivant (14 s).
        lazy.dirty(.mft, rank: 8, lba: 8, at: 13.5)
        #expect(lazy.due(at: 14).count == 1)
        // Un passage sans rien à écrire le rend au repos : la suivante attend
        // de nouveau 3 s.
        #expect(lazy.due(at: 15).isEmpty)
        #expect(!lazy.active)
        lazy.dirty(.mft, rank: 16, lba: 16, at: 20)
        #expect(lazy.due(at: 22).isEmpty)
        #expect(lazy.due(at: 23).count == 1)
    }

    @Test("Un huitième des pages sales, flux par flux, le dernier flux entier")
    func eighthByStreams() {
        var lazy = LazyWriter()
        // 64 pages de MFT, puis 16 de bitmap : 80 pages, budget 10.
        for page in 0..<64 { lazy.dirty(.mft, rank: page, lba: 1_000 + page * 8, at: 0) }
        for page in 0..<16 { lazy.dirty(.bitmap, rank: page, lba: 9_000 + page * 8, at: 0) }
        let scans = lazy.due(at: 3)
        #expect(scans.count == 1)
        // La MFT épuise le budget : elle part entière, `$Bitmap` attend.
        let written = scans[0].streams.flatMap { $0 }
        #expect(written.allSatisfy { $0.stream == .mft })
        #expect(written.reduce(0) { $0 + $1.sectors } == 64 * 8)
        // Par plages de 64 Ko au plus.
        #expect(written.allSatisfy { $0.sectors <= 128 })
        #expect(lazy.dirtyPages == 16)
        // Le passage suivant écrit le reste.
        #expect(lazy.due(at: 4).flatMap(\.streams).flatMap { $0 }.allSatisfy { $0.stream == .bitmap })
        #expect(lazy.isClean)
    }

    @Test("Un flux de données n'écrit que ce qui reste du budget, et reprend où il s'est arrêté")
    func dataStreamsResume() {
        var lazy = LazyWriter()
        for page in 0..<80 { lazy.dirty(.data(7), rank: page, lba: page * 8, at: 0) }
        let first = lazy.due(at: 3).flatMap(\.streams).flatMap { $0 }
        #expect(first.reduce(0) { $0 + $1.sectors } == 10 * 8)
        #expect(first.first?.lba == 0)
        let second = lazy.due(at: 4).flatMap(\.streams).flatMap { $0 }
        #expect(second.first?.lba == 10 * 8)
    }
}
