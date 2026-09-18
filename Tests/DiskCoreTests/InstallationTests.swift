import Testing
import Foundation
@testable import DiskCore

/// L'installation du jour 0 : ses étapes, ses archives, et le disque qu'elle
/// laisse.
@Suite("Installation")
struct InstallationTests {

    @Test("Les archives d'un installeur naissent et meurent le jour de l'installation",
          arguments: ["secretaire-1996", "famille-1999", "gamer-2003"])
    func temporariesLiveOneDay(id: String) throws {
        let compiled = ScenarioCompiler.compile(try ScenarioLibrary.load(id))
        let temporaries = Set(compiled.installSteps.flatMap(\.temporaryIDs))
        #expect(!temporaries.isEmpty)

        var created: Set<UInt32> = []
        var deleted: Set<UInt32> = []
        for timed in compiled.timeline.events {
            switch timed.event {
            case let .create(spec) where temporaries.contains(spec.id):
                #expect(timed.day == 0)
                #expect(spec.category == .temporary)
                created.insert(spec.id)
            case let .delete(id) where temporaries.contains(id):
                #expect(timed.day == 0)
                #expect(created.contains(id), "effacé avant d'être extrait")
                deleted.insert(id)
            default:
                break
            }
        }
        #expect(created == temporaries)
        #expect(deleted == temporaries)
    }

    @Test("Les étapes couvrent toutes les créations du jour 0",
          arguments: ["gamer-1993", "secretaire-1996", "famille-2007"])
    func stepsCoverDayZero(id: String) throws {
        let compiled = ScenarioCompiler.compile(try ScenarioLibrary.load(id))
        let described = Set(compiled.installSteps.flatMap { $0.temporaryIDs + $0.fileIDs })
        var dayZero: Set<UInt32> = []
        for timed in compiled.timeline.events where timed.day == 0 {
            if case let .create(spec) = timed.event { dayZero.insert(spec.id) }
        }
        #expect(dayZero == described)
        #expect(compiled.installSteps.last?.kind == .swap)
        #expect(compiled.installSteps.first?.kind == .system)
    }

    @Test("Le système pose ses ruches, réécrites en place")
    func systemPlacesHives() throws {
        let compiled = ScenarioCompiler.compile(try ScenarioLibrary.load("famille-2003"))
        let system = try #require(compiled.installSteps.first)
        #expect(system.manifestID == "winxp")
        #expect(system.settingsIDs.count == 6)
        #expect(Set(system.settingsIDs).isSubset(of: Set(system.fileIDs)))
        // Démarré depuis le CD : rien n'est extrait à côté.
        #expect(system.temporaryIDs.isEmpty)
        #expect(system.style.reboots == 2)
    }

    @Test("Une époque de disquettes n'extrait rien et ne redémarre qu'une fois par système")
    func floppyEra() throws {
        let compiled = ScenarioCompiler.compile(try ScenarioLibrary.load("gamer-1993"))
        for step in compiled.installSteps where step.kind != .swap {
            #expect(step.style.medium == .floppy)
            #expect(step.temporaryIDs.isEmpty)
            #expect(step.style.reboots == (step.kind == .system ? 1 : 0))
        }
    }

    @Test("Le journal rejoué sur un volume vierge redonne la bitmap du soir",
          arguments: ["gamer-1993", "secretaire-1996", "famille-2003"])
    func journalRebuildsBitmap(id: String) throws {
        let installed = try DiskGenerator.install(try ScenarioLibrary.load(id))
        var bitmap = ClusterBitmap(clusterCount: installed.disk.clusterCount)
        for extent in installed.initialSystemExtents { bitmap.allocate(extent) }
        var steps = 0
        for entry in installed.journal {
            switch entry {
            case .begin: steps += 1
            case let .created(record): for extent in record.extents { bitmap.allocate(extent) }
            case let .deleted(record): _ = bitmap.free(record.extents)
            case let .metadataGrew(extents): for extent in extents { bitmap.allocate(extent) }
            case let .directoryGrew(extents): for extent in extents { bitmap.allocate(extent) }
            }
        }
        #expect(steps == installed.steps.count)
        #expect(bitmap.usedCount == installed.disk.bitmap.usedCount)
        var cluster: UInt32 = 0
        var mismatches = 0
        while cluster < bitmap.clusterCount {
            if bitmap.isAllocated(cluster) != installed.disk.bitmap.isAllocated(cluster) { mismatches += 1 }
            cluster += 1
        }
        #expect(mismatches == 0)
        // Les archives sont parties : elles ont laissé leurs trous.
        let temporaries = Set(installed.steps.flatMap(\.temporaryIDs))
        #expect(installed.disk.catalog.files.allSatisfy { !temporaries.contains($0.id) })
    }

    @Test("Le disque installé est celui que la génération vieillit",
          arguments: ["gamer-1993", "secretaire-1996", "famille-2003"])
    func installedIsTheStartOfGeneration(id: String) throws {
        let spec = try ScenarioLibrary.load(id)
        let installed = try DiskGenerator.install(spec)
        let aged = try DiskGenerator.generate(spec)

        // Un fichier posé le jour 0 et jamais retouché garde sa place : ce que
        // l'installation a écrit est bien ce que l'usage a trouvé.
        var compared = 0
        for record in aged.catalog.files
        where record.createdDay == 0 && record.modifiedDay == 0 && record.category != .swap {
            let fresh = try #require(installed.disk.catalog[record.id])
            #expect(fresh.extents == record.extents)
            #expect(fresh.logicalSize == record.logicalSize)
            compared += 1
        }
        #expect(compared > 100)
    }

    @Test("Soustraire des extents garde ce qui dépasse, dans l'ordre")
    func extentSubtraction() {
        let before = [Extent(start: 10, length: 5)]
        let after = [Extent(start: 10, length: 8), Extent(start: 40, length: 2)]
        #expect(after.subtracting(before) == [Extent(start: 15, length: 3), Extent(start: 40, length: 2)])
        #expect(before.subtracting(after).isEmpty)
        #expect([Extent(start: 0, length: 10)].subtracting([Extent(start: 3, length: 2)])
                == [Extent(start: 0, length: 3), Extent(start: 5, length: 5)])
    }
}
