import Testing
import Foundation
@testable import DiskCore

/// Le lot 4 : des fichiers qui se fragmentent **pendant** qu'on les écrit, et
/// des répertoires qui existent.
///
/// Rien ici ne vise un taux de fragmentation. Les tests unitaires disent ce que
/// fait chaque mécanisme sur un volume de quelques centaines de clusters ; les
/// tests sur les profils de la galerie bornent la **forme** de ce qui en sort —
/// la traîne des fichiers en 2 à 16 morceaux —, aux valeurs mesurées quand le
/// lot a été écrit, pour qu'un retour en arrière se voie.
@Suite("Écrire sans connaître la taille, et les répertoires")
struct WritingWhileItGrowsTests {

    private static func vfat(clusters: UInt32 = 4_000) -> FATAllocator {
        FATAllocator(profile: FAT16Profile(clusterKB: 2), clusterCount: clusters, scan: .fromLastAllocated)
    }

    private static func streamed(_ id: UInt32, _ name: String, bytes: ByteCount,
                                 directory: UInt32 = 0) -> FileEvent {
        .create(FileSpec(id: id, name: name, directory: directory, category: .cache,
                         bytes: bytes, sizeKnownInAdvance: false))
    }

    // MARK: - Les paquets

    /// Sur FAT, un programme seul qui écrit cluster par cluster prend exactement
    /// ce qu'un appel unique aurait pris : chaque cluster est le premier libre
    /// après le curseur, et le curseur est là où le précédent l'a laissé. C'est
    /// ce qui permet à `FATAllocator.stream` de ne faire qu'un appel.
    @Test("Seul, un programme FAT prend cluster par cluster ce qu'un appel unique aurait pris")
    func fatStreamingAloneIsOneCall() {
        var holes = Self.vfat(clusters: 600)
        // Un volume mité : un cluster sur trois libre dans la première moitié.
        holes.claim(Extent(start: 0, length: 300))
        for cluster in stride(from: UInt32(0), to: 300, by: 3) { holes.free([Extent(start: cluster, length: 1)]) }

        var whole = holes
        var oneCall = FileEntry(id: 1, logicalSize: 0)
        #expect(whole.stream(file: &oneCall, clusters: 150))

        var packets = holes
        var byCluster = FileEntry(id: 1, logicalSize: 0)
        for _ in 0..<150 { #expect(packets.extend(file: &byCluster, byClusters: 1)) }

        #expect(oneCall.extents == byCluster.extents)
        #expect(oneCall.extents.count > 1)
    }

    /// Le paquet est une propriété du format : un cluster sur FAT, où le
    /// pilote prolonge la chaîne à chaque écriture ; 64 Ko sur NTFS, ce que le
    /// gestionnaire de cache vide d'un coup.
    @Test("Le paquet d'écriture : un cluster sur FAT, 64 Ko sur NTFS")
    func ntfsPacketIsSixtyFourKilobytes() {
        let profile = NTFSProfile(clusterKB: 4)
        #expect(profile.writePacketClusters == 16)
        #expect(FAT32Profile(clusterKB: 4).writePacketClusters == 1)
        #expect(FAT16Profile(clusterKB: 32).writePacketClusters == 1)
    }

    /// Tout ou rien, comme `extend` : un paquet qui ne trouve pas de place
    /// rend ce que les précédents avaient pris.
    @Test("Une écriture par paquets qui manque de place rend tout ce qu'elle avait pris")
    func failedStreamGivesBackEverything() {
        var allocator = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 2_000)
        let free = allocator.bitmap.freeCount
        var file = FileEntry(id: 1, logicalSize: 0)
        #expect(!allocator.stream(file: &file, clusters: free + 10))
        #expect(file.extents.isEmpty)
        #expect(allocator.bitmap.freeCount == free)
    }

    // MARK: - L'entrelacement

    /// Deux programmes qui écrivent le même jour sans connaître leur taille se
    /// disputent le curseur de VFAT : leurs clusters alternent, un à un.
    @Test("Deux programmes du même jour écrivent des chaînes alternées")
    func twoProgramsInterleave() throws {
        var timeline = EventTimeline()
        timeline.append(Self.streamed(0, "A.DAT", bytes: 20 * 2_048), on: 1, by: .browser)
        timeline.append(Self.streamed(1, "B.DAT", bytes: 20 * 2_048), on: 1, by: .download)
        var simulator = Simulator(allocator: Self.vfat())
        let outcome = try simulator.run(timeline)
        let a = try #require(outcome.catalog[0])
        let b = try #require(outcome.catalog[1])
        #expect(a.extents.count == 20)
        #expect(b.extents.count == 20)
        #expect(a.extents.allSatisfy { $0.length == 1 })
        #expect(a.extents[0].start + 1 == b.extents[0].start)
    }

    /// Le même jour, mais sous MS-DOS : un programme à la fois, dans l'ordre où
    /// la journée a été écrite.
    @Test("Sous MS-DOS, rien ne s'entrelace")
    func singleTaskingDoesNotInterleave() throws {
        var timeline = EventTimeline()
        timeline.append(Self.streamed(0, "A.DAT", bytes: 20 * 2_048), on: 1, by: .browser)
        timeline.append(Self.streamed(1, "B.DAT", bytes: 20 * 2_048), on: 1, by: .download)
        var simulator = Simulator(allocator: Self.vfat(), concurrent: false)
        let outcome = try simulator.run(timeline)
        #expect(outcome.catalog[0]?.extents == [Extent(start: 0, length: 20)])
        #expect(outcome.catalog[1]?.extents == [Extent(start: 20, length: 20)])
    }

    /// Un programme écrit ses fichiers l'un après l'autre : deux fichiers du
    /// même programme ne s'entrelacent pas, même écrits par paquets.
    @Test("Deux fichiers du même programme ne s'entrelacent pas")
    func oneProgramWritesInSequence() throws {
        var timeline = EventTimeline()
        timeline.append(Self.streamed(0, "A.DAT", bytes: 20 * 2_048), on: 1, by: .browser)
        timeline.append(Self.streamed(1, "B.DAT", bytes: 20 * 2_048), on: 1, by: .browser)
        var simulator = Simulator(allocator: Self.vfat())
        let outcome = try simulator.run(timeline)
        #expect(outcome.catalog[0]?.extents.count == 1)
        #expect(outcome.catalog[1]?.extents.count == 1)
    }

    /// Un fichier dont la taille est déclarée prend sa place en une fois, au
    /// tour de son programme : il ne se laisse pas entrelacer.
    @Test("Un fichier déclaré se pose d'un bloc, même au milieu d'une écriture par paquets")
    func declaredFileIsAtomic() throws {
        var timeline = EventTimeline()
        // Le navigateur a la main avant le jeu (`Program`) : il prend son
        // premier paquet, le jeu pose sa sauvegarde d'un bloc, le navigateur
        // finit derrière elle.
        timeline.append(Self.streamed(0, "A.DAT", bytes: 20 * 2_048), on: 1, by: .browser)
        timeline.append(.create(FileSpec(id: 1, name: "B.SAV", directory: 0, category: .document,
                                         bytes: 20 * 2_048)), on: 1, by: .game)
        var simulator = Simulator(allocator: Self.vfat())
        let outcome = try simulator.run(timeline)
        #expect(outcome.catalog[1]?.extents == [Extent(start: 1, length: 20)])
        #expect(outcome.catalog[0]?.extents == [Extent(start: 0, length: 1), Extent(start: 21, length: 19)])
    }

    /// Rien ne se tire au sort, ni dans les paquets ni dans les répertoires :
    /// deux générations du même profil posent les mêmes clusters aux mêmes
    /// fichiers et aux mêmes répertoires.
    @Test("Deux générations du même profil donnent le même volume, au cluster près",
          arguments: ["secretaire-1999", "secretaire-2003"])
    func generationIsDeterministic(id: String) throws {
        let spec = try ScenarioLibrary.load(id)
        let first = try DiskGenerator.generate(spec)
        let second = try DiskGenerator.generate(spec)
        #expect(first.catalog.files.map(\.extents) == second.catalog.files.map(\.extents))
        #expect(first.catalog.directories.map(\.extents) == second.catalog.directories.map(\.extents))
        #expect(first.systemExtents == second.systemExtents)
        #expect(first.bitmap.usedCount == second.bitmap.usedCount)
    }

    // MARK: - La forme de la distribution

    /// La traîne : la part des fichiers de plus d'un cluster qui sont en 2 à 16
    /// morceaux. C'est sur NTFS qu'elle se remplit — sur FAT, un programme seul
    /// prend par paquets les mêmes clusters qu'en une fois. Avant le lot, 1,9 %
    /// sur `secretaire-2003` et 1,0 % sur `gamer-2007` ; au lot, 10,3 et 4,5 %.
    /// Les bornes sont en dessous de ce que le lot mesure, bien au-dessus de ce
    /// qu'il y avait avant.
    @Test("Sur un NTFS vieilli, la traîne des fichiers en 2 à 16 morceaux existe",
          arguments: [("secretaire-2003", 0.07), ("gamer-2007", 0.03)])
    func tailIsPopulated(id: String, share: Double) throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load(id))
        let tail = disk.catalog.files.filter { (2...16).contains($0.extents.count) }.count
        let measured = Double(tail) / Double(disk.metrics.fragmentableFileCount)
        print(String(format: "%@ — %d fichiers en 2 à 16 morceaux, %.1f %% des fragmentables",
                     id, tail, measured * 100))
        #expect(measured > share)
    }

    // MARK: - Les répertoires

    /// VFAT consomme une entrée par tranche de treize caractères du nom long,
    /// plus celle du nom court.
    @Test("Un nom long coûte ses entrées sur VFAT, une seule sous MS-DOS")
    func longNamesCostEntries() {
        let vfat = DirectoryFormat(kind: .fat(longNames: true, fixedRoot: true), clusterBytes: 32_768)
        let dos = DirectoryFormat(kind: .fat(longNames: false, fixedRoot: true), clusterBytes: 32_768)
        #expect(vfat.entryBytes(forName: "Rapport trimestriel 1996.doc") == 4 * 32)
        #expect(dos.entryBytes(forName: "RAPPORT.DOC") == 32)
        #expect(vfat.entryBytes(forName: "RAPPORT.DOC") == 32)
        // Une minuscule suffit : Windows 95 garde la casse dans un nom long.
        #expect(vfat.entryBytes(forName: "index.dat") == 2 * 32)
        #expect(!DirectoryFormat.isShortName("TROPLONGNOM.DOC", caseSensitive: true))
        #expect(!DirectoryFormat.isShortName("A.DOCX", caseSensitive: true))
        #expect(!DirectoryFormat.isShortName("A B.DOC", caseSensitive: true))
        #expect(DirectoryFormat.isShortName("~WRD0000.TMP", caseSensitive: true))

        // NTFS : une entrée d'index par nom, et une seconde pour le nom court
        // quand le nom n'en est pas un.
        let ntfs = DirectoryFormat(kind: .ntfs, clusterBytes: 4_096, residentBytes: 700)
        #expect(ntfs.entryBytes(forName: "WINWORD.EXE") == 104)
        #expect(ntfs.entryBytes(forName: "Rapport trimestriel 1996.doc") == 144 + 112)
    }

    /// Un répertoire FAT naît avec un cluster, grandit d'un cluster quand ses
    /// entrées débordent — là où le curseur en est, loin du premier —, et ne
    /// rend rien quand ses fichiers disparaissent.
    @Test("Un répertoire FAT grandit par clusters, se fragmente, et ne rétrécit pas")
    func fatDirectoryGrowsAndFragments() throws {
        var catalog = FileCatalog()
        let folder = catalog.makeDirectory(path: "\\DOSSIER")
        var timeline = EventTimeline()
        // 2 Ko par cluster : 64 entrées. `.` et `..`, puis 100 noms courts.
        for index in 0..<100 {
            timeline.append(.create(FileSpec(id: UInt32(index), name: "F\(index).TXT", directory: folder,
                                             category: .document, bytes: 1_000)), on: 0)
        }
        for index in 0..<100 { timeline.append(.delete(id: UInt32(index)), on: 1) }
        let format = DirectoryFormat(kind: .fat(longNames: true, fixedRoot: true), clusterBytes: 2_048)
        var simulator = Simulator(allocator: Self.vfat(), catalog: catalog, directories: format)
        let outcome = try simulator.run(timeline)

        let directory = outcome.catalog.directories[Int(folder)]
        #expect(directory.exists)
        #expect(directory.entry.clusterCount == 2)
        #expect(directory.extents.count == 2)
        #expect(directory.entryBytes == 64)
        #expect(directory.peakEntryBytes == 64 + 100 * 32)
        // La racine de FAT16 vit hors de la zone de données.
        #expect(outcome.catalog.directories[0].extents.isEmpty)
    }

    /// Sur NTFS l'index d'un petit répertoire tient dans son enregistrement ;
    /// il n'en sort, et ne prend des clusters par tampons de 4 Ko, que quand
    /// il grossit.
    @Test("Un index NTFS reste dans son enregistrement tant qu'il est petit")
    func ntfsIndexLeavesItsRecord() throws {
        var catalog = FileCatalog()
        let small = catalog.makeDirectory(path: "\\Petit")
        let large = catalog.makeDirectory(path: "\\Grand")
        var timeline = EventTimeline()
        for index in 0..<3 {
            timeline.append(.create(FileSpec(id: UInt32(index), name: "F\(index).TXT", directory: small,
                                             category: .document, bytes: 10_000)), on: 0)
        }
        for index in 3..<203 {
            timeline.append(.create(FileSpec(id: UInt32(index), name: "Fichier numéro \(index).txt",
                                             directory: large, category: .document, bytes: 10_000)), on: 0)
        }
        let format = DirectoryFormat(kind: .ntfs, clusterBytes: 4_096, residentBytes: 700)
        var simulator = Simulator(allocator: NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: 20_000),
                                  catalog: catalog, directories: format)
        let outcome = try simulator.run(timeline)
        #expect(outcome.catalog.directories[Int(small)].exists)
        #expect(outcome.catalog.directories[Int(small)].extents.isEmpty)
        #expect(outcome.catalog.directories[Int(large)].entry.clusterCount > 1)
    }

    /// Sur un vrai profil : les répertoires existent sur le disque, certains
    /// en plusieurs clusters, et ceux-là en plusieurs morceaux.
    ///
    /// `famille-1999` en compte **761** — un dossier par séance d'import de
    /// MP3, quatre pour le cache du navigateur — et non « plusieurs milliers » :
    /// le générateur ne pose que 3 600 fichiers sur ce volume, là où un vrai
    /// Windows 98 en porte dix fois plus, et les installeurs y rangent chaque
    /// groupe de fichiers dans un seul dossier. Les répertoires manquants sont
    /// ceux des fichiers manquants.
    @Test("Un volume FAT32 vieilli a ses répertoires sur le disque, et en morceaux")
    func agedFATHasDirectories() throws {
        let disk = try DiskGenerator.generate(try ScenarioLibrary.load("famille-1999"))
        let existing = disk.catalog.directories.filter(\.exists)
        let multi = existing.filter { $0.entry.clusterCount > 1 }
        let fragmented = existing.filter { $0.extents.coalesced().count > 1 }
        print("famille-1999 — \(existing.count) répertoires, \(multi.count) en plusieurs clusters, "
              + "\(fragmented.count) en morceaux")
        #expect(existing.count > 500)
        #expect(multi.count >= 10)
        #expect(fragmented.count >= 10)
        // La racine d'un FAT32 est un fichier comme les autres, posée au
        // premier cluster au formatage.
        #expect(disk.catalog.directories[0].extents.first?.start == 0)
        // Et la bitmap les tient occupés.
        for directory in existing { for extent in directory.extents { #expect(disk.bitmap.isAllocated(extent.start)) } }
    }
}
