import Foundation
import DiskCore

/// Ce qu'il reste d'une passe une fois l'app fermée.
///
/// Un `PassRecord` tient le disque entier — son catalogue, ses deux cartes,
/// l'arrangement d'arrivée : quelques mégaoctets pour un NTFS de 320 Go, et
/// c'est pourquoi on n'en garde que douze, en mémoire. Le résumé, lui, tient en
/// deux cents octets : de quoi dire, au prochain lancement, ce qu'on a fait à
/// ce disque et ce que ça a donné, sans prétendre le remontrer.
///
/// C'est la piste 4 de `UX_REVIEW.md` : « garder les bilans d'un lancement à
/// l'autre, résumés, sans leurs cartes ». Les cartes ne survivent pas, et la
/// bascule d'origine/rangé ne vit que le temps de la session qui l'a produite ;
/// ce qui survit, c'est l'état du disque et les chiffres du bilan.
struct PassDigest: Codable, Identifiable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable { case defrag, boot, install, day }

    let id: UUID
    /// Le profil de la galerie. C'est la clé : un disque est une recette, et
    /// deux fabrications de la même recette donnent le même volume.
    let diskID: String
    let title: String
    let kind: Kind
    /// L'outil d'une défragmentation, le système d'un démarrage.
    let toolLabel: String
    let toolID: String?
    let finishedAt: Date
    let duration: Double
    let movedBytes: Int

    // Défragmentation seulement : l'avant → après que le bilan montrait.
    var fragmentedBefore: Int?
    var fragmentedAfter: Int?
    var fragmentsBefore: Int?
    var fragmentsAfter: Int?
    var holesBefore: Int?
    var holesAfter: Int?
    var filesMoved: Int?
    var evacuations: Int?
    var summary: String?

    /// Une passe qui a rangé le disque : c'est elle qui lui donne son état.
    ///
    /// Un outil qui n'a rien trouvé à recoller n'a rien rangé — il a tourné, il
    /// n'a rien changé —, et le disque reste dans l'état où il était. Le dire
    /// ainsi évite d'annoncer « rangé par UltraDefrag » un volume qui n'a pas
    /// bougé d'un cluster.
    var isTidying: Bool {
        guard kind == .defrag, let before = fragmentedBefore, let after = fragmentedAfter else { return false }
        return after < before
    }
}

/// L'état d'un disque, tel qu'une carte et une fiche l'annoncent.
///
/// L'écart central de l'audit : on défragmente un disque, on revient sur sa
/// fiche, et rien ne s'en souvient — les tuiles montrent toujours l'état
/// d'avant, la carte est celle d'avant, et le seul vestige est une ligne au bas
/// de « Plus de détails ». L'utilisateur, lui, pense « mon disque », et
/// s'attend à le retrouver rangé.
struct DiskState: Equatable, Sendable {

    /// La dernière passe qui a rangé ce disque, s'il y en a eu une.
    var tidied: PassDigest?
    /// La dernière passe, quelle qu'elle soit — y compris celle qui n'a rien
    /// changé.
    var last: PassDigest?
    /// Toutes les passes gardées de ce disque, de la plus récente à la plus
    /// ancienne.
    var passes: [PassDigest] = []

    var isEmpty: Bool { passes.isEmpty }
}

/// Les résumés de passes, gardés d'un lancement à l'autre.
///
/// Un seul fichier JSON réécrit en entier, comme `CustomDiskStore` : quelques
/// dizaines de résumés de deux cents octets.
struct PassHistoryStore {

    let url: URL

    /// Ce qu'on garde en tout. Au-delà, les plus anciens tombent — mais jamais
    /// la dernière passe d'un disque : c'est elle qui porte son état, et un
    /// disque rangé il y a trois mois doit encore pouvoir le dire.
    static let limit = 120

    static func standard() -> PassHistoryStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return PassHistoryStore(url: base.appendingPathComponent("Winchester", isDirectory: true)
                                         .appendingPathComponent("passes.json"))
    }

    /// Ce qui est enregistré, du plus récent au plus ancien ; rien si le
    /// fichier manque.
    ///
    /// Un fichier illisible rend une liste vide plutôt que de lever, à la
    /// différence de « Mes disques » : perdre l'historique d'écoute n'est pas
    /// perdre le travail de quelqu'un, et refuser de démarrer pour ça serait
    /// hors de proportion. `PassHistory` le dit par son `failure`.
    func load() throws -> [PassDigest] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let digests = try decoder.decode([PassDigest].self, from: Data(contentsOf: url))
        return digests.sorted { $0.finishedAt > $1.finishedAt }
    }

    func save(_ digests: [PassDigest]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(digests).write(to: url, options: .atomic)
    }

    /// Ce qu'on garde après avoir ajouté `digest` : les plus récents d'abord,
    /// la dernière passe de chaque disque protégée de l'élagage.
    static func trimmed(_ digests: [PassDigest]) -> [PassDigest] {
        let ordered = digests.sorted { $0.finishedAt > $1.finishedAt }
        guard ordered.count > limit else { return ordered }
        // La plus récente de chaque disque est gardée quoi qu'il arrive : elle
        // porte l'état affiché sur sa carte et sa fiche.
        var keptPerDisk: Set<String> = []
        var protected: [UUID: Bool] = [:]
        for digest in ordered where !keptPerDisk.contains(digest.diskID) {
            keptPerDisk.insert(digest.diskID)
            protected[digest.id] = true
        }
        var kept: [PassDigest] = []
        for digest in ordered where protected[digest.id] == true { kept.append(digest) }
        for digest in ordered where protected[digest.id] != true && kept.count < limit {
            kept.append(digest)
        }
        return kept.sorted { $0.finishedAt > $1.finishedAt }
    }
}
