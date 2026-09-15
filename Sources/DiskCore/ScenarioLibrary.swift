import Foundation

/// Les scénarios livrés avec l'application : cinq époques, quatre profils
/// chacune.
///
/// Ce sont des fichiers JSON, pas du code. On peut en ajouter un sans
/// recompiler quoi que ce soit, et surtout on peut les **lire** : une époque y
/// tient en vingt lignes, et aucune de ces lignes ne parle de fragmentation.
public enum ScenarioLibrary {

    public enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case unreadable(String, underlying: Error)

        public var description: String {
            switch self {
            case let .notFound(id): return "scénario introuvable : \(id)"
            case let .unreadable(id, error): return "scénario illisible (\(id)) : \(error)"
            }
        }
    }

    /// Identifiants des scénarios embarqués, dans l'ordre chronologique puis
    /// alphabétique — un ordre stable, qui ne dépend pas du système de fichiers
    /// qui les stocke.
    public static let identifiers: [String] = [
        "dev-1993", "gamer-1993", "poweruser-1993", "secretaire-1993",
        "dev-1996", "famille-1996", "gamer-1996", "secretaire-1996",
        "dev-1999", "famille-1999", "gamer-1999", "secretaire-1999",
        "dev-2003", "famille-2003", "gamer-2003", "secretaire-2003",
        "dev-2007", "famille-2007", "gamer-2007", "secretaire-2007",
    ]

    /// Emplacement d'un scénario dans le bundle. Selon la façon dont les
    /// ressources ont été traitées, le sous-dossier peut avoir été aplati :
    /// les deux cas sont essayés.
    public static func url(for id: String) -> URL? {
        Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "scenarios")
            ?? Bundle.module.url(forResource: id, withExtension: "json")
    }

    public static func load(_ id: String) throws -> ProfileSpec {
        guard let url = url(for: id) else { throw LoadError.notFound(id) }
        do {
            return try ProfileSpec.decode(from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(id, underlying: error)
        }
    }

    public static func loadAll() throws -> [ProfileSpec] {
        try identifiers.map(load)
    }
}
