import Testing
import Foundation
@testable import DiskCore

/// Un chemin ne désigne qu'un fichier présent.
///
/// FAT comme NTFS refusent deux fichiers du même nom dans un répertoire, sans
/// distinction de casse. Les défragmenteurs s'appuient dessus : trier par nom,
/// ou départager par chemin, ne donne un ordre unique qu'à cette condition.
@Suite("Noms de fichiers")
struct FileNameTests {

    private enum Step {
        case create(UInt32, String, directory: UInt32 = 0)
        case delete(UInt32)
    }

    /// Les noms que reçoivent les créations, dans l'ordre.
    private static func names(_ steps: [Step]) -> [String] {
        var timeline = EventTimeline()
        for step in steps {
            switch step {
            case let .create(id, name, directory):
                timeline.append(.create(FileSpec(id: id, name: name, directory: directory,
                                                 category: .source, bytes: 1_000)), on: 0)
            case let .delete(id):
                timeline.append(.delete(id: id), on: 0)
            }
        }
        timeline.giveUniqueNames()
        return timeline.events.compactMap {
            guard case let .create(spec) = $0.event else { return nil }
            return spec.name
        }
    }

    @Test("Un nom porté par un fichier présent reçoit un alias à la manière de Windows")
    func aliases() {
        #expect(Self.names([.create(1, "MODULE.C"), .create(2, "MODULE.C"), .create(3, "module.c"),
                            .create(4, "MODULE.C", directory: 1)])
                == ["MODULE.C", "MODULE~1.C", "module~2.c", "MODULE.C"])
        #expect(Self.names([.create(1, "DL"), .create(2, "DL"), .create(3, "EXTRAIT"), .create(4, "EXTRAIT")])
                == ["DL", "DL~1", "EXTRAIT", "EXTRAI~1"])
    }

    @Test("Un nom libéré par une suppression est repris tel quel")
    func freedNamesAreReused() {
        #expect(Self.names([.create(1, "SAVE.DAT"), .delete(1), .create(2, "SAVE.DAT")])
                == ["SAVE.DAT", "SAVE.DAT"])
        #expect(Self.names([.create(1, "A.OBJ"), .create(2, "A.OBJ"), .delete(1),
                            .create(3, "A.OBJ"), .create(4, "A.OBJ")])
                == ["A.OBJ", "A~1.OBJ", "A.OBJ", "A~2.OBJ"])
    }

    @Test("Un alias ne prend pas un nom déjà porté")
    func aliasSkipsTakenNames() {
        #expect(Self.names([.create(1, "MODULE~1.C"), .create(2, "MODULE.C"), .create(3, "MODULE.C")])
                == ["MODULE~1.C", "MODULE.C", "MODULE~2.C"])
    }

    @Test("Aucun scénario de la galerie ne fait coexister deux fichiers du même chemin")
    func galleryPathsAreUnique() throws {
        for spec in try ScenarioLibrary.loadAll() {
            let compiled = ScenarioCompiler.compile(spec)
            var live: [String: UInt32] = [:]
            var pathOfFile: [UInt32: String] = [:]
            var duplicates = 0
            for timed in compiled.timeline.events {
                switch timed.event {
                case let .create(file):
                    let path = "\(file.directory)\\\(file.name.uppercased())"
                    if live[path] != nil { duplicates += 1 }
                    live[path] = file.id
                    pathOfFile[file.id] = path
                case let .delete(id):
                    if let path = pathOfFile.removeValue(forKey: id), live[path] == id { live[path] = nil }
                default:
                    break
                }
            }
            #expect(duplicates == 0, "\(spec.id) : \(duplicates) fichiers créés sur un chemin occupé")
        }
    }
}
