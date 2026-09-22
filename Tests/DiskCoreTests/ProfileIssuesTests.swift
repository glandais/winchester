import Testing
import Foundation
@testable import DiskCore

/// Un profil écrit à la main se relit avant de se fabriquer.
@Suite("Remarques sur un profil")
struct ProfileIssuesTests {

    @Test("Les vingt scénarios du bundle se fabriquent sans remarque bloquante")
    func bundledScenariosAreBuildable() throws {
        for spec in try ScenarioLibrary.loadAll() {
            #expect(spec.isBuildable, "\(spec.id) : \(spec.issues.map(\.message))")
        }
    }

    @Test("Ce qui arrêterait le générateur est bloquant")
    func blockingIssues() throws {
        var spec = try ScenarioLibrary.load("secretaire-1996")
        spec.fileSystem.clusterKB = 12
        #expect(!spec.isBuildable)

        spec = try ScenarioLibrary.load("secretaire-1996")
        spec.timeline.end = spec.timeline.start
        #expect(!spec.isBuildable)

        spec = try ScenarioLibrary.load("secretaire-1996")
        spec.disk.rpm = 0
        #expect(!spec.isBuildable)
    }

    @Test("Un FAT16 trop grand et un format anachronique avertissent sans bloquer")
    func warnings() throws {
        var spec = try ScenarioLibrary.load("secretaire-1996")
        spec.fileSystem = FileSystemSpec(type: .fat16, clusterKB: 4)
        spec.disk.sizeMB = 2_000
        #expect(spec.isBuildable)
        #expect(spec.issues.contains { $0.severity == .warning && $0.message.contains("n'adresse que") })

        spec = try ScenarioLibrary.load("secretaire-1993")
        spec.fileSystem = FileSystemSpec(type: .ntfs)
        #expect(spec.isBuildable)
        #expect(spec.issues.contains { $0.message.contains("n'arrive qu'en 2001") })

        spec = try ScenarioLibrary.load("secretaire-1993")
        spec.installs.append("inconnu")
        #expect(spec.issues.contains { $0.message.contains("inconnu") })
    }

    /// Quatre logiciels de la galerie sont installés avant leur sortie — MS-DOS
    /// 6.22 en avril 1993, Quake et Netscape 3 en mars 1996, Crysis en avril
    /// 2007. Le README promet que l'anachronisme avertit : il le fait, et
    /// il le fait donc sur ces profils-là, jusqu'à ce que leurs dates bougent.
    @Test("Un logiciel installé avant sa sortie avertit")
    func anachronisticSoftwareWarns() throws {
        // La galerie n'avertit plus : ses dates ont été déplacées après la
        // sortie des logiciels qu'elle installe.
        for spec in try ScenarioLibrary.loadAll() {
            #expect(!spec.issues.contains { $0.message.contains("ne sort que") }, "\(spec.id)")
        }
        var early = try ScenarioLibrary.load("gamer-1996")
        early.timeline.start = CivilDate("1996-03-01")!
        #expect(early.isBuildable)
        #expect(early.issues.contains { $0.message.contains("« Quake » ne sort que le 1996-06-22") })
    }

    @Test("Un profil anachronique mais valide se fabrique")
    func anachronisticProfileGenerates() throws {
        var spec = try ScenarioLibrary.load("gamer-1993")
        spec.id = "perso-test"
        spec.fileSystem = FileSystemSpec(type: .ntfs)
        #expect(spec.isBuildable)
        let disk = try DiskGenerator.generate(spec)
        #expect(disk.metrics.fileCount > 0)
    }
}
