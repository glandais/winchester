import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce que le plan d'une partition doit dire, format par format.
///
/// C'est là que se joue la signature sonore d'une passe : sur FAT, valider un
/// déplacement écrit trois fois au tout début de la partition ; sur NTFS, un
/// enregistrement de la MFT et un bout de bitmap.
@Suite("Plan d'une partition")
struct PartitionGeometryTests {

    @Test("Une partition FAT16 se dimensionne comme FORMAT")
    func fat16Layout() {
        let partition = PartitionGeometry(startLBA: 0, sectors: 360_000,
                                          clusterSectors: 8, format: .fat16)
        #expect(partition.clusterCount > 0)
        #expect(partition.clusterCount < 65_525)
        // Les tables encadrent la racine, la zone de données vient après.
        #expect(partition.fat1LBA < partition.fat2LBA)
        #expect(partition.fat2LBA < partition.rootLBA)
        #expect(partition.rootLBA < partition.dataStartLBA)
        // Deux octets par cluster, arrondis au secteur.
        #expect(partition.fatSectors >= partition.clusterCount * 2 / 512)
        // Et tout cela tient dans les secteurs demandés.
        #expect(partition.totalSectors <= 360_000)
    }

    @Test("Une FAT32 décrit ses clusters sur quatre octets")
    func fat32Layout() {
        let sectors = 8_000_000
        let fat16 = PartitionGeometry(startLBA: 0, sectors: 400_000,
                                      clusterSectors: 8, format: .fat16)
        let fat32 = PartitionGeometry(startLBA: 0, sectors: sectors,
                                      clusterSectors: 8, format: .fat32)
        #expect(fat32.format.fatEntryBytes == 4)
        #expect(fat16.format.fatEntryBytes == 2)
        // Pas de racine de taille fixe : elle est un fichier comme un autre.
        #expect(fat32.rootSectorCount == 0)
        #expect(fat32.clusterCount > 65_524, "une FAT32 n'a pas la borne de FAT16")
    }

    @Test("Un volume NTFS n'a ni table d'allocation ni racine fixe")
    func ntfsLayout() {
        let partition = PartitionGeometry(startLBA: 0, sectors: 8_000_000,
                                          clusterSectors: 8, format: .ntfs)
        #expect(partition.fatSectors == 0)
        #expect(partition.rootSectorCount == 0)
        #expect(partition.dataStartLBA > partition.startLBA, "$Boot occupe le début")
    }

    /// L'écart qui s'entend : trois écritures au bord du plateau contre deux,
    /// dont une qui suit le fichier au lieu de revenir au début — plus, une
    /// validation sur huit, la page de journal (`LogFileTests`).
    @Test("Valider un déplacement coûte trois écritures sur FAT, deux sur NTFS")
    func commitCost() {
        let fat = PartitionGeometry(startLBA: 0, sectors: 400_000,
                                    clusterSectors: 8, format: .fat16)
        let ntfs = PartitionGeometry(startLBA: 0, sectors: 8_000_000,
                                     clusterSectors: 8, format: .ntfs)

        let fatCommit = fat.commitAccesses(forCluster: 20_000, fileIndex: 3, validation: 0)
        #expect(fatCommit.count == 3)
        // Toutes au tout début de la partition, avant la zone de données.
        for access in fatCommit {
            #expect(access.lba < fat.dataStartLBA,
                    "une validation FAT ramène le bras au bord du plateau")
        }

        let ntfsCommit = ntfs.commitAccesses(forCluster: 20_000, fileIndex: 3, validation: 0)
        #expect(ntfsCommit.count == 2)
    }

    @Test("Un cluster se traduit toujours en LBA de la zone de données")
    func clusterAddressing() {
        let partition = PartitionGeometry(startLBA: 128, sectors: 400_000,
                                          clusterSectors: 8, format: .fat16)
        #expect(partition.lba(ofCluster: 0) == partition.dataStartLBA)
        #expect(partition.lba(ofCluster: 10) == partition.dataStartLBA + 80)
        // Le dernier cluster reste dans la partition.
        let last = partition.lba(ofCluster: partition.clusterCount - 1) + partition.clusterSectors
        #expect(last <= partition.startLBA + partition.totalSectors)
    }
}

@Suite("Index des extents")
struct ExtentIndexTests {

    @Test("Un extent se retrouve depuis n'importe lequel de ses clusters")
    func lookup() {
        var index = ExtentIndex(clusterCount: 100_000)
        index.insert(Extent(start: 500, length: 10), file: 7)

        #expect(index.files(in: 500..<501) == [7])
        #expect(index.files(in: 509..<510) == [7])
        #expect(index.files(in: 495..<505) == [7])
        #expect(index.files(in: 510..<520).isEmpty)
        #expect(index.files(in: 490..<500).isEmpty)
    }

    /// Le cas qui casse une indexation naïve : un extent plus long qu'un bloc
    /// doit être trouvé depuis son milieu, pas seulement depuis son début.
    @Test("Un extent qui traverse plusieurs blocs reste trouvable partout")
    func spanningExtent() {
        var index = ExtentIndex(clusterCount: 1_000_000, targetBlocks: 64)
        let extent = Extent(start: 1_000, length: 200_000)
        index.insert(extent, file: 1)

        for probe: UInt32 in [1_000, 50_000, 150_000, 200_999] {
            #expect(index.files(in: probe..<(probe + 1)) == [1], "cluster \\(probe)")
        }
        #expect(index.files(in: 201_000..<201_100).isEmpty)
    }

    @Test("Retirer un extent le retire de tous ses blocs")
    func removal() {
        var index = ExtentIndex(clusterCount: 1_000_000, targetBlocks: 64)
        let extent = Extent(start: 1_000, length: 200_000)
        index.insert(extent, file: 1)
        index.remove(extent, file: 1)
        for probe: UInt32 in [1_000, 50_000, 200_999] {
            #expect(index.files(in: probe..<(probe + 1)).isEmpty, "cluster \\(probe)")
        }
    }

    @Test("Plusieurs fichiers sur la même plage sortent sans doublon")
    func multipleFiles() {
        var index = ExtentIndex(clusterCount: 100_000)
        index.insert(Extent(start: 100, length: 50), file: 1)
        index.insert(Extent(start: 120, length: 50), file: 2)
        index.insert(Extent(start: 400, length: 10), file: 1)

        let found = index.files(in: 100..<500)
        #expect(Set(found) == [1, 2])
        #expect(found.count == 2, "un fichier en deux extents n'est cité qu'une fois")
    }
}

/// Un fichier de test : sa catégorie, ses extents, et le droit d'y toucher.
private struct TestFile {
    let category: ClusterCategory
    let extents: [Extent]
    var movable = true
}

/// Un volume de test dont on choisit exactement le placement.
private func volume(clusterCount: Int, files: [TestFile]) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: .fat16)
    let records: [DefragFile] = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\DIR\\F\(position).DAT",
                   category: file.category, walkOrder: position,
                   extents: file.extents, isMovable: file.movable)
    }
    return DefragVolume(partition: partition, files: records)
}

/// La carte par cluster que le plan portait autrefois en clair, reconstruite
/// depuis les plages qu'il publie désormais.
///
/// Sur ces volumes de quelques milliers de clusters, c'est encore la façon la
/// plus directe de vérifier qu'aucun cluster ne se perd ni ne se recouvre — et
/// la dérouler ici plutôt que dans le modèle est précisément ce que le
/// changement visait : elle n'existe plus que pour les tests.
private func materialized(_ plan: DefragPlan) -> [UInt8] {
    var map = [UInt8](repeating: ClusterCategory.free.rawValue,
                      count: plan.partition.clusterCount)
    for run in plan.initialRuns {
        for cluster in Int(run.start)..<min(Int(run.end), map.count) { map[cluster] = run.category }
    }
    return map
}

@Suite("Planificateur de défragmentation")
struct DefragPlannerTests {

    /// Le résultat visible d'une passe : plus un seul fichier en morceaux.
    @Test("Une passe rend tous les fichiers contigus")
    func everythingEndsContiguous() {
        let input = volume(clusterCount: 1_000, files: [
            TestFile(category: .system,
                     extents: [Extent(start: 10, length: 5), Extent(start: 100, length: 5)]),
            TestFile(category: .document,
                     extents: [Extent(start: 20, length: 3), Extent(start: 60, length: 2),
                               Extent(start: 300, length: 4)]),
            TestFile(category: .application, extents: [Extent(start: 500, length: 20)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        #expect(plan.before.fragmentedFiles == 2)
        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.filesMoved > 0)
    }

    /// Et le résultat qu'on entend : tout est tassé contre le début, donc
    /// l'espace libre est d'un seul tenant à la fin.
    @Test("Une passe tasse le volume contre son début")
    func packingLeavesOneHole() {
        let input = volume(clusterCount: 1_000, files: [
            TestFile(category: .system,
                     extents: [Extent(start: 10, length: 5), Extent(start: 100, length: 5)]),
            TestFile(category: .document,
                     extents: [Extent(start: 20, length: 3), Extent(start: 300, length: 4)]),
            TestFile(category: .application, extents: [Extent(start: 500, length: 20)]),
        ])
        let plan = DefragPlanner.plan(volume: input)
        #expect(plan.after.freeHoles == 1, "l'espace libre doit finir d'un seul tenant")
        #expect(plan.before.freeHoles > 1)
    }

    /// Le fichier d'échange est ouvert par le système : il ne bouge pas, et
    /// c'est lui le bloc immobile au milieu de la carte.
    @Test("Un fichier immobile n'est jamais déplacé, et rien ne le recouvre")
    func immovableFileStaysPut() {
        let swap = Extent(start: 400, length: 50)
        let input = volume(clusterCount: 1_000, files: [
            TestFile(category: .system,
                     extents: [Extent(start: 10, length: 5), Extent(start: 900, length: 5)]),
            TestFile(category: .swap, extents: [swap], movable: false),
            TestFile(category: .application, extents: [Extent(start: 600, length: 300)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        // Aucune écriture ne tombe dans les clusters du fichier d'échange.
        let partition = plan.partition
        let swapStart = partition.lba(ofCluster: Int(swap.start))
        let swapEnd = partition.lba(ofCluster: Int(swap.end))
        for operation in plan.operations where operation.isWrite && operation.kind == .writeExtent {
            let overlaps = operation.lba < swapEnd && operation.lba + operation.sectors > swapStart
            #expect(!overlaps, "une écriture recouvre le fichier d'échange")
        }
    }

    /// L'invariant le plus fort : à aucun moment deux fichiers ne se partagent
    /// un cluster. On le vérifie en rejouant la carte, exactement comme le fait
    /// l'écran, puis en comptant ce qu'elle porte.
    @Test("Le volume d'arrivée porte autant de clusters qu'il en avait")
    func nothingIsLostOrOverlapped() {
        let files: [TestFile] = (0..<40).map { (index: Int) -> TestFile in
            let head: UInt32 = UInt32(index) * 40 + 5
            let tail: UInt32 = 1_000 + UInt32(index) * 20
            return TestFile(category: .document,
                            extents: [Extent(start: head, length: 4),
                                      Extent(start: tail, length: 3)])
        }
        let input = volume(clusterCount: 2_000, files: files)
        let occupiedBefore = 40 * 7

        let plan = DefragPlanner.plan(volume: input)
        var map = materialized(plan)
        #expect(map.filter { $0 != ClusterCategory.free.rawValue }.count == occupiedBefore)

        for operation in plan.operations {
            let range = Int(operation.mutationStart)..<Int(operation.mutationStart + operation.mutationCount)
            for index in range {
                let mutation = plan.mutations[index]
                let end = min(mutation.start + mutation.count, map.count)
                guard mutation.start < end else { continue }
                for cluster in mutation.start..<end { map[cluster] = mutation.category.rawValue }
            }
        }

        // Si deux fichiers s'étaient recouverts, ou si un morceau avait été
        // oublié en route, le compte ne tomberait pas juste.
        let occupiedAfter = map.filter { $0 != ClusterCategory.free.rawValue }.count
        #expect(occupiedAfter == occupiedBefore,
                "\(occupiedAfter) clusters occupés à l'arrivée contre \(occupiedBefore)")
        #expect(plan.after.fragmentedFiles == 0)
    }

    /// Un fichier déjà contigu et déjà à sa place ne coûte rien : c'est pour
    /// cela qu'une passe démarre dans le calme.
    @Test("Ce qui est déjà en place n'est pas touché")
    func alreadyInPlaceIsFree() {
        let input = volume(clusterCount: 1_000, files: [
            TestFile(category: .system, extents: [Extent(start: 0, length: 10)]),
            TestFile(category: .system, extents: [Extent(start: 10, length: 10)]),
            TestFile(category: .document,
                     extents: [Extent(start: 50, length: 5), Extent(start: 80, length: 5)]),
        ])
        let plan = DefragPlanner.plan(volume: input)
        #expect(plan.filesAlreadyInPlace == 2)
        #expect(plan.filesMoved == 1)
    }

    /// Chaque déplacement est validé : autant de séries d'écritures de
    /// métadonnées que de fichiers déplacés et d'évacuations.
    @Test("Chaque déplacement est suivi de sa validation")
    func everyMoveIsCommitted() {
        let input = volume(clusterCount: 1_000, files: [
            TestFile(category: .system,
                     extents: [Extent(start: 10, length: 5), Extent(start: 100, length: 5)]),
            TestFile(category: .document,
                     extents: [Extent(start: 20, length: 3), Extent(start: 300, length: 4)]),
            TestFile(category: .application, extents: [Extent(start: 500, length: 20)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        let commits = plan.operations.filter { $0.kind == .metadata }.count
        let moves = plan.filesMoved + plan.evacuations
        // Trois écritures par validation sur FAT, plus la réécriture finale.
        #expect(commits == moves * 3 + plan.partition.finalAccesses.count)
    }

    @Test("Toutes les opérations restent dans la partition")
    func operationsStayInBounds() {
        let files: [TestFile] = (0..<100).map { (index: Int) -> TestFile in
            TestFile(category: .document,
                     extents: [Extent(start: UInt32(index) * 40 + 3, length: 6)])
        }
        let input = volume(clusterCount: 5_000, files: files)
        let plan = DefragPlanner.plan(volume: input)
        let end = plan.partition.startLBA + plan.partition.totalSectors

        for operation in plan.operations {
            #expect(operation.lba >= plan.partition.startLBA, "LBA négatif")
            #expect(operation.lba + operation.sectors <= end, "opération hors partition")
            #expect(operation.sectors > 0)
        }
    }

    /// Les mutations de la carte sont désignées par une tranche du plan : leurs
    /// bornes doivent toutes être valides, sans quoi le rejeu visuel lirait à
    /// côté.
    @Test("Les tranches de mutations sont toutes dans les bornes")
    func mutationSlicesAreValid() {
        let files: [TestFile] = (0..<30).map { (index: Int) -> TestFile in
            let head: UInt32 = UInt32(index) * 60 + 7
            let tail: UInt32 = 1_000 + UInt32(index) * 10
            return TestFile(category: .churn,
                            extents: [Extent(start: head, length: 5),
                                      Extent(start: tail, length: 2)])
        }
        let input = volume(clusterCount: 2_000, files: files)
        let plan = DefragPlanner.plan(volume: input)

        for operation in plan.operations {
            #expect(operation.mutationStart >= 0)
            #expect(Int(operation.mutationStart + operation.mutationCount) <= plan.mutations.count)
        }
        for mutation in plan.mutations {
            #expect(mutation.start >= 0)
            #expect(mutation.start + mutation.count <= plan.partition.clusterCount)
        }
    }

    /// Le refactor qui a amené ce fichier visait la taille : un volume de
    /// plusieurs millions de clusters doit se planifier en temps raisonnable,
    /// et surtout sans coût quadratique. Dix mille fichiers sur deux millions
    /// de clusters, c'est l'ordre de grandeur d'un FAT32 de 1999.
    @Test("Un volume de deux millions de clusters se planifie sans s'effondrer")
    func largeVolumeStaysTractable() {
        let fileCount = 10_000
        let files: [TestFile] = (0..<fileCount).map { (index: Int) -> TestFile in
            let head: UInt32 = UInt32(index) * 150 + 11
            let tail: UInt32 = 1_000_000 + UInt32(index) * 90
            return TestFile(category: .document,
                            extents: [Extent(start: head, length: 40),
                                      Extent(start: tail, length: 20)])
        }
        let input = volume(clusterCount: 2_000_000, files: files)

        let start = Date()
        let plan = DefragPlanner.plan(volume: input)
        let elapsed = Date().timeIntervalSince(start)

        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.filesMoved > fileCount / 2)
        // Large, mais suffisant pour attraper un retour au coût quadratique :
        // la version par chaîne de clusters n'en voyait pas la fin.
        #expect(elapsed < 60, "\(elapsed) s pour \(fileCount) fichiers")
    }
}

/// La passe livrée, sur le volume qu'elle range réellement : un FAT16 de 180 Mo
/// vieilli par deux ans d'usage simulé. C'est le seul test qui parte d'un
/// volume qu'on n'a pas fabriqué pour l'occasion.
@Suite("Passe sur le volume livré")
struct AgedVolumeTests {

    private static func agedVolume() -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0,
                                          sectors: 180_000_000 / 512,
                                          clusterSectors: 8,
                                          format: .fat16)
        return VolumeFactory.agedWindows95(partition: partition, fill: 0.78).defragVolume()
    }

    @Test("Le volume vieilli est bien mité au départ, rangé à l'arrivée")
    func agedVolumeGetsPacked() {
        let plan = DefragPlanner.plan(volume: Self.agedVolume())

        // Deux ans d'usage laissent des fichiers en morceaux et un espace libre
        // criblé de trous — sans quoi il n'y aurait rien à défragmenter.
        #expect(plan.before.fragmentedFiles > 20)
        #expect(plan.before.freeHoles > 20)
        #expect(plan.before.fill > 0.7 && plan.before.fill < 0.85)

        #expect(plan.after.fragmentedFiles == 0)
        // Deux trous et non un seul : le fichier d'échange est immobile et
        // coupe l'espace libre en deux — ce qui est tassé devant lui, et la
        // fin du volume. C'est exactement le bloc qui ne bouge jamais sur la
        // carte du défragmenteur.
        #expect(plan.after.freeHoles == 2)
    }

    /// Le va-et-vient qui fait durer une passe : bien plus d'évacuations que de
    /// fichiers déplacés, et plus d'octets déplacés que le volume n'en porte.
    @Test("La passe évacue plus qu'elle ne déplace")
    func evacuationsDominate() {
        let plan = DefragPlanner.plan(volume: Self.agedVolume())
        #expect(plan.evacuations > plan.filesMoved)
        #expect(plan.movedBytes > plan.partition.capacityBytes * 3 / 4)
    }

    /// Le fichier d'échange est ouvert par Windows : il ne bouge pas, et tout
    /// est tassé autour de lui.
    @Test("Le fichier d'échange ne bouge pas")
    func swapStaysPut() {
        let volume = Self.agedVolume()
        let swapBefore = volume.files.filter { $0.category == .swap }.flatMap(\.extents)
        #expect(!swapBefore.isEmpty, "le volume vieilli doit avoir un fichier d'échange")

        let plan = DefragPlanner.plan(volume: volume)
        let partition = plan.partition
        for extent in swapBefore {
            let start = partition.lba(ofCluster: Int(extent.start))
            let end = partition.lba(ofCluster: Int(extent.end))
            for operation in plan.operations where operation.kind == .writeExtent {
                #expect(!(operation.lba < end && operation.lba + operation.sectors > start),
                        "une écriture passe sur le fichier d'échange")
            }
        }
    }
}

// MARK: - La passe NTFS

/// Un volume NTFS de test, dont on choisit exactement le placement.
private func ntfsVolume(clusterCount: Int, files: [TestFile],
                        mftZone: Range<UInt32>? = nil) -> DefragVolume {
    let partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                      clusterSectors: 8, format: .ntfs)
    let records: [DefragFile] = files.enumerated().map { position, file in
        DefragFile(id: UInt32(position), path: "\\Documents\\F\(position).dat",
                   category: file.category, walkOrder: position,
                   extents: file.extents, isMovable: file.movable)
    }
    return DefragVolume(partition: partition, files: records, mftZone: mftZone)
}

/// Ce que fait le défragmenteur de Windows XP, et surtout ce qu'il ne fait pas.
///
/// Les trois quarts de ces tests vérifient une **absence** : pas de tassage,
/// pas d'évacuation, pas de retour au bord du plateau. C'est bien là que se
/// joue la différence avec la passe de 1995, et c'est ce qui rend les huit
/// volumes NTFS de la galerie planifiables.
@Suite("Passe NTFS façon Windows XP")
struct WindowsXPStrategyTests {

    /// La règle `IsFragmented` de JKDefrag (`ALGO.md` §4.2) : ce qui compte
    /// est le nombre de morceaux que la tête doit aller chercher, pas le
    /// nombre d'extents que le système de fichiers a écrits. Deux extents qui
    /// se touchent bout à bout se lisent sans un seul seek.
    @Test("Deux fragments contigus ne comptent que pour un")
    func adjacentExtentsAreOneFragment() {
        let joined = DefragFile(id: 0, path: "\\A.dat", category: .document, walkOrder: 0,
                                extents: [Extent(start: 10, length: 4),
                                          Extent(start: 14, length: 6)],
                                isMovable: true)
        #expect(joined.fragmentCount == 1)
        #expect(joined.isContiguous)

        // Un seul cluster d'écart, et les deux morceaux redeviennent deux.
        let split = DefragFile(id: 0, path: "\\A.dat", category: .document, walkOrder: 0,
                               extents: [Extent(start: 10, length: 4),
                                         Extent(start: 15, length: 6)],
                               isMovable: true)
        #expect(split.fragmentCount == 2)
        #expect(!split.isContiguous)

        // Jointifs sur le plateau mais dans l'ordre inverse du fichier : la
        // tête lit le premier, puis revient en arrière chercher le second.
        // Deux morceaux, comme le comptent JKDefrag et UltraDefrag.
        let reversed = DefragFile(id: 0, path: "\\A.dat", category: .document, walkOrder: 0,
                                  extents: [Extent(start: 14, length: 6),
                                            Extent(start: 10, length: 4)],
                                  isMovable: true)
        #expect(reversed.fragmentCount == 2)
        #expect(!reversed.isContiguous)
    }

    /// Conséquence directe : un fichier décrit en deux extents jointifs ne
    /// donne aucun travail au défragmenteur, et n'est pas compté comme cassé.
    @Test("Un fichier en deux extents jointifs n'est pas défragmenté")
    func adjacentExtentsAreNotWorthMoving() {
        let input = ntfsVolume(clusterCount: 1_000, files: [
            TestFile(category: .document,
                     extents: [Extent(start: 500, length: 4), Extent(start: 504, length: 6)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        #expect(plan.before.fragmentedFiles == 0)
        #expect(plan.filesMoved == 0)
        #expect(plan.filesAlreadyInPlace == 1)
    }

    /// La zone MFT est libre dans la bitmap, et c'est le piège : sur un volume
    /// de 320 Go elle fait quarante gigaoctets d'un seul tenant, donc le plus
    /// grand trou disponible et de très loin. Un défragmenteur qui s'y range
    /// condamne la MFT à se fragmenter dès la création de fichier suivante.
    @Test("Un fichier réparé n'atterrit pas dans la zone réservée à la MFT")
    func theMftZoneIsNotAPlayground() {
        // Tout le volume est occupé sauf la zone MFT (100..<400) et un trou
        // juste assez grand à la fin.
        let input = ntfsVolume(clusterCount: 1_000, files: [
            TestFile(category: .system, extents: [Extent(start: 0, length: 100)]),
            TestFile(category: .application, extents: [Extent(start: 400, length: 480)]),
            TestFile(category: .document,
                     extents: [Extent(start: 880, length: 5), Extent(start: 900, length: 5)]),
        ], mftZone: 100..<400)
        let plan = DefragPlanner.plan(volume: input)

        #expect(plan.filesMoved == 1)
        for mutation in plan.mutations where mutation.category != .free {
            #expect(mutation.start >= 400 || mutation.start + mutation.count <= 100,
                    "un fichier a été écrit dans la zone réservée à la MFT")
        }
    }

    /// Sans zone déclarée — un volume FAT, ou un NTFS dont on ne sait rien —
    /// rien n'est interdit : le même fichier part dans le premier trou venu.
    @Test("Sans zone MFT déclarée, le placement reste libre")
    func withoutAnMftZoneNothingIsReserved() {
        let files = [
            TestFile(category: .system, extents: [Extent(start: 0, length: 100)]),
            TestFile(category: .application, extents: [Extent(start: 400, length: 480)]),
            TestFile(category: .document,
                     extents: [Extent(start: 880, length: 5), Extent(start: 900, length: 5)]),
        ]
        let free = DefragPlanner.plan(volume: ntfsVolume(clusterCount: 1_000, files: files))
        let fenced = DefragPlanner.plan(volume: ntfsVolume(clusterCount: 1_000, files: files,
                                                           mftZone: 100..<400))
        // Les deux réparent le fichier, mais pas au même endroit.
        #expect(free.filesMoved == 1)
        #expect(fenced.filesMoved == 1)
        let destination = { (plan: DefragPlan) in
            plan.mutations.first { $0.category == .document }?.start
        }
        #expect(destination(free) == 100)
        #expect(destination(fenced) != destination(free))
    }

    /// L'écran affichait une phrase codée en dur pour la stratégie de 1995 :
    /// sur une passe XP, elle annonçait que « la destination d'un fichier est
    /// presque toujours occupée » juste au-dessus d'un compteur à zéro. C'est
    /// désormais la stratégie qui commente ses propres chiffres.
    @Test("Chaque stratégie commente ses compteurs sans contredire l'écran")
    func eachStrategyNarratesItsOwnCounters() {
        let input = ntfsVolume(clusterCount: 2_000, files: [
            TestFile(category: .application, extents: [Extent(start: 900, length: 40)]),
            TestFile(category: .document,
                     extents: [Extent(start: 100, length: 5), Extent(start: 600, length: 5)]),
        ])
        let plan = DefragPlanner.plan(volume: input)
        let text = plan.strategy.summary(of: plan)

        #expect(plan.strategy.label == "Défragmenteur de Windows XP")
        #expect(plan.evacuations == 0)
        #expect(text.contains("n'évacue personne"))
        #expect(!text.contains("presque toujours occupée"),
                "la phrase de 1995 a resurgi sur une passe qui n'évacue rien")
        // Tout est réparé : l'écran n'a pas à parler de ce qui resterait.
        #expect(plan.after.fragmentedFiles == 0)
        #expect(!text.contains("restent en morceaux"))
    }

    /// Et le plan porte bien la stratégie qui l'a produit, y compris une fois
    /// allégé de ses opérations pour l'affichage.
    @Test("Un plan résumé garde l'outil qui l'a produit")
    func summarizedPlansKeepTheirStrategy() {
        let ntfs = DefragPlanner.plan(volume: ntfsVolume(clusterCount: 1_000, files: [
            TestFile(category: .document,
                     extents: [Extent(start: 100, length: 5), Extent(start: 600, length: 5)]),
        ]))
        #expect(ntfs.summarized().strategy.id == "windowsXP")
        #expect(ntfs.summarized().operations.isEmpty)
    }

    @Test("Un volume NTFS est confié au défragmenteur de Windows XP")
    func ntfsPicksTheXPStrategy() {
        #expect(DefragPlanner.strategy(for: .ntfs).id == "windowsXP")
        #expect(DefragPlanner.strategy(for: .fat16).id == "windows95")
        #expect(DefragPlanner.strategy(for: .fat32).id == "windows95")
    }

    /// Le point de départ : un fichier contigu n'est pas touché, même s'il est
    /// loin du début du volume. Sur `famille-2007` cela fait 11 976 fichiers
    /// qui ne coûtent pas une requête.
    @Test("Seuls les fichiers fragmentés sont touchés")
    func onlyFragmentedFilesMove() {
        let input = ntfsVolume(clusterCount: 2_000, files: [
            TestFile(category: .application, extents: [Extent(start: 900, length: 40)]),
            TestFile(category: .document,
                     extents: [Extent(start: 100, length: 5), Extent(start: 600, length: 5)]),
            TestFile(category: .system, extents: [Extent(start: 1_500, length: 10)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        #expect(plan.filesMoved == 1)
        #expect(plan.filesAlreadyInPlace == 2)
        #expect(plan.before.fragmentedFiles == 1)
        #expect(plan.after.fragmentedFiles == 0)
    }

    /// Ce qui distinguait l'outil de 2003 de celui de 1995, en un compteur :
    /// il n'a jamais délogé personne pour se faire de la place.
    @Test("La passe n'évacue personne")
    func noEvacuation() {
        let files: [TestFile] = (0..<30).map { (index: Int) -> TestFile in
            TestFile(category: .document,
                     extents: [Extent(start: UInt32(index) * 20 + 3, length: 4),
                               Extent(start: 1_000 + UInt32(index) * 20, length: 3)])
        }
        let plan = DefragPlanner.plan(volume: ntfsVolume(clusterCount: 3_000, files: files))
        #expect(plan.evacuations == 0)
        #expect(plan.after.fragmentedFiles == 0)
    }

    /// Le contre-exemple de la stratégie de 1995 : ce qui était déjà contigu
    /// reste exactement où il était, y compris à l'autre bout du volume. C'est
    /// pour cela qu'il n'y a pas trois cents gigaoctets à recopier.
    @Test("Un fichier contigu en fin de volume n'est pas ramené vers le début")
    func nothingIsPacked() {
        let far = Extent(start: 1_800, length: 50)
        let input = ntfsVolume(clusterCount: 2_000, files: [
            TestFile(category: .application, extents: [far]),
            TestFile(category: .document,
                     extents: [Extent(start: 10, length: 4), Extent(start: 500, length: 4)]),
        ])
        let plan = DefragPlanner.plan(volume: input)
        let partition = plan.partition
        let start = partition.lba(ofCluster: Int(far.start))
        let end = partition.lba(ofCluster: Int(far.end))

        for operation in plan.operations where operation.kind != .scan {
            #expect(!(operation.lba < end && operation.lba + operation.sectors > start),
                    "la passe a touché un fichier déjà contigu")
        }
    }

    /// La signature sonore, vérifiée là où elle se décide : une validation NTFS
    /// écrit l'enregistrement de MFT du fichier et un secteur de bitmap, pas
    /// trois fois au tout début de la partition.
    @Test("Valider un déplacement ne ramène pas le bras au cluster 0")
    func commitStaysAwayFromTheEdge() {
        let input = ntfsVolume(clusterCount: 200_000, files: [
            TestFile(category: .document,
                     extents: [Extent(start: 150_000, length: 8),
                               Extent(start: 180_000, length: 8)]),
        ])
        let plan = DefragPlanner.plan(volume: input)
        let commits = plan.operations.filter { $0.kind == .metadata && $0.phase == 1 }

        // Deux écritures par déplacement, et aucune dans le boot.
        #expect(commits.count == 2 * plan.filesMoved)
        for commit in commits {
            #expect(commit.lba >= plan.partition.dataStartLBA)
        }
        // Et la bitmap suit le cluster de destination : elle n'est pas au bord.
        #expect(commits.contains { $0.lba > plan.partition.dataStartLBA + 1_000 })
    }

    /// Déplacer des clusters reste une lecture suivie d'une écriture : le
    /// système de fichiers travaille par gros blocs, il ne fabrique pas la
    /// donnée.
    @Test("Chaque bloc déplacé est lu avant d'être écrit")
    func everyWriteHasItsRead() {
        let input = ntfsVolume(clusterCount: 200_000, files: [
            TestFile(category: .application,
                     extents: (0..<8).map { Extent(start: UInt32($0) * 10_000 + 50_000,
                                                   length: 2_000) }),
        ])
        let plan = DefragPlanner.plan(volume: input)
        let reads = plan.operations.filter { $0.kind == .readExtent }
        let writes = plan.operations.filter { $0.kind == .writeExtent }

        #expect(reads.count == writes.count)
        #expect(!reads.isEmpty)
        let readClusters = reads.reduce(0) { $0 + $1.sectors } / plan.partition.clusterSectors
        #expect(readClusters == 16_000, "tout le fichier est relu, et une seule fois")
    }

    /// Le bloc de déplacement est un réglage de l'outil, comme le tampon de
    /// 256 Ko l'est pour Windows 95 : c'est lui qui fixe le grain de la passe.
    @Test("La taille du bloc de déplacement fixe le nombre de requêtes")
    func moveBlockSizeDrivesTheRequestCount() {
        let input = ntfsVolume(clusterCount: 100_000, files: [
            TestFile(category: .application,
                     extents: [Extent(start: 50_000, length: 4_000),
                               Extent(start: 60_000, length: 4_000)]),
        ])
        // 8 000 clusters de 4 Ko, soit 32 Mo, en deux extents de 4 000 : huit
        // blocs de 4 Mo (1 024 clusters), cent vingt-six de 256 Ko (64
        // clusters) — un bloc ne chevauche jamais deux extents de la source.
        var big = WindowsXPStrategy()
        big.bufferBytes = 4 * 1024 * 1024
        var small = WindowsXPStrategy()
        small.bufferBytes = 256 * 1024

        let writes = { (plan: DefragPlan) in
            plan.operations.filter { $0.kind == .writeExtent }.count
        }
        #expect(writes(big.plan(volume: input)) == 8)
        #expect(writes(small.plan(volume: input)) == 126)
    }

    /// Le comportement qui a fait écrire « prévoyez 15 % d'espace libre » dans
    /// la documentation de l'époque : sans trou à la taille, le fichier reste
    /// en morceaux et finit dans le rapport de fin de passe.
    @Test("Faute de trou assez grand, le fichier reste en morceaux")
    func aFileWithNowhereToGoStaysPut() {
        // Deux fichiers remplissent le volume en damier : il ne reste que des
        // trous de deux clusters, et le fichier cassé en demande six.
        var occupied: [Extent] = []
        for index in stride(from: 0, to: 100, by: 4) {
            occupied.append(Extent(start: UInt32(index), length: 2))
        }
        let input = ntfsVolume(clusterCount: 100, files: [
            TestFile(category: .system, extents: occupied),
            TestFile(category: .document,
                     extents: [Extent(start: 2, length: 1), Extent(start: 6, length: 1)]),
        ])
        // Le fichier système est lui aussi fragmenté, mais bien trop gros pour
        // le moindre trou : personne ne bouge pour lui faire de la place.
        let plan = DefragPlanner.plan(volume: input)
        #expect(plan.evacuations == 0)
        #expect(plan.after.fragmentedFiles >= 1)
        #expect(plan.filesMoved < plan.before.fragmentedFiles)
    }

    /// Le fichier d'échange est ouvert par Windows, et la MFT ne se réorganise
    /// pas à chaud : le défragmenteur de XP les signalait et passait son
    /// chemin.
    @Test("Ni le fichier d'échange ni les métadonnées ne bougent")
    func swapAndMetadataAreLeftAlone() {
        let swap = [Extent(start: 100, length: 20), Extent(start: 300, length: 20)]
        let mft = [Extent(start: 4, length: 10), Extent(start: 500, length: 10)]
        let input = ntfsVolume(clusterCount: 2_000, files: [
            TestFile(category: .swap, extents: swap, movable: false),
            TestFile(category: .reserved, extents: mft),
            TestFile(category: .document,
                     extents: [Extent(start: 700, length: 4), Extent(start: 900, length: 4)]),
        ])
        let plan = DefragPlanner.plan(volume: input)

        #expect(plan.filesMoved == 1, "seul le document se défragmente")
        let partition = plan.partition
        for extent in swap + mft {
            let start = partition.lba(ofCluster: Int(extent.start))
            let end = partition.lba(ofCluster: Int(extent.end))
            for operation in plan.operations where operation.kind == .writeExtent {
                #expect(!(operation.lba < end && operation.lba + operation.sectors > start),
                        "une écriture passe sur un fichier intouchable")
            }
        }
    }

    /// Le même invariant que pour la passe FAT, et pour la même raison : si
    /// deux fichiers se recouvraient, le compte ne tomberait pas juste.
    @Test("Le volume d'arrivée porte autant de clusters qu'il en avait")
    func nothingIsLostOrOverlapped() {
        let files: [TestFile] = (0..<50).map { (index: Int) -> TestFile in
            TestFile(category: .document,
                     extents: [Extent(start: UInt32(index) * 30 + 9, length: 5),
                               Extent(start: 5_000 + UInt32(index) * 17, length: 6)])
        }
        let input = ntfsVolume(clusterCount: 20_000, files: files)
        let occupied = 50 * 11

        let plan = DefragPlanner.plan(volume: input)
        var map = materialized(plan)
        #expect(map.filter { $0 != ClusterCategory.free.rawValue }.count == occupied)

        for operation in plan.operations {
            for index in Int(operation.mutationStart)
                ..< Int(operation.mutationStart + operation.mutationCount) {
                let mutation = plan.mutations[index]
                let end = min(mutation.start + mutation.count, map.count)
                guard mutation.start < end else { continue }
                for cluster in mutation.start..<end { map[cluster] = mutation.category.rawValue }
            }
        }
        #expect(map.filter { $0 != ClusterCategory.free.rawValue }.count == occupied)
        #expect(plan.after.fragmentedFiles == 0)
    }

    @Test("Toutes les opérations restent dans la partition")
    func operationsStayInBounds() {
        let files: [TestFile] = (0..<200).map { (index: Int) -> TestFile in
            TestFile(category: .churn,
                     extents: [Extent(start: UInt32(index) * 100 + 7, length: 3),
                               Extent(start: 40_000 + UInt32(index) * 50, length: 2)])
        }
        let plan = DefragPlanner.plan(volume: ntfsVolume(clusterCount: 100_000, files: files))
        let end = plan.partition.startLBA + plan.partition.totalSectors

        for operation in plan.operations {
            #expect(operation.lba >= plan.partition.startLBA)
            #expect(operation.lba + operation.sectors <= end, "opération hors partition")
            #expect(operation.sectors > 0)
        }
    }

    /// L'ordre de grandeur réel : un volume de 320 Go, quatre-vingts millions
    /// de clusters, douze mille fichiers dont deux cents en morceaux. C'est le
    /// cas que la stratégie de 1995 ne savait pas planifier.
    @Test("Un volume de quatre-vingts millions de clusters se planifie en quelques secondes")
    func hugeVolumeStaysTractable() {
        var files: [TestFile] = (0..<12_000).map { (index: Int) -> TestFile in
            TestFile(category: .document,
                     extents: [Extent(start: UInt32(index) * 6_000 + 11, length: 200)])
        }
        files += (0..<250).map { (index: Int) -> TestFile in
            TestFile(category: .application,
                     extents: [Extent(start: 72_000_000 + UInt32(index) * 3_000, length: 500),
                               Extent(start: 76_000_000 + UInt32(index) * 3_000, length: 700)])
        }
        let input = ntfsVolume(clusterCount: 80_000_000, files: files)

        let start = Date()
        let plan = DefragPlanner.plan(volume: input)
        let elapsed = Date().timeIntervalSince(start)

        #expect(plan.filesMoved == 250)
        #expect(plan.filesAlreadyInPlace == 12_000)
        #expect(plan.after.fragmentedFiles == 0)
        // Deux cent cinquante fichiers de 4,8 Mo par blocs de 4 Mo : quelques
        // milliers de requêtes, contre vingt-huit millions pour un tassage.
        #expect(plan.operations.count < 20_000, "\(plan.operations.count) opérations")
        #expect(elapsed < 60, "\(elapsed) s")
    }
}

// MARK: - La défragmentation partielle

/// Un volume NTFS dont on choisit le placement, défragmenté par UltraDefrag.
///
/// Le seuil de fragment est donné en clusters plutôt qu'en octets : les 20 Mo
/// de `PART_DEFRAG_MAGIC_CONSTANT` feraient 5 120 clusters de 4 Ko, donc des
/// volumes de test d'un million de clusters pour vérifier une règle qui tient
/// en dix. La règle ne dépend pas de l'échelle, les tests non plus.
private func ultraPlan(clusterCount: Int, files: [TestFile],
                       thresholdClusters: UInt32 = 10,
                       mftZone: Range<UInt32>? = nil) -> DefragPlan {
    let volume = ntfsVolume(clusterCount: clusterCount, files: files, mftZone: mftZone)
    var strategy = UltraDefragStrategy()
    strategy.fragmentSizeThreshold = Int(thresholdClusters) * volume.partition.clusterBytes
    strategy.bufferBytes = 4 * 1024 * 1024
    return DefragPlanner.plan(volume: volume, using: strategy)
}

/// Ce que la défragmentation partielle d'UltraDefrag apporte, et ce qu'elle
/// coûte.
///
/// Elle répond à un échec que la passe de Windows XP ne sait pas traiter : un
/// gros fichier en morceaux sur un volume plein n'a plus aucun trou à sa
/// taille, donc XP le laisse tel quel. UltraDefrag ne cherche pas à le rendre
/// contigu — il recolle ses **petits** morceaux et laisse les gros où ils sont.
@Suite("Défragmentation partielle façon UltraDefrag")
struct UltraDefragStrategyTests {

    /// Le cas qui justifie l'outil, en dix clusters. Le fichier fait 35
    /// clusters — plus du double du seuil, donc « gros » — et le volume n'offre
    /// qu'un trou de 10. XP ne peut rien en faire ; UltraDefrag y recolle les
    /// trois éclats de tête et laisse le gros bloc où il est.
    @Test("Un gros fichier sans trou à sa taille voit ses petits morceaux recollés")
    func littleFragmentsAreMergedInPlace() {
        let plan = Self.crowdedVolume()

        // Windows XP : aucun trou de 35 clusters, le fichier reste tel quel.
        #expect(plan.xp.filesMoved == 0)
        #expect(plan.xp.after.fragments == 4)

        // UltraDefrag : les trois éclats et un cluster du gros bloc n'en font
        // plus qu'un. Le fichier reste fragmenté — il l'est en deux morceaux au
        // lieu de quatre, et c'est exactement ce que l'outil promet.
        #expect(plan.ultra.filesMoved == 1)
        #expect(plan.ultra.after.fragmentedFiles == 1, "le fichier n'est pas devenu contigu")
        #expect(plan.ultra.after.fragments == 2)
        // Et personne n'a été délogé pour cela.
        #expect(plan.ultra.evacuations == 0)
    }

    /// Un volume plein à ras bord, où le seul trou fait 10 clusters et le seul
    /// fichier cassé 35 : la situation de `famille-2007`, en cent clusters.
    static func crowdedVolume() -> (xp: DefragPlan, ultra: DefragPlan) {
        let files = [
            TestFile(category: .application, extents: [Extent(start: 0, length: 10)]),
            TestFile(category: .document, extents: [
                Extent(start: 10, length: 2),     // trois éclats,
                Extent(start: 14, length: 3),     // séparés par d'autres fichiers,
                Extent(start: 20, length: 4),     // et un gros bloc au bout
                Extent(start: 40, length: 26),
            ]),
            TestFile(category: .application, extents: [Extent(start: 12, length: 2)]),
            TestFile(category: .application, extents: [Extent(start: 17, length: 3)]),
            TestFile(category: .application, extents: [Extent(start: 24, length: 16)]),
            TestFile(category: .application, extents: [Extent(start: 66, length: 24)]),
        ]
        return (DefragPlanner.plan(volume: ntfsVolume(clusterCount: 100, files: files),
                                   using: WindowsXPStrategy()),
                ultraPlan(clusterCount: 100, files: files))
    }

    /// Le garde-fou `n < 2` : recoller un morceau tout seul, c'est le déplacer
    /// sans en supprimer un. UltraDefrag ne le fait pas, et c'est ce qui
    /// distingue une défragmentation partielle d'un brassage.
    ///
    /// Il se déclenche là où le plafond du plus grand trou coupe la suite après
    /// son premier élément : deux petits morceaux de 3 et 9 clusters, un trou
    /// de 10, et les recoller demanderait 12. La passe préfère ne rien faire.
    @Test("Un morceau isolé ne vaut pas le déplacement")
    func aLoneFragmentIsLeftAlone() {
        let plan = ultraPlan(clusterCount: 100, files: [
            TestFile(category: .application, extents: [Extent(start: 0, length: 10)]),
            // 32 clusters : « gros ». Deux petits morceaux, puis un gros bloc.
            TestFile(category: .document, extents: [Extent(start: 10, length: 3),
                                                    Extent(start: 20, length: 9),
                                                    Extent(start: 40, length: 20)]),
            TestFile(category: .application, extents: [Extent(start: 13, length: 7)]),
            TestFile(category: .application, extents: [Extent(start: 29, length: 11)]),
            TestFile(category: .application, extents: [Extent(start: 60, length: 30)]),
        ])
        #expect(plan.before.fragments == 3)
        #expect(plan.filesMoved == 0)
        #expect(plan.after.fragments == 3, "le fichier a été brassé pour rien")
        #expect(plan.operations.allSatisfy { $0.kind != .writeExtent })
    }

    /// L'ordre de `fragmented_files_compare` (`analyze.c:756`) : décroissant sur
    /// le nombre de morceaux, là où XP suit les numéros d'enregistrement de la
    /// MFT. Il ne décide de rien tant qu'il y a de la place pour tout le monde ;
    /// ici il n'y a qu'un trou, et les deux outils n'y mettent pas le même
    /// fichier.
    @Test("Le fichier le plus fragmenté passe en premier")
    func theWorstFileGoesFirst() {
        let files = [
            TestFile(category: .application, extents: [Extent(start: 0, length: 10)]),
            // Deux morceaux, et c'est le premier de la MFT.
            TestFile(category: .archive, extents: [Extent(start: 10, length: 3),
                                                   Extent(start: 20, length: 3)]),
            TestFile(category: .application, extents: [Extent(start: 13, length: 7)]),
            // Six morceaux d'un cluster : le pire du volume.
            TestFile(category: .document, extents: [Extent(start: 23, length: 1),
                                                    Extent(start: 25, length: 1),
                                                    Extent(start: 27, length: 1),
                                                    Extent(start: 29, length: 1),
                                                    Extent(start: 31, length: 1),
                                                    Extent(start: 33, length: 1)]),
            TestFile(category: .application, extents: [Extent(start: 24, length: 1),
                                                       Extent(start: 26, length: 1),
                                                       Extent(start: 28, length: 1),
                                                       Extent(start: 30, length: 1),
                                                       Extent(start: 32, length: 1)]),
            // Le seul trou du volume : six clusters, pas un de plus.
            TestFile(category: .application, extents: [Extent(start: 40, length: 60)]),
        ]
        let volume = ntfsVolume(clusterCount: 100, files: files)
        let firstServed = { (plan: DefragPlan) in
            plan.mutations.first { $0.category != .free }.map { ($0.start, $0.category) }
        }

        // UltraDefrag sert le fichier à six morceaux.
        let ultra = ultraPlan(clusterCount: 100, files: files)
        #expect(firstServed(ultra)?.0 == 34)
        #expect(firstServed(ultra)?.1 == .document)

        // XP sert celui que la MFT présente en premier, qui n'en a que deux.
        let xp = DefragPlanner.plan(volume: volume, using: WindowsXPStrategy())
        #expect(firstServed(xp)?.1 == .archive)

        // Et la même passe XP, rejouée dans l'ordre d'UltraDefrag, sert le
        // même fichier que lui : c'est l'ordre qui décide ici, pas le placement.
        var sorted = WindowsXPStrategy()
        sorted.order = .mostFragmented
        let reordered = DefragPlanner.plan(volume: volume, using: sorted)
        #expect(firstServed(reordered)?.1 == .document)
    }

    /// `move.c:719-727` : sur NTFS, les clusters qu'un déplacement quitte ne
    /// reviennent dans la liste des régions libres qu'au tour suivant, parce
    /// que Windows les tient pour temporairement alloués. Sur FAT, ils sont
    /// réutilisables aussitôt.
    ///
    /// Le fichier le plus fragmenté part en premier et libère, en quittant son
    /// dernier morceau, de quoi compléter un trou de quatre clusters en un trou
    /// de six. Le second fichier en veut six : sur FAT il les prend là, en bas
    /// du volume ; sur NTFS ce trou n'existe pas encore, et il part au fond.
    @Test("Sur NTFS, l'espace libéré n'est réutilisé qu'au tour suivant")
    func releasedSpaceWaitsForTheNextRoundOnNTFS() {
        let files = [
            TestFile(category: .application, extents: [Extent(start: 0, length: 10)]),
            // Trois morceaux : le premier servi.
            TestFile(category: .document, extents: [Extent(start: 10, length: 2),
                                                    Extent(start: 14, length: 2),
                                                    Extent(start: 18, length: 2)]),
            TestFile(category: .application, extents: [Extent(start: 12, length: 2)]),
            TestFile(category: .application, extents: [Extent(start: 16, length: 2)]),
            // Libre : [20, 24).
            // Deux morceaux, six clusters.
            TestFile(category: .archive, extents: [Extent(start: 24, length: 3),
                                                   Extent(start: 28, length: 3)]),
            TestFile(category: .application, extents: [Extent(start: 27, length: 1)]),
            TestFile(category: .application, extents: [Extent(start: 31, length: 29)]),
            // Libre : [60, 66), où part le premier fichier.
            TestFile(category: .application, extents: [Extent(start: 66, length: 24)]),
            // Libre : [90, 96).
        ]
        let archiveLandsAt = { (plan: DefragPlan) in
            plan.mutations.first { $0.category == .archive }?.start
        }

        let ntfs = ultraPlan(clusterCount: 96, files: files)
        #expect(archiveLandsAt(ntfs) == 90)
        #expect(ntfs.after.fragmentedFiles == 0)
        // Le bilan est pris une fois tout rendu : rien ne reste retenu.
        #expect(ntfs.after.fill == ntfs.before.fill)

        var strategy = UltraDefragStrategy()
        strategy.fragmentSizeThreshold = 10 * 4_096
        let fat = DefragPlanner.plan(volume: volume(clusterCount: 96, files: files), using: strategy)
        #expect(archiveLandsAt(fat) == 18)
        #expect(fat.after.fragmentedFiles == 0)
    }

    /// La première séquence de `defrag_sequence` a un seuil infini : tout
    /// fichier y est « petit » et se recopie d'un seul tenant. Un fichier sous
    /// le double du seuil passe donc par le même chemin que sur une passe XP,
    /// et ressort contigu.
    @Test("Un fichier assez petit est recopié d'un seul tenant")
    func smallFilesAreMovedWhole() {
        let plan = ultraPlan(clusterCount: 100, files: [
            TestFile(category: .application, extents: [Extent(start: 0, length: 10)]),
            TestFile(category: .document, extents: [Extent(start: 10, length: 4),
                                                    Extent(start: 20, length: 4)]),
            TestFile(category: .application, extents: [Extent(start: 14, length: 6)]),
        ])
        #expect(plan.filesMoved == 1)
        #expect(plan.after.fragmentedFiles == 0)
        #expect(plan.after.fragments == 0)
    }

    /// Ce qu'un déplacement partiel ne doit jamais casser : le fichier garde
    /// exactement sa taille, ses morceaux ne se recouvrent pas, et aucun ne
    /// sort du volume. C'est le seul endroit de la couche où une liste
    /// d'extents est coupée en son milieu.
    @Test("Un déplacement partiel conserve le fichier")
    func partialMovesPreserveTheFile() {
        let files: [TestFile] = (0..<30).map { index in
            let base = UInt32(index) * 30
            return TestFile(category: index.isMultiple(of: 2) ? .document : .application,
                            extents: [Extent(start: base, length: 2),
                                      Extent(start: base + 4, length: 3),
                                      Extent(start: base + 9, length: 1),
                                      Extent(start: base + 12, length: 18)])
        }
        let plan = ultraPlan(clusterCount: 1_200, files: files)

        // Rien ne se recouvre : chaque cluster écrit l'est par un seul fichier
        // à la fois, et les libérations suivent.
        var occupant = [Int](repeating: -1, count: 1_200)
        for mutation in plan.mutations {
            for cluster in mutation.start..<(mutation.start + mutation.count) {
                #expect(cluster < 1_200, "mutation hors du volume")
                occupant[cluster] = mutation.category == .free ? -1 : Int(mutation.category.rawValue)
            }
        }
        // Et la taille de chaque fichier est intacte.
        #expect(plan.before.fileCount == plan.after.fileCount)
        #expect(plan.after.fragments < plan.before.fragments)
        #expect(plan.evacuations == 0)
    }

    /// `adjust_move_at_once_parameter` (`analyze.c:90-117`) : le grain d'un
    /// déplacement suit la capacité du volume, parce qu'un volume plus gros est
    /// porté par un disque plus rapide. Les volumes NTFS de la galerie
    /// s'échelonnent de 39 à 312 Gio et couvrent donc trois paliers.
    @Test("Le bloc de déplacement suit la capacité du volume")
    func moveGranularityFollowsCapacity() {
        #expect(UltraDefragStrategy.moveAtOnce(capacityBytes: 4 << 30) == 256 * 1024)
        #expect(UltraDefragStrategy.moveAtOnce(capacityBytes: 40 << 30) == 4 << 20)
        #expect(UltraDefragStrategy.moveAtOnce(capacityBytes: 244 << 30) == 8 << 20)
        #expect(UltraDefragStrategy.moveAtOnce(capacityBytes: 312 << 30) == 16 << 20)
        #expect(UltraDefragStrategy.moveAtOnce(capacityBytes: 3 << 40) == 64 << 20)
    }

    /// La zone MFT est le plus grand trou du volume et elle est interdite :
    /// `largestGap` doit la sauter, sans quoi la passe partielle composerait
    /// des morceaux qu'aucun trou réel ne saurait accueillir.
    @Test("Le plus grand trou ignore la zone réservée à la MFT")
    func theLargestGapSkipsTheMftZone() {
        let files = [TestFile(category: .system, extents: [Extent(start: 0, length: 100)])]
        let free = ntfsVolume(clusterCount: 1_000, files: files)
        let fenced = ntfsVolume(clusterCount: 1_000, files: files, mftZone: 200..<900)

        #expect(DefragOperations.largestGap(in: free) == Extent(start: 100, length: 900))
        // Reste 100..<200 d'un côté, 900..<1000 de l'autre : deux fois cent.
        #expect(DefragOperations.largestGap(in: fenced)?.length == 100)
    }

    /// Les compteurs d'une passe UltraDefrag ne se lisent pas comme ceux d'une
    /// passe XP : « 242 fichiers déplacés, 158 encore fragmentés » n'est pas un
    /// échec, c'est la description exacte de ce que fait l'outil.
    @Test("La stratégie commente ses propres chiffres")
    func itNarratesItsOwnCounters() {
        let plan = Self.crowdedVolume().ultra
        let text = plan.strategy.summary(of: plan)

        #expect(plan.strategy.label == "UltraDefrag")
        #expect(text.contains("les plus abîmés"))
        #expect(text.contains("trop gros pour tenir ailleurs"),
                "la phrase doit dire pourquoi un fichier déplacé reste fragmenté")
    }

    /// L'outil d'époque reste celui du format : UltraDefrag est de 2018 et ne
    /// s'obtient que sur demande.
    @Test("UltraDefrag ne se choisit pas tout seul")
    func itIsNeverThePeriodTool() {
        #expect(DefragPlanner.strategy(for: .ntfs).id == "windowsXP")
        #expect(DefragPlanner.strategy(for: .fat32).id == "windows95")
        #expect(DefragPlanner.strategy(named: "ultraDefrag")?.label == "UltraDefrag")
        #expect(DefragPlanner.strategy(named: "myDefrag") == nil)
    }
}
