import Testing
import Foundation
@testable import DiskCore

/// Un profil écrit à la main se relit avant de se fabriquer.
@Suite("Remarques sur un profil")
struct ProfileIssuesTests {

    @Test("Les vingt scénarios du bundle se fabriquent sans remarque bloquante")
    func bundledScenariosAreBuildable() throws {
        for spec in try ScenarioLibrary.loadAll() {
            #expect(spec.isBuildable, "\(spec.id) : \(spec.issues.map(\.kind))")
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
        #expect(spec.issues.contains {
            if case .formatAddressesLess(.fat16, _, 4) = $0.kind { return $0.severity == .warning }
            return false
        })

        spec = try ScenarioLibrary.load("secretaire-1993")
        spec.fileSystem = FileSystemSpec(type: .ntfs)
        #expect(spec.isBuildable)
        #expect(spec.issues.contains { $0.kind == .formatTooEarly(.ntfs, year: 2001) })

        spec = try ScenarioLibrary.load("secretaire-1993")
        spec.installs.append("inconnu")
        #expect(spec.issues.contains { $0.kind == .unknownSoftware(["inconnu"]) })
    }

    /// Le README promet que l'anachronisme avertit. La galerie, elle, n'en a
    /// plus : quatre logiciels y étaient installés avant leur sortie — MS-DOS
    /// 6.22 en avril 1993, Quake et Netscape 3 en mars 1996, Crysis en avril
    /// 2007 —, et les dates de ces profils ont été déplacées (lot F). Le test
    /// vérifie donc les deux : aucun profil de la galerie n'avertit, et un
    /// profil ramené avant la sortie de Quake, si.
    @Test("Un logiciel installé avant sa sortie avertit")
    func anachronisticSoftwareWarns() throws {
        // La galerie n'avertit plus : ses dates ont été déplacées après la
        // sortie des logiciels qu'elle installe.
        for spec in try ScenarioLibrary.loadAll() {
            #expect(!spec.issues.contains {
                if case .installedBeforeRelease = $0.kind { return true }
                return false
            }, "\(spec.id)")
        }
        var early = try ScenarioLibrary.load("gamer-1996")
        early.timeline.start = CivilDate("1996-03-01")!
        #expect(early.isBuildable)
        #expect(early.issues.contains {
            $0.kind == .installedBeforeRelease(app: "Quake", released: CivilDate("1996-06-22")!)
        })
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
