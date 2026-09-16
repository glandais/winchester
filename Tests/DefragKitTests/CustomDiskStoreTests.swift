import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Les disques construits survivent à l'app.
@Suite("Mes disques")
struct CustomDiskStoreTests {

    private static func store() -> CustomDiskStore {
        CustomDiskStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("disknoise-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("disques.json"))
    }

    @Test("Un fichier absent, c'est aucun disque")
    func missingFileIsEmpty() throws {
        #expect(try Self.store().load().isEmpty)
    }

    @Test("Ce qui est enregistré se relit à l'identique")
    func roundTrip() throws {
        let store = Self.store()
        var first = try ScenarioLibrary.load("famille-1999")
        first.id = CustomDiskStore.newIdentifier()
        first.displayName = "Le disque de ma mère, 1999"
        first.uninstalls = [.init(app: "winamp", date: CivilDate(year: 2000, month: 5, day: 1))]
        var second = try ScenarioLibrary.load("dev-2003")
        second.id = CustomDiskStore.newIdentifier()

        try store.save([first, second])
        let loaded = try store.load()
        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(try loaded[0].encoded() == first.encoded())
        #expect(try loaded[1].encoded() == second.encoded())
    }

    @Test("Un identifiant construit se reconnaît et ne se répète pas")
    func identifiers() {
        let a = CustomDiskStore.newIdentifier()
        let b = CustomDiskStore.newIdentifier()
        #expect(a != b)
        #expect(CustomDiskStore.isCustom(a))
        #expect(!CustomDiskStore.isCustom("secretaire-1996"))
    }

    @Test("Un fichier illisible lève au lieu de rendre une liste vide")
    func unreadableFileThrows() throws {
        let store = Self.store()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
