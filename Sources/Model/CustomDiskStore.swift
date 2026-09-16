import Foundation
import DiskCore

/// Les disques construits dans l'app, gardés d'une session à l'autre.
///
/// Un disque construit, c'est son **histoire** — un `ProfileSpec` —, jamais le
/// volume fabriqué : celui-ci se refait à l'identique depuis la graine, en une
/// seconde ou deux, et pèserait des mégaoctets. Les bilans de passe ne sont pas
/// gardés non plus : ils tiennent le disque entier, et se refont en réécoutant.
///
/// Un seul fichier JSON, réécrit en entier à chaque changement : quelques
/// dizaines de profils de quelques kilo-octets.
struct CustomDiskStore {

    let url: URL

    /// Le fichier de l'app, dans Application Support.
    static func standard() -> CustomDiskStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return CustomDiskStore(url: base.appendingPathComponent("DiskNoise", isDirectory: true)
                                        .appendingPathComponent("disques.json"))
    }

    /// Ce qui est enregistré ; rien si le fichier manque. Un fichier illisible
    /// lève : mieux vaut le dire que l'écraser au prochain enregistrement.
    func load() throws -> [ProfileSpec] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ProfileSpec].self, from: Data(contentsOf: url))
    }

    func save(_ specs: [ProfileSpec]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(specs).write(to: url, options: .atomic)
    }

    /// Un identifiant neuf pour un disque construit. Le préfixe le distingue
    /// des vingt scénarios du bundle, qui n'en ont pas.
    static func newIdentifier() -> String {
        "perso-" + UUID().uuidString.prefix(8).lowercased()
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix("perso-") }
}
