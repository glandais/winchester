import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce qu'un disque garde de ce qu'on lui a fait, d'un lancement à l'autre.
///
/// `UX_REVIEW.md` §2.2 : tout s'évaporait à la fermeture, et au lancement
/// suivant les cartes ne disaient plus rien. Ce qui survit désormais est un
/// résumé de deux cents octets par passe — pas le disque, pas les cartes.
@Suite("Ce qu'un disque garde")
struct PassHistoryTests {

    // MARK: - Fabrique

    private func store() -> PassHistoryStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("winchester-tests-\(UUID().uuidString)", isDirectory: true)
        return PassHistoryStore(url: dir.appendingPathComponent("passes.json"))
    }

    private func stats(fragmented: Int, fragments: Int, holes: Int) -> VolumeStats {
        VolumeStats(fill: 0.7, fragmentedFiles: fragmented, fragments: fragments,
                    fileCount: 4_027, extentsPerFile: 1.17, freeHoles: holes)
    }

    /// Une défragmentation entendue jusqu'au bout, comme la passe de l'audit :
    /// « Développeur, 1993 » rangé de 321 à 2 fichiers fragmentés.
    private func tidyingRecord(disk: String = "dev-1993", tool: String = "UltraDefrag") -> PassRecord {
        var record = PassRecord(passNumber: 1, diskID: disk, title: "Développeur, 1993",
                                kind: .defrag, toolLabel: tool, toolID: "ultraDefrag",
                                rangedBy: nil, duration: 151, requests: 9_000, seeks: 6_000,
                                averageSeek: 298, movedBytes: 49_000_000)
        record.before = stats(fragmented: 321, fragments: 1_200, holes: 62)
        record.after = stats(fragmented: 2, fragments: 35, holes: 461)
        record.filesMoved = 319
        record.evacuations = 0
        record.summary = "Rien n'a été évacué : c'est le principe de l'outil."
        return record
    }

    // MARK: - Le résumé

    @Test("Le résumé tient ce que le bilan disait, sans le disque")
    func digestKeepsTheNumbers() {
        let record = tidyingRecord()
        let digest = PassHistory.digest(of: record)

        #expect(digest.id == record.id)
        #expect(digest.diskID == "dev-1993")
        #expect(digest.kind == .defrag)
        #expect(digest.toolLabel == "UltraDefrag")
        #expect(digest.fragmentedBefore == 321)
        #expect(digest.fragmentedAfter == 2)
        #expect(digest.holesAfter == 461)
        #expect(digest.movedBytes == 49_000_000)
        #expect(digest.isTidying)
    }

    @Test("Un outil qui n'a rien recollé n'a rien rangé")
    func aPassThatChangedNothingDoesNotTidy() {
        // Windows XP sur un volume sans trou à la bonne taille : la passe a
        // bien eu lieu, elle n'a rien réparé. Annoncer « rangé par » sur cette
        // base ferait mentir la carte du disque.
        var record = tidyingRecord(tool: "Défragmenteur Windows XP")
        record.after = stats(fragmented: 321, fragments: 1_200, holes: 62)
        #expect(!PassHistory.digest(of: record).isTidying)

        // Pas plus qu'un démarrage, qui ne range rien par construction.
        var boot = tidyingRecord()
        boot.before = nil
        boot.after = nil
        #expect(!PassHistory.digest(of: boot).isTidying)
    }

    // MARK: - Le fichier

    @Test("Ce qui est écrit se relit à l'identique")
    func roundTripsThroughTheFile() throws {
        let store = store()
        let digest = PassHistory.digest(of: tidyingRecord(), at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save([digest])

        let read = try store.load()
        #expect(read.count == 1)
        #expect(read.first == digest)
        // La date passe par ISO 8601 : à la seconde près, et pas à la
        // milliseconde flottante d'un `timeIntervalSinceReferenceDate`.
        #expect(read.first?.finishedAt == digest.finishedAt)
    }

    @Test("Un fichier absent n'est pas une erreur")
    func missingFileIsEmpty() throws {
        #expect(try store().load().isEmpty)
    }

    @Test("Un fichier illisible ne fait pas tomber le lancement")
    @MainActor
    func unreadableFileDoesNotThrowOnLaunch() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("ceci n'est pas du JSON".utf8).write(to: store.url)

        // Perdre l'historique d'écoute n'est pas perdre le travail de
        // quelqu'un : on repart de rien, en le disant, plutôt que de refuser
        // de démarrer.
        let history = PassHistory(store: store)
        #expect(history.digests.isEmpty)
        #expect(history.failure != nil)
    }

    // MARK: - L'état d'un disque

    @Test("L'état d'un disque est sa dernière passe, et son dernier rangement")
    @MainActor
    func stateIsTheLastPassAndTheLastTidying() {
        let history = PassHistory(store: store())
        let now = Date()

        var tidying = PassHistory.digest(of: tidyingRecord(), at: now.addingTimeInterval(-3_600))
        tidying.summary = "rangé"
        history.append(tidying)

        // Une journée d'usage passe après : elle est la dernière, mais ce n'est
        // pas elle qui a rangé le disque.
        let day = PassDigest(id: UUID(), diskID: "dev-1993", title: "Développeur, 1993",
                             kind: .day, toolLabel: "Jour 13", toolID: nil,
                             finishedAt: now, duration: 40, movedBytes: 1_000)
        history.append(day)

        let state = history.state(of: "dev-1993")
        #expect(state.passes.count == 2)
        #expect(state.last?.kind == .day)
        #expect(state.tidied?.toolLabel == "UltraDefrag")
        // Un disque jamais écouté ne dit rien.
        #expect(history.state(of: "famille-1999").isEmpty)
    }

    @Test("Ce qui est gardé survit à un relancement")
    @MainActor
    func survivesRelaunch() throws {
        let store = store()
        let first = PassHistory(store: store)
        first.record(try withDisk(tidyingRecord()))
        #expect(first.digests.count == 1)

        // Le même fichier, relu par une instance neuve : c'est très exactement
        // ce que fait le lancement suivant de l'application.
        let second = PassHistory(store: store)
        #expect(second.digests.count == 1)
        #expect(second.state(of: "dev-1993").tidied?.toolLabel == "UltraDefrag")
        #expect(second.failure == nil)

        second.forgetAll()
        #expect(PassHistory(store: store).digests.isEmpty)
    }

    @Test("Une passe sans disque de la galerie n'a pas d'état à porter")
    @MainActor
    func passWithoutDiskIsNotKept() {
        let history = PassHistory(store: store())
        history.record(tidyingRecord())
        #expect(history.digests.isEmpty)
    }

    // MARK: - L'élagage

    @Test("L'élagage garde la dernière passe de chaque disque")
    func trimmingKeepsEachDiskLastPass() {
        let now = Date()
        // Un disque écouté une seule fois, il y a longtemps : c'est la passe
        // qui porte son état, et elle ne doit pas tomber sous le nombre de
        // passes d'un disque qu'on écoute tous les jours.
        let old = PassHistory.digest(of: tidyingRecord(disk: "rare-1996"),
                                     at: now.addingTimeInterval(-90 * 86_400))
        var digests = [old]
        for i in 0..<(PassHistoryStore.limit + 40) {
            digests.append(PassHistory.digest(of: tidyingRecord(disk: "dev-1993"),
                                              at: now.addingTimeInterval(-Double(i))))
        }

        let kept = PassHistoryStore.trimmed(digests)
        #expect(kept.count == PassHistoryStore.limit)
        #expect(kept.contains { $0.diskID == "rare-1996" })
        // Et l'ordre reste celui du plus récent au plus ancien.
        #expect(kept == kept.sorted { $0.finishedAt > $1.finishedAt })
    }

    /// Un bilan venu de la galerie : seul celui-là porte un état de disque.
    ///
    /// Le plus petit volume du catalogue, généré en une fraction de seconde
    /// même en debug — `swift test` doit rester une poignée de secondes.
    private func withDisk(_ record: PassRecord) throws -> PassRecord {
        var copy = record
        let spec = try #require(try ScenarioLibrary.loadAll().first { $0.id == "dev-1993" })
        copy.disk = try DiskGenerator.generate(spec)
        return copy
    }
}
