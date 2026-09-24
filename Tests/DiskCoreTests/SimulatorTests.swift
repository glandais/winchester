import Testing
import Foundation
@testable import DiskCore

@Suite("Simulateur et motifs d'écriture")
struct SimulatorTests {

    private static func fat16Volume(megabytes: UInt64 = 256) -> FATAllocator {
        let profile = FAT16Profile(clusterKB: 8)
        return FATAllocator(profile: profile,
                            clusterCount: UInt32(megabytes * 1_024 * 1_024 / UInt64(profile.clusterBytes)),
                            scan: .fromVolumeStart)
    }

    private static func ntfsVolume(megabytes: UInt64 = 256) -> NTFSAllocator {
        let profile = NTFSProfile(clusterKB: 4)
        return NTFSAllocator(profile: profile,
                             clusterCount: UInt32(megabytes * 1_024 * 1_024 / UInt64(profile.clusterBytes)))
    }

    /// Bruit de fond : de quoi mettre le volume dans un état réaliste avant
    /// d'observer un motif d'écriture. Sans lui, tout tombe dans un volume
    /// vierge et rien ne fragmente jamais.
    private func noise(into timeline: inout EventTimeline,
                       directory: UInt32,
                       count: Int,
                       firstID: UInt32,
                       rng: inout SeededGenerator) -> [UInt32] {
        var ids: [UInt32] = []
        for index in 0..<count {
            let id = firstID + UInt32(index)
            timeline.append(.create(FileSpec(id: id,
                                             name: "N\(index).TMP",
                                             directory: directory,
                                             category: .cache,
                                             bytes: ByteCount(max(2_000, rng.logNormal(median: 30_000, sigma: 1.2))))),
                            on: 0)
            ids.append(id)
        }
        return ids
    }

    // MARK: - Les motifs, un par un

    /// Le cas de référence : écrit une fois sur un volume neuf, un fichier est
    /// contigu. Si celui-là fragmentait, tout le reste serait faux.
    @Test("createOnce sur un volume neuf ne fragmente rien")
    func createOnceIsContiguous() throws {
        var timeline = EventTimeline()
        for index in 0..<200 {
            timeline.append(.create(FileSpec(id: UInt32(index),
                                             name: "F\(index).DLL",
                                             directory: 0,
                                             category: .application,
                                             bytes: 200_000)),
                            on: 0)
        }
        var simulator = Simulator(allocator: Self.fat16Volume(), concurrent: false)
        let outcome = try simulator.run(timeline)

        #expect(outcome.metrics.fileCount == 200)
        #expect(outcome.metrics.fragmentedFileCount == 0)
        #expect(outcome.metrics.freeRunCount == 1)
    }

    /// `rewriteInPlace` ne touche à rien : le fichier est réécrit, sa chaîne de
    /// clusters ne bouge pas. C'est le contre-exemple qui montre que le modèle
    /// ne fragmente pas par construction.
    @Test("rewriteInPlace ne déplace aucun cluster")
    func rewriteChangesNothing() throws {
        var timeline = EventTimeline()
        timeline.append(.create(FileSpec(id: 0, name: "FIXED.DAT", directory: 0,
                                         category: .document,
                                         pattern: .rewriteInPlace, bytes: 400_000)),
                        on: 0)
        for day in 1...50 { timeline.append(.rewrite(id: 0), on: UInt32(day)) }

        var simulator = Simulator(allocator: Self.fat16Volume(), concurrent: false)
        let outcome = try simulator.run(timeline)
        let file = try #require(outcome.catalog[0])

        #expect(file.extents.count == 1)
        #expect(outcome.metrics.usedClusters == file.entry.clusterCount)
    }

    /// Le motif de Word : le temporaire est écrit pendant que l'original existe
    /// encore, donc le document change de place à chaque enregistrement et
    /// laisse un trou derrière lui. Sur FAT16, qui rebouche par le début, le
    /// document finit très loin de là où il a commencé.
    @Test("writeTempThenRename déplace le document à chaque enregistrement")
    func wordSaveMovesTheDocument() throws {
        var rng = SeededGenerator(seed: 1_997)
        var timeline = EventTimeline()
        let noiseIDs = noise(into: &timeline, directory: 0, count: 300, firstID: 100, rng: &rng)

        var writer = PatternWriter(timeline: timeline)
        writer.write(FileSpec(id: 1, name: "RAPPORT.DOC", directory: 0,
                              category: .document,
                              pattern: .writeTempThenRename, bytes: 30_000),
                     from: 1, to: 200, touches: 60, rng: &rng)
        timeline = writer.timeline

        // Un trou sur deux est ouvert juste après, pour que les réécritures
        // aient où tomber.
        for (index, id) in noiseIDs.enumerated() where index % 2 == 0 {
            timeline.append(.delete(id: id), on: 2)
        }
        timeline.sortByDay()

        var simulator = Simulator(allocator: Self.fat16Volume(megabytes: 64), concurrent: false)
        let outcome = try simulator.run(timeline)
        let document = try #require(outcome.catalog[1])

        // Le *fast save* ajoute à la fin : le document a grossi tout seul, mais
        // raisonnablement — les enregistrements complets périodiques le
        // ramènent régulièrement à sa taille utile.
        #expect(document.logicalSize > 30_000 * 3)
        #expect(document.logicalSize < 30_000 * 20)
        // Et il a été déplacé : il n'est plus là où il a été créé.
        #expect(document.extents.first!.start > 0)
    }

    /// Le journal qui grossit par la fin, sur un volume où d'autres écritures
    /// s'intercalent : c'est le motif le plus fragmentant du lot.
    @Test("append fragmente quand d'autres écritures s'intercalent")
    func appendFragments() throws {
        var rng = SeededGenerator(seed: 1_999)
        var timeline = EventTimeline()

        // Le journal, et un flot de petits fichiers qui s'écrivent entre deux
        // ajouts et prennent la place qui suivait.
        var writer = PatternWriter()
        writer.write(FileSpec(id: 0, name: "INDEX.DAT", directory: 0,
                              category: .cache,
                              pattern: .append(growthPerEvent: 40_000), bytes: 20_000),
                     from: 0, to: 300, touches: 120, rng: &rng)
        timeline = writer.timeline

        var id: UInt32 = 1_000
        for day in stride(from: UInt32(1), to: UInt32(300), by: 2) {
            timeline.append(.create(FileSpec(id: id, name: "C\(id).TMP", directory: 0,
                                             category: .cache,
                                             bytes: ByteCount(max(3_000, rng.logNormal(median: 26_000, sigma: 1.0))))),
                            on: day)
            id += 1
        }
        timeline.sortByDay()

        var simulator = Simulator(allocator: Self.fat16Volume(megabytes: 64), concurrent: false)
        let outcome = try simulator.run(timeline)
        let journal = try #require(outcome.catalog[0])

        #expect(journal.logicalSize > 20_000)
        #expect(journal.extents.count > 10, "le journal est en \(journal.extents.count) morceaux")
    }

    /// `createDeleteShortLived` ne laisse rien derrière lui — sauf des trous,
    /// qui sont précisément le sujet.
    @Test("createDeleteShortLived ne laisse que des trous")
    func shortLivedLeavesHoles() throws {
        var rng = SeededGenerator(seed: 5)
        var timeline = EventTimeline()
        var writer = PatternWriter()

        // Des fichiers durables, puis des temporaires intercalés qui
        // disparaissent : le volume garde peu de fichiers et beaucoup de trous.
        var id: UInt32 = 0
        for day in 0..<40 {
            for _ in 0..<10 {
                writer.write(FileSpec(id: id, name: "T\(id).OBJ", directory: 0,
                                      category: .buildArtifact,
                                      pattern: .createDeleteShortLived(lifetimeDays: 1),
                                      bytes: ByteCount(max(4_000, rng.logNormal(median: 18_000, sigma: 1.0)))),
                             from: UInt32(day), to: UInt32(day) + 2, touches: 0, rng: &rng)
                id += 1
            }
            writer.write(FileSpec(id: id, name: "KEEP\(id).LIB", directory: 0,
                                  category: .application, bytes: 120_000),
                         from: UInt32(day), to: UInt32(day), touches: 0, rng: &rng)
            id += 1
        }
        timeline = writer.timeline
        timeline.sortByDay()

        var simulator = Simulator(allocator: Self.fat16Volume(megabytes: 32), concurrent: false)
        let outcome = try simulator.run(timeline)

        // Il ne reste que les fichiers durables.
        #expect(outcome.catalog.liveCount == 40)
        #expect(outcome.metrics.fileCount == 40)
    }

    /// `growShrinkDynamic` : `WIN386.SWP` qui gonfle et se dégonfle. La
    /// troncature doit rendre exactement ce qu'elle a pris.
    @Test("growShrinkDynamic rend la place qu'il reprend")
    func swapBreathes() throws {
        var rng = SeededGenerator(seed: 95)
        var writer = PatternWriter()
        writer.write(FileSpec(id: 0, name: "WIN386.SWP", directory: 0,
                              category: .swap,
                              pattern: .growShrinkDynamic(minBytes: 4 * 1_024 * 1_024,
                                                          maxBytes: 20 * 1_024 * 1_024),
                              bytes: 8 * 1_024 * 1_024),
                     from: 0, to: 120, touches: 60, rng: &rng)

        let allocator = Self.fat16Volume(megabytes: 64)
        let clusterBytes = UInt64(allocator.profile.clusterBytes)
        var simulator = Simulator(allocator: allocator, concurrent: false)
        let outcome = try simulator.run(writer.timeline)
        let swap = try #require(outcome.catalog[0])

        // La place occupée correspond toujours exactement à la taille courante.
        let expected = (swap.logicalSize + clusterBytes - 1) / clusterBytes
        #expect(UInt64(swap.entry.clusterCount) == expected)
        #expect(swap.logicalSize >= 4 * 1_024 * 1_024)
        #expect(swap.logicalSize <= 20 * 1_024 * 1_024)
    }

    // MARK: - Défragmentation

    /// Une passe de défragmentation tasse tout contre le début du volume, sauf
    /// le fichier d'échange que le système garde ouvert.
    @Test("La défragmentation tasse le volume et laisse le swap en place")
    func defragmentationCompacts() throws {
        var rng = SeededGenerator(seed: 1_995)
        var timeline = EventTimeline()

        timeline.append(.create(FileSpec(id: 0, name: "WIN386.SWP", directory: 0,
                                         category: .swap, bytes: 6 * 1_024 * 1_024)),
                        on: 0)

        var ids: [UInt32] = []
        for index in 1...600 {
            let id = UInt32(index)
            timeline.append(.create(FileSpec(id: id, name: "F\(index).DAT", directory: 0,
                                             category: .document,
                                             bytes: ByteCount(max(5_000, rng.logNormal(median: 40_000, sigma: 1.3))))),
                            on: 1)
            ids.append(id)
        }
        // Un fichier sur trois disparaît, puis on réécrit : le volume est mité.
        for (index, id) in ids.enumerated() where index % 3 == 0 {
            timeline.append(.delete(id: id), on: 2)
        }
        var next: UInt32 = 10_000
        for _ in 0..<150 {
            timeline.append(.create(FileSpec(id: next, name: "G\(next).DAT", directory: 0,
                                             category: .document,
                                             bytes: ByteCount(max(30_000, rng.logNormal(median: 180_000, sigma: 0.9))))),
                            on: 3)
            next += 1
        }
        timeline.sortByDay()

        var simulator = Simulator(allocator: Self.fat16Volume(megabytes: 64), concurrent: false)
        let before = try simulator.run(timeline)
        let swapBefore = try #require(before.catalog[0])
        // Le scan depuis le début ne laisse pas de trous derrière lui : ce qui
        // est mité ici, ce sont les fichiers, pas l'espace libre.
        #expect(before.metrics.fragmentedFileCount > 0)

        var afterTimeline = EventTimeline()
        afterTimeline.append(.defragment, on: 4)
        let after = try simulator.run(afterTimeline)
        let swapAfter = try #require(after.catalog[0])

        #expect(after.defragRuns == 1)
        // Plus un seul fichier fragmenté, et l'espace libre est rassemblé.
        #expect(after.metrics.fragmentedFileCount == 0)
        #expect(after.metrics.meanExtentsPerFile == 1)
        // L'espace libre est rassemblé : le plus grand bloc a grandi, et il ne
        // reste au plus que deux trous — de part et d'autre du fichier
        // d'échange, qui n'a pas pu être déplacé.
        #expect(after.metrics.largestFreeRunClusters >= before.metrics.largestFreeRunClusters)
        #expect(after.metrics.freeRunCount <= 2)
        // Le fichier d'échange, lui, n'a pas bougé d'un cluster.
        #expect(swapAfter.extents == swapBefore.extents)
        // Aucun fichier n'a été perdu en route.
        #expect(after.metrics.fileCount == before.metrics.fileCount)
        #expect(after.failedWrites == before.failedWrites)
    }

    /// La défragmentation de l'histoire tasse depuis le début, mais laisse la
    /// zone MFT vide : le défragmenteur de XP la rogne de toutes ses listes de
    /// trous (`BuildFreeSpaceList`, `freespace.cpp:305-318`). Tassés à travers
    /// elle, les fichiers y prenaient la place de la MFT, et XP lui ouvrait
    /// une zone neuve loin derrière (chantier 50, 50a).
    @Test("La défragmentation de l'histoire laisse la zone MFT vide")
    func defragmentationSkipsTheMFTZone() throws {
        var rng = SeededGenerator(seed: 2_003)
        var timeline = EventTimeline()
        var ids: [UInt32] = []
        for index in 1...900 {
            let id = UInt32(index)
            timeline.append(.create(FileSpec(id: id, name: "F\(index).DAT", directory: 0,
                                             category: .document,
                                             bytes: ByteCount(max(20_000, rng.logNormal(median: 150_000, sigma: 0.8))))),
                            on: 1)
            ids.append(id)
        }
        for (index, id) in ids.enumerated() where index % 3 == 0 {
            timeline.append(.delete(id: id), on: 2)
        }
        timeline.sortByDay()

        var simulator = Simulator(allocator: Self.ntfsVolume(megabytes: 256), concurrent: false)
        _ = try simulator.run(timeline)
        let zone = try #require(simulator.allocator.defragmentExcludedZone)
        let used = simulator.allocator.bitmap.clusterCount - simulator.allocator.bitmap.freeCount
        // Assez de données pour que le tassage atteigne la zone.
        #expect(used > zone.lowerBound)

        var afterTimeline = EventTimeline()
        afterTimeline.append(.defragment, on: 3)
        let after = try simulator.run(afterTimeline)

        #expect(after.defragRuns == 1)
        #expect(after.failedWrites == 0)
        let intruders = after.catalog.files.filter { record in
            record.extents.contains { $0.start < zone.upperBound && $0.end > zone.lowerBound }
        }
        #expect(intruders.isEmpty, "\(intruders.count) fichiers tassés dans la zone \(zone)")
        // La MFT peut encore grandir sur place : elle reste d'un seul tenant.
        #expect(simulator.allocator.mft.extents.count == 1)
    }

    // MARK: - Déterminisme, annulation, progression

    /// La propriété qui porte tout le reste : même graine, même disque.
    @Test("Deux générations de même graine donnent le même volume")
    func determinism() throws {
        func build() throws -> SimulationOutcome {
            var rng = SeededGenerator(seed: 2_003)
            var writer = PatternWriter()
            var id: UInt32 = 0
            for day in 0..<120 {
                for _ in 0..<12 {
                    let pattern: WritePattern = switch rng.below(4) {
                    case 0: .createOnce
                    case 1: .append(growthPerEvent: 30_000)
                    case 2: .writeTempThenRename
                    default: .createDeleteShortLived(lifetimeDays: 3)
                    }
                    writer.write(FileSpec(id: id, name: "F\(id)", directory: 0,
                                          category: .document, pattern: pattern,
                                          bytes: ByteCount(max(1_000, rng.logNormal(median: 40_000, sigma: 1.4)))),
                                 from: UInt32(day), to: UInt32(day) + 30, touches: 4, rng: &rng)
                    id += 1
                }
            }
            var timeline = writer.timeline
            timeline.sortByDay()
            var simulator = Simulator(allocator: Self.ntfsVolume(), concurrent: false)
            return try simulator.run(timeline)
        }

        let first = try build()
        let second = try build()

        #expect(first.metrics == second.metrics)
        #expect(first.catalog.files.map(\.extents) == second.catalog.files.map(\.extents))
        #expect(first.catalog.files.map(\.logicalSize) == second.catalog.files.map(\.logicalSize))
    }

    /// Le tri par jour doit être stable : deux événements du même jour gardent
    /// leur ordre d'insertion. Sinon deux générations identiques divergeraient.
    @Test("Le tri par jour conserve l'ordre d'insertion")
    func stableSort() {
        var timeline = EventTimeline()
        for index in 0..<500 {
            timeline.append(.rewrite(id: UInt32(index)), on: UInt32(index % 7))
        }
        var sorted = timeline
        sorted.sortByDay()

        var seen: [UInt32] = []
        for event in sorted.events {
            guard case let .rewrite(id) = event.event else { continue }
            seen.append(id)
        }
        // À l'intérieur de chaque journée, les identifiants restent croissants.
        for day in UInt32(0)..<7 {
            let ofDay = seen.filter { $0 % 7 == day }
            #expect(ofDay == ofDay.sorted())
        }
    }

    @Test("La progression est rapportée et va jusqu'au bout")
    func progressIsReported() throws {
        var timeline = EventTimeline()
        for index in 0..<5_000 {
            timeline.append(.create(FileSpec(id: UInt32(index), name: "F\(index)", directory: 0,
                                             category: .cache, bytes: 9_000)),
                            on: UInt32(index / 100))
        }

        var reports: [GenerationProgress] = []
        var simulator = Simulator(allocator: Self.ntfsVolume(), concurrent: false)
        _ = try simulator.run(timeline) { reports.append($0) }

        #expect(reports.count > 1)
        #expect(reports.first!.fraction == 0)
        #expect(reports.last!.fraction == 1)
        #expect(reports.last!.completedEvents == timeline.count)
        // L'avancement ne recule jamais.
        for (previous, next) in zip(reports, reports.dropFirst()) {
            #expect(next.completedEvents >= previous.completedEvents)
            #expect(next.day >= previous.day)
        }
    }

    /// Une génération doit pouvoir être abandonnée : sur un téléphone, changer
    /// de scénario ne doit pas attendre la fin du précédent.
    @Test("Une génération annulée s'arrête")
    func cancellation() async {
        var timeline = EventTimeline()
        for index in 0..<200_000 {
            timeline.append(.create(FileSpec(id: UInt32(index), name: "F\(index)", directory: 0,
                                             category: .cache, bytes: 5_000)),
                            on: UInt32(index / 1_000))
        }
        let frozen = timeline

        let task = Task.detached { () -> Bool in
            var simulator = Simulator(allocator: Self.ntfsVolume(megabytes: 4_096), concurrent: false)
            do {
                _ = try simulator.run(frozen)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let cancelled = await task.value
        #expect(cancelled)
    }

    /// Le journal est injecté, jamais imprimé : rien ne doit partir dans la
    /// console d'un build de production.
    @Test("Le journal de génération reçoit ce qui se passe")
    func loggerReceivesMessages() throws {
        final class Recorder: GenerationLogger, @unchecked Sendable {
            private let lock = NSLock()
            private var messages: [String] = []
            func log(_ message: String) {
                lock.lock(); defer { lock.unlock() }
                messages.append(message)
            }
            var all: [String] {
                lock.lock(); defer { lock.unlock() }
                return messages
            }
        }

        var timeline = EventTimeline()
        timeline.append(.create(FileSpec(id: 0, name: "A.DAT", directory: 0,
                                         category: .document, bytes: 50_000)),
                        on: 0)
        timeline.append(.defragment, on: 1)

        let recorder = Recorder()
        var simulator = Simulator(allocator: Self.fat16Volume(), logger: recorder, concurrent: false)
        _ = try simulator.run(timeline)

        #expect(recorder.all.count == 2)
        #expect(recorder.all.contains { $0.contains("défragmentation") })
    }
}

@Suite("Composition d'allocateurs")
struct AllocatorCompositionTests {

    /// `ProfilingAllocator` enveloppe n'importe quel allocateur sans rien
    /// changer à ce qu'il produit. C'est lui qui a permis de trouver d'où
    /// venaient les trois secondes et demie d'une génération de volume XP ;
    /// ce test vérifie qu'il reste transparent, et au passage que le protocole
    /// se compose vraiment.
    @Test("Envelopper un allocateur ne change pas le volume produit")
    func profilingIsTransparent() throws {
        var rng = SeededGenerator(seed: 31)
        var writer = PatternWriter()
        for index in 0..<400 {
            writer.write(FileSpec(id: UInt32(index), name: "F\(index)", directory: 0,
                                  category: .document,
                                  pattern: index % 3 == 0 ? .writeTempThenRename : .createOnce,
                                  bytes: ByteCount(max(3_000, rng.logNormal(median: 50_000, sigma: 1.2)))),
                         from: UInt32(index % 50), to: UInt32(index % 50) + 20,
                         touches: 3, rng: &rng)
        }
        var timeline = writer.timeline
        timeline.sortByDay()

        let profile = NTFSProfile(clusterKB: 4)
        let clusterCount: UInt32 = 65_536

        var plain = Simulator(allocator: NTFSAllocator(profile: profile, clusterCount: clusterCount),
                              concurrent: false)
        var wrapped = Simulator(allocator: ProfilingAllocator(
            NTFSAllocator(profile: profile, clusterCount: clusterCount)), concurrent: false)

        let a = try plain.run(timeline)
        let b = try wrapped.run(timeline)

        #expect(a.metrics == b.metrics)
        #expect(a.catalog.files.map(\.extents) == b.catalog.files.map(\.extents))
        #expect(wrapped.allocator.allocateCalls > 0)
    }
}
