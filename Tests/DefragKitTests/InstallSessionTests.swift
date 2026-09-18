import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Installer un disque de la galerie.
///
/// Comme pour le démarrage, le son ne se teste pas ; ce qui se teste, c'est ce
/// dont il dépend : l'installation écrit là où l'allocateur a posé, elle laisse
/// la carte du disque d'arrivée, et ce qui la rythme — source, tables,
/// redémarrages — suit l'époque.
@Suite("Installation d'un disque généré")
struct InstallSessionTests {

    /// Une époque de disquettes, une de CD en FAT, une de NTFS.
    static let profiles = ["gamer-1993", "secretaire-1996", "famille-2003"]

    private struct Planned {
        let installed: InstalledDisk
        let partition: PartitionGeometry
        let plan: InstallPlan
        let operations: [DiskOperation]
        let mutations: [MapMutation]
    }

    private static func planned(_ id: String) throws -> Planned {
        let installed = try DiskGenerator.install(try ScenarioLibrary.load(id))
        let sink = OperationSink()
        let plan = InstallPlanner.plan(installed: installed, diskBytesPerSecond: 5_000_000, into: sink)
        return Planned(installed: installed, partition: plan.partition, plan: plan,
                       operations: sink.operations, mutations: sink.mutations)
    }

    @Test("Une installation n'écrit que dans le volume", arguments: InstallSessionTests.profiles)
    func withinVolume(id: String) throws {
        let planned = try Self.planned(id)
        #expect(!planned.operations.isEmpty)
        for operation in planned.operations {
            #expect(operation.lba >= planned.partition.startLBA)
            #expect(operation.lba + operation.sectors <= planned.partition.totalSectors)
            #expect(operation.sectors > 0)
            #expect(operation.thinkTime >= 0)
            #expect(planned.plan.phases.indices.contains(operation.phase))
        }
        // Les phases avancent : une étape ne revient pas en arrière.
        let phases = planned.operations.map(\.phase)
        #expect(zip(phases, phases.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Deux installations du même disque sont identiques")
    func deterministic() throws {
        let a = try Self.planned("secretaire-1996")
        let b = try Self.planned("secretaire-1996")
        #expect(a.operations.count == b.operations.count)
        #expect(zip(a.operations, b.operations).allSatisfy {
            $0.lba == $1.lba && $0.sectors == $1.sectors && $0.isWrite == $1.isWrite
                && $0.thinkTime == $1.thinkTime && $0.phase == $1.phase
        })
    }

    @Test("Chaque cluster d'un fichier posé est écrit", arguments: InstallSessionTests.profiles)
    func everyClusterWritten(id: String) throws {
        let planned = try Self.planned(id)
        let partition = planned.partition
        var written = [Bool](repeating: false, count: partition.clusterCount)
        for operation in planned.operations where operation.kind == .writeExtent {
            let first = (operation.lba - partition.dataStartLBA) / partition.clusterSectors
            for cluster in first..<(first + operation.sectors / partition.clusterSectors) {
                written[cluster] = true
            }
        }
        let swap = Set(planned.installed.steps.filter { $0.kind == .swap }.flatMap(\.fileIDs))
        var missing = 0
        for record in planned.installed.disk.catalog.files where !swap.contains(record.id) {
            // Seuls les clusters que la taille logique remplit sont écrits.
            var remaining = partition.clusters(forBytes: max(Int(record.logicalSize), 1))
            for extent in record.extents where remaining > 0 {
                for cluster in extent.start..<extent.end where remaining > 0 {
                    if !written[Int(cluster)] { missing += 1 }
                    remaining -= 1
                }
            }
        }
        #expect(missing == 0)
    }

    @Test("La carte rejouée finit sur le disque d'arrivée", arguments: InstallSessionTests.profiles)
    func mapEndsOnInstalledDisk(id: String) throws {
        let planned = try Self.planned(id)
        let disk = planned.installed.disk
        let count = Int(disk.clusterCount)

        var map = [UInt8](repeating: ClusterCategory.free.rawValue, count: count)
        for run in InstallPlanner.initialRuns(of: planned.installed) {
            for cluster in Int(run.start)..<Int(run.end) { map[cluster] = run.category }
        }
        for mutation in planned.mutations {
            for cluster in mutation.start..<(mutation.start + mutation.count) {
                map[cluster] = mutation.category.rawValue
            }
        }

        var expected = [UInt8](repeating: ClusterCategory.free.rawValue, count: count)
        for extent in disk.systemExtents {
            for cluster in Int(extent.start)..<Int(extent.end) { expected[cluster] = ClusterCategory.reserved.rawValue }
        }
        for record in disk.catalog.files {
            let category = ClusterCategory(record.category).rawValue
            for extent in record.extents {
                for cluster in Int(extent.start)..<Int(extent.end) { expected[cluster] = category }
            }
        }
        // Les répertoires que l'installation a créés, et fait grandir.
        for directory in disk.catalog.directories {
            for extent in directory.extents {
                for cluster in Int(extent.start)..<Int(extent.end) {
                    expected[cluster] = ClusterCategory.directory.rawValue
                }
            }
        }
        let mismatches = zip(map, expected).filter { $0 != $1 }.count
        #expect(mismatches == 0)
    }

    @Test("MS-DOS écrit ses tables à chaque fichier, Windows 95 par salves")
    func metadataFlushFollowsEra() throws {
        let dos = try Self.planned("gamer-1993")
        #expect(dos.plan.metadataFlushes >= dos.plan.filesWritten)

        let windows = try Self.planned("secretaire-1996")
        #expect(windows.plan.metadataFlushes * 4 < windows.plan.filesWritten)
    }

    @Test("Les redémarrages et la source suivent l'époque", arguments: InstallSessionTests.profiles)
    func rebootsAndSource(id: String) throws {
        let planned = try Self.planned(id)
        let announced = planned.installed.steps.reduce(0) { $0 + $1.style.reboots }
        #expect(planned.plan.reboots == announced)
        #expect(planned.plan.sourceSeconds > 0)
        #expect(planned.plan.thinkSeconds > planned.plan.sourceSeconds)
        #expect(planned.plan.settingsRewrites > 0)
    }

    @Test("Une disquette coûte plus par mégaoctet qu'un CD")
    func floppyIsSlower() throws {
        let floppy = try Self.planned("gamer-1993")
        let cd = try Self.planned("secretaire-1996")
        let floppyRate = floppy.plan.sourceSeconds / Double(floppy.plan.bytesWritten)
        let cdRate = cd.plan.sourceSeconds / Double(cd.plan.bytesWritten)
        #expect(floppyRate > cdRate * 10)
    }

    @Test("Un installeur relit les archives qu'il a extraites, puis les efface")
    func cabinetsAreReadBack() throws {
        let planned = try Self.planned("secretaire-1996")
        #expect(planned.plan.temporaryFiles > 0)
        #expect(planned.plan.temporaryBytesRead > 0)
        let freed = planned.mutations.filter { $0.category == .free }.reduce(0) { $0 + $1.count }
        #expect(freed > 0)
    }

    @Test("Les phases nomment chaque logiciel, et ses redémarrages")
    func phasesNameSteps() throws {
        let planned = try Self.planned("secretaire-1996")
        let labels = planned.plan.phases.map(\.label)
        #expect(labels.first == "Copie de Windows 95")
        #expect(labels.contains("Installation de Office 95"))
        #expect(labels.contains("Redémarrages et configuration"))
    }
}
