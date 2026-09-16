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
