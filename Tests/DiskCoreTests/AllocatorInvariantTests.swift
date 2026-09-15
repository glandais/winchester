import Testing
import Foundation
@testable import DiskCore

/// Les invariants de la phase 1 étaient vérifiés sur un bac à sable. Ils le sont
/// ici sur les allocateurs réels, à travers une histoire complète : c'est là
/// qu'une stratégie de placement peut réellement se tromper, en servant deux
/// fois le même cluster ou en débordant d'une plage réservée.
@Suite("Invariants des allocateurs")
struct AllocatorInvariantTests {

    private static let seeds = 0..<20
    private static let volumeBytes: UInt64 = 128 * 1_024 * 1_024

    /// Histoire courte mais hostile : beaucoup de créations et de suppressions
    /// entrelacées, quelques gros fichiers, un fichier à placement contraint.
    private func history(seed: UInt64) -> [FSEvent] {
        var rng = SeededGenerator(seed: seed)
        var events: [FSEvent] = []
        var live: [UInt32] = []
        var id: UInt32 = 0

        func newID() -> UInt32 { id += 1; return id }

        events.append(.create(id: newID(), bytes: Self.volumeBytes / 20, hint: .reservedContiguous))
        events.append(.create(id: newID(), bytes: 64_000, hint: .boot))

        for step in 0..<2_500 {
            switch rng.below(10) {
            case 0...5:
                let bytes = UInt64(max(700, rng.logNormal(median: 20_000, sigma: 1.5)))
                let newFile = newID()
                events.append(.create(id: newFile, bytes: bytes,
                                      hint: step % 7 == 0 ? .temporary : .normal))
                live.append(newFile)
            case 6:
                let bytes = UInt64(max(200_000, rng.logNormal(median: 2_000_000, sigma: 0.7)))
                let newFile = newID()
                events.append(.create(id: newFile, bytes: bytes, hint: .normal))
                live.append(newFile)
            case 7...8:
                guard !live.isEmpty else { continue }
                let target = live[rng.index(below: live.count)]
                events.append(.grow(id: target,
                                    toBytes: UInt64(max(4_000, rng.logNormal(median: 90_000, sigma: 1.2)))))
            default:
                guard !live.isEmpty else { continue }
                events.append(.delete(id: live.remove(at: rng.index(below: live.count))))
            }
        }
        return events
    }

    /// Vérifie sur un état final tout ce qui doit tenir quel que soit
    /// l'allocateur.
    private func check<A: Allocator>(_ label: String, _ allocator: A, _ files: [FileEntry]) {
        let bitmap = allocator.bitmap
        let profile = allocator.profile

        var owner = [UInt32](repeating: .max, count: Int(bitmap.clusterCount))
        var counted: UInt32 = 0

        for file in files {
            // Invariant 2 : la place occupée est celle qu'exige la taille
            // logique, arrondie au cluster.
            if file.isResident {
                #expect(file.extents.isEmpty, "\(label) : un fichier résident n'alloue rien")
                continue
            }
            #expect(file.clusterCount == profile.clusters(forBytes: file.logicalSize),
                    "\(label) : fichier \(file.id) mal dimensionné")

            for extent in file.extents {
                // Invariant 6 : rien hors des bornes du volume.
                #expect(UInt64(extent.start) + UInt64(extent.length) <= UInt64(bitmap.clusterCount),
                        "\(label) : extent hors volume")
                #expect(extent.length > 0, "\(label) : extent vide")

                for cluster in extent.start..<extent.end {
                    // Invariant 1 : aucun cluster alloué deux fois.
                    #expect(owner[Int(cluster)] == .max,
                            "\(label) : cluster \(cluster) réclamé par \(owner[Int(cluster)]) et \(file.id)")
                    owner[Int(cluster)] = file.id
                    #expect(bitmap.isAllocated(cluster),
                            "\(label) : cluster \(cluster) détenu mais marqué libre")
                    counted += 1
                }
            }

            // Invariant 7 : un fichier à placement contraint est d'un seul
            // tenant.
            if file.hint == .reservedContiguous {
                #expect(file.extents.count == 1,
                        "\(label) : fichier contraint en \(file.extents.count) extents")
            }
        }

        // Les clusters détenus par des fichiers ne peuvent pas dépasser les
        // clusters marqués occupés — la différence est ce qui appartient au
        // système de fichiers lui-même ($Boot, $MFT, $MFTMirr).
        #expect(counted <= bitmap.usedCount, "\(label) : plus de clusters détenus qu'alloués")
        #expect(bitmap.freeCount + bitmap.usedCount == bitmap.clusterCount)
    }

    @Test("FAT16 tient ses invariants", arguments: AllocatorInvariantTests.seeds)
    func fat16(seed: Int) {
        let profile = FAT16Profile(clusterKB: 8)
        var allocator = FATAllocator(profile: profile,
                                     clusterCount: UInt32(Self.volumeBytes / UInt64(profile.clusterBytes)),
                                     scan: .fromVolumeStart)
        let result = replay(history(seed: UInt64(seed)), on: &allocator)
        check("FAT16", allocator, result.files)
    }

    @Test("FAT32 tient ses invariants", arguments: AllocatorInvariantTests.seeds)
    func fat32(seed: Int) {
        let profile = FAT32Profile(clusterKB: 4)
        var allocator = FATAllocator(profile: profile,
                                     clusterCount: UInt32(Self.volumeBytes / UInt64(profile.clusterBytes)),
                                     scan: .fromLastAllocated)
        let result = replay(history(seed: UInt64(seed)), on: &allocator)
        check("FAT32", allocator, result.files)
    }

    @Test("NTFS tient ses invariants", arguments: AllocatorInvariantTests.seeds)
    func ntfs(seed: Int) {
        let profile = NTFSProfile(clusterKB: 4)
        var allocator = NTFSAllocator(profile: profile,
                                      clusterCount: UInt32(Self.volumeBytes / UInt64(profile.clusterBytes)))
        let result = replay(history(seed: UInt64(seed)), on: &allocator)
        check("NTFS", allocator, result.files)

        // La MFT est un fichier comme les autres : ses extents ne recouvrent
        // rien et restent dans le volume.
        for extent in allocator.mft.extents {
            #expect(UInt64(extent.start) + UInt64(extent.length) <= UInt64(allocator.bitmap.clusterCount))
            #expect(allocator.bitmap.isAllocated(extent.start))
        }
        for file in result.files {
            for extent in file.extents {
                for mftExtent in allocator.mft.extents {
                    let disjoint = extent.end <= mftExtent.start || mftExtent.end <= extent.start
                    #expect(disjoint, "un fichier chevauche la MFT")
                }
            }
        }
    }

    /// Invariant 3, sur les allocateurs réels : libérer rend exactement la place
    /// occupée, et tout libérer ramène le volume à son état de départ.
    @Test("La libération rend exactement la place occupée",
          arguments: AllocatorInvariantTests.seeds)
    func freeingIsExact(seed: Int) {
        let profile = FAT32Profile(clusterKB: 4)
        var allocator = FATAllocator(profile: profile,
                                     clusterCount: UInt32(Self.volumeBytes / UInt64(profile.clusterBytes)),
                                     scan: .fromLastAllocated)
        var result = replay(history(seed: UInt64(seed)), on: &allocator)

        for index in result.files.indices {
            let occupied = result.files[index].clusterCount
            let before = allocator.bitmap.freeCount
            allocator.release(file: &result.files[index])
            #expect(allocator.bitmap.freeCount == before + occupied)
        }
        #expect(allocator.bitmap.usedCount == 0)
        #expect(allocator.bitmap.freeRunCount() == 1)
    }

    /// L'invariant 7 mérite d'être poussé : un fichier contraint doit rester
    /// d'un seul tenant **tant que** le volume a un bloc assez grand, et la
    /// règle ne cède que lorsqu'il n'en a plus.
    @Test("Le placement contraint ne cède qu'à court d'espace contigu")
    func reservedContiguousHoldsUntilItCannot() {
        let profile = FAT32Profile(clusterKB: 4)
        let clusterCount: UInt32 = 32_768
        var allocator = FATAllocator(profile: profile, clusterCount: clusterCount,
                                     scan: .fromLastAllocated)

        // Un volume émietté, construit comme il l'aurait été dans la vraie vie :
        // on remplit les trois premiers quarts de fichiers d'un cluster, puis on
        // en supprime un sur deux. Il ne reste plus un seul bloc de taille.
        var filler: [FileEntry] = []
        for index in 0..<(clusterCount * 3 / 4) {
            var file = FileEntry(id: index + 1,
                                 logicalSize: UInt64(profile.clusterBytes),
                                 hint: .normal)
            allocator.place(file: &file)
            filler.append(file)
        }
        for index in stride(from: 1, to: filler.count, by: 2) {
            allocator.release(file: &filler[index])
        }

        // Le dernier quart est intact : le fichier contraint doit y aller d'un
        // seul tenant.
        var pagefile = FileEntry(id: 10_000,
                                 logicalSize: UInt64(clusterCount / 8) * UInt64(profile.clusterBytes),
                                 hint: .reservedContiguous)
        allocator.place(file: &pagefile)
        #expect(pagefile.extents.count == 1)
        #expect(pagefile.extents.first!.start >= clusterCount * 3 / 4)

        // Le dernier quart n'a plus que 4 096 clusters d'un tenant. Un second
        // fichier contraint plus grand que cela ne peut plus l'être : il se
        // morcelle, mais il est écrit — c'est ce que faisait Windows quand il
        // n'avait plus le choix.
        let tooBig = clusterCount / 8 + 500
        var second = FileEntry(id: 10_001,
                               logicalSize: UInt64(tooBig) * UInt64(profile.clusterBytes),
                               hint: .reservedContiguous)
        allocator.place(file: &second)
        #expect(second.extents.count > 1)
        #expect(second.clusterCount == tooBig)
    }
}
