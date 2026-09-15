import Testing
import Foundation
@testable import DiskCore

// MARK: - Une histoire, indépendante du système de fichiers

/// Événement de système de fichiers, décrit en **octets** et non en clusters :
/// c'est ce qui permet de rejouer exactement la même histoire sur trois
/// formats dont les clusters font 4 ou 32 Ko.
enum FSEvent: Sendable {
    case create(id: UInt32, bytes: UInt64, hint: AllocationHint)
    case grow(id: UInt32, toBytes: UInt64)
    case delete(id: UInt32)
}

/// Une journée de développeur, celle qui fabrique le pire volume de tous :
/// une installation posée une fois, puis des cycles de compilation qui créent
/// et détruisent des centaines de fichiers objets, un fichier précompilé
/// réécrit à chaque passe, et quelques documents qui grossissent.
///
/// Le détail qui fait tout, et qu'il est facile de manquer : les suppressions
/// sont **entrelacées** avec les écritures. Un cycle qui créerait ses objets,
/// puis les supprimerait tous d'un coup, rouvrirait un grand espace contigu
/// et ne fragmenterait rien du tout. Dans la réalité le compilateur écrit
/// pendant que l'éditeur de liens lit, le fichier précompilé est refait au
/// milieu, et ce qui est écrit à ce moment-là tombe dans les trous encore
/// ouverts. La fragmentation ne vient pas de la distribution des tailles, elle
/// vient de cet ordre-là.
///
/// La séquence est construite **une seule fois** et rejouée telle quelle sur
/// les trois allocateurs : toute différence de résultat vient donc de la
/// stratégie de placement, et d'elle seule.
func developerHistory(seed: UInt64, volumeBytes: UInt64) -> [FSEvent] {
    var rng = SeededGenerator(seed: seed)
    var events: [FSEvent] = []
    events.reserveCapacity(40_000)
    var nextID: UInt32 = 1

    func newID() -> UInt32 { defer { nextID += 1 }; return nextID }

    // 1. Installation du système et des outils : écrit une fois, jamais touché.
    var installed: UInt64 = 0
    let installTarget = volumeBytes * 40 / 100
    while installed < installTarget {
        let bytes = UInt64(max(512, rng.logNormal(median: 60_000, sigma: 1.6)))
        events.append(.create(id: newID(), bytes: bytes, hint: .system))
        installed += bytes
    }

    // 2. Le fichier d'échange, posé d'un seul tenant au premier démarrage.
    events.append(.create(id: newID(), bytes: volumeBytes * 6 / 100, hint: .reservedContiguous))

    // 3. Une copie de travail : les sources, petites et nombreuses. En NTFS
    //    une bonne part d'entre elles ne touchera pas un seul cluster.
    var sources: [UInt32] = []
    for _ in 0..<1_500 {
        let id = newID()
        events.append(.create(id: id, bytes: UInt64(max(120, rng.logNormal(median: 3_000, sigma: 1.2))),
                              hint: .normal))
        sources.append(id)
    }

    // 4. Quelques documents, qui seront réenregistrés encore et encore.
    var documents: [UInt32] = []
    var documentSize: [UInt32: UInt64] = [:]
    for _ in 0..<40 {
        let id = newID()
        let bytes = UInt64(max(4_000, rng.logNormal(median: 25_000, sigma: 0.9)))
        events.append(.create(id: id, bytes: bytes, hint: .normal))
        documents.append(id)
        documentSize[id] = bytes
    }

    // 5. Le fichier précompilé de Visual C++ : 22 Mo refaits à chaque
    //    compilation. C'est le plus gros fragmenteur du lot — à chaque passe il
    //    cherche 22 Mo dans un volume qui n'a plus que des miettes.
    let pchBytes: UInt64 = 22 * 1_024 * 1_024
    var pchID = newID()
    events.append(.create(id: pchID, bytes: pchBytes, hint: .normal))

    var previousObjects: [UInt32] = []
    var binaries: [UInt32] = []

    // Ce que l'utilisateur accumule et ne supprime jamais : archives, versions
    // livrées, documentation. Le volume se remplit **pendant** l'histoire, et
    // c'est ce qui compte : les mêmes cycles de compilation sur un disque à
    // 60 % et sur un disque à 90 % ne produisent pas du tout le même volume.
    let keepsakeBytes = volumeBytes * 22 / 100
    let keepsakePerCycle = keepsakeBytes / 120

    // 6. Cent vingt cycles de compilation.
    for cycle in 0..<120 {
        var objects: [UInt32] = []

        func compile(_ count: Int) {
            for _ in 0..<count {
                let id = newID()
                events.append(.create(id: id,
                                      bytes: UInt64(max(1_000, rng.logNormal(median: 14_000, sigma: 1.1))),
                                      hint: .temporary))
                objects.append(id)
            }
        }

        // La moitié des objets du cycle précédent disparaît pendant que le
        // compilateur travaille : les trous s'ouvrent au milieu des écritures.
        let half = previousObjects.count / 2
        for id in previousObjects.prefix(half) { events.append(.delete(id: id)) }
        compile(60)
        for id in previousObjects.dropFirst(half) { events.append(.delete(id: id)) }

        // Le fichier précompilé est refait alors que le volume est au plus mité.
        events.append(.delete(id: pchID))
        pchID = newID()
        events.append(.create(id: pchID, bytes: pchBytes, hint: .normal))

        compile(60)

        // L'éditeur de liens écrit son exécutable dans ce qui reste.
        let binary = newID()
        events.append(.create(id: binary,
                              bytes: UInt64(max(100_000, rng.logNormal(median: 1_400_000, sigma: 0.6))),
                              hint: .normal))
        binaries.append(binary)
        // On ne garde que les deux dernières versions de l'exécutable.
        if binaries.count > 2 { events.append(.delete(id: binaries.removeFirst())) }

        // Un document réenregistré : Word réécrit en ajoutant à la fin.
        if cycle % 3 == 0, !documents.isEmpty {
            let id = documents[rng.index(below: documents.count)]
            let grown = (documentSize[id] ?? 25_000) + UInt64(max(500, rng.logNormal(median: 9_000, sigma: 1.0)))
            documentSize[id] = grown
            events.append(.grow(id: id, toBytes: grown))
        }

        // Des sources modifiées, donc supprimées et réécrites — dans les trous.
        for _ in 0..<10 where !sources.isEmpty {
            let index = rng.index(below: sources.count)
            events.append(.delete(id: sources[index]))
            let id = newID()
            events.append(.create(id: id,
                                  bytes: UInt64(max(120, rng.logNormal(median: 3_400, sigma: 1.2))),
                                  hint: .normal))
            sources[index] = id
        }

        // Un peu de patrimoine en plus à chaque cycle.
        events.append(.create(id: newID(),
                              bytes: UInt64(rng.uniform(0.7...1.3) * Double(keepsakePerCycle)),
                              hint: .normal))

        previousObjects = objects
    }

    return events
}

// MARK: - Rejeu

/// Rejoue une histoire sur un allocateur et rend les métriques finales. Les
/// fichiers sont conservés dans leur ordre de création : aucune mesure ne passe
/// par l'ordre d'itération d'un dictionnaire.
@discardableResult
func replay<A: Allocator>(_ events: [FSEvent], on allocator: inout A) -> (metrics: AllocationMetrics,
                                                                          files: [FileEntry],
                                                                          failures: Int) {
    var files: [UInt32: FileEntry] = [:]
    var order: [UInt32] = []
    order.reserveCapacity(events.count / 2)
    var failures = 0

    for event in events {
        switch event {
        case let .create(id, bytes, hint):
            var file = FileEntry(id: id, logicalSize: bytes, hint: hint)
            allocator.place(file: &file)
            if file.extents.isEmpty && !file.isResident {
                failures += 1
                continue
            }
            files[id] = file
            order.append(id)

        case let .grow(id, bytes):
            guard var file = files[id] else { continue }
            allocator.grow(file: &file, toLogicalSize: bytes)
            files[id] = file

        case let .delete(id):
            guard var file = files.removeValue(forKey: id) else { continue }
            allocator.release(file: &file)
        }
    }

    let live = order.compactMap { files[$0] }
    return (AllocationMetrics.evaluate(files: live,
                                       bitmap: allocator.bitmap,
                                       profile: allocator.profile),
            live,
            failures)
}

// MARK: - Le test comparatif

@Suite("Comparaison des systèmes de fichiers")
struct AllocatorComparisonTests {

    /// 512 Mo : assez pour que FAT16 impose des clusters de 32 Ko et que les
    /// trois volumes se remplissent aux deux tiers sur la même histoire.
    private static let volumeBytes: UInt64 = 512 * 1_024 * 1_024

    private static func volumes() -> (fat16: FATAllocator, fat32: FATAllocator, ntfs: NTFSAllocator) {
        let fat16Profile = FAT16Profile(clusterKB: 32)
        let fat16 = FATAllocator(profile: fat16Profile,
                                 clusterCount: UInt32(volumeBytes / UInt64(fat16Profile.clusterBytes)),
                                 scan: .fromVolumeStart)

        let fat32Profile = FAT32Profile(clusterKB: 4)
        let fat32 = FATAllocator(profile: fat32Profile,
                                 clusterCount: UInt32(volumeBytes / UInt64(fat32Profile.clusterBytes)),
                                 scan: .fromLastAllocated)

        let ntfsProfile = NTFSProfile(clusterKB: 4)
        let ntfs = NTFSAllocator(profile: ntfsProfile,
                                 clusterCount: UInt32(volumeBytes / UInt64(ntfsProfile.clusterBytes)))

        return (fat16, fat32, ntfs)
    }

    /// Le test central de la phase : une seule histoire, trois allocateurs,
    /// trois textures. Si ces écarts s'effaçaient, l'application n'aurait plus
    /// rien à montrer.
    @Test("La même histoire produit trois volumes différents")
    func divergence() {
        let events = developerHistory(seed: 1_996, volumeBytes: Self.volumeBytes)
        var (fat16, fat32, ntfs) = Self.volumes()

        let a = replay(events, on: &fat16)
        let b = replay(events, on: &fat32)
        let c = replay(events, on: &ntfs)

        print("""

        FAT16 32 Ko, scan depuis le début du volume
        \(a.metrics)

        FAT32 4 Ko, hint next-free
        \(b.metrics)

        NTFS 4 Ko, best-fit hors zone MFT
        \(c.metrics)
        MFT : \(ntfs.mft.clusterCount) clusters en \(ntfs.mft.extents.count) extents, \
        \(ntfs.mftRecordCount) enregistrements, zone entamée : \(ntfs.mftZoneBreached)

        """)

        // NTFS garde ses fichiers bien plus contigus que les deux FAT.
        #expect(c.metrics.fragmentedRatio < a.metrics.fragmentedRatio)
        #expect(c.metrics.fragmentedRatio < b.metrics.fragmentedRatio)
        #expect(c.metrics.meanExtentsPerFile < a.metrics.meanExtentsPerFile)

        // Le scan depuis le début rebouche les trous à l'instant où ils
        // s'ouvrent : les fichiers récents en paient le prix.
        #expect(a.metrics.fragmentedRatio > b.metrics.fragmentedRatio)

        // Rapporté aux seuls fichiers qui pouvaient être fragmentés, l'écart
        // entre les trois stratégies est bien plus net.
        #expect(c.metrics.fragmentedRatioAmongFragmentable
                < a.metrics.fragmentedRatioAmongFragmentable / 2)

        // Le slack de 1996 : des clusters de 32 Ko contre 4 Ko, un ordre de
        // grandeur de différence sur la place perdue. Sa valeur absolue dépend
        // de la population du volume — un développeur traîne de gros fichiers —
        // et se mesure sur un profil de petits fichiers, plus bas.
        #expect(a.metrics.slackRatio > b.metrics.slackRatio * 5)
        #expect(b.metrics.slackRatio < 0.12)
        #expect(c.metrics.slackRatio < 0.12)

        // NTFS garde de grands blocs libres là où les deux FAT n'ont plus que
        // des miettes : c'est la texture visible sur la carte des clusters.
        #expect(c.metrics.largestFreeRunClusters > a.metrics.largestFreeRunClusters * 2)

        // Et le scan depuis le début ne laisse presque aucun trou derrière lui,
        // là où le curseur next-free en sème des centaines.
        #expect(a.metrics.freeRunCount < b.metrics.freeRunCount / 10)

        // Seul NTFS loge les petits fichiers dans sa table de métadonnées.
        #expect(c.metrics.residentFileCount > 0)
        #expect(a.metrics.residentFileCount == 0)
        #expect(b.metrics.residentFileCount == 0)

        // Et seul NTFS tient une MFT, qui a grandi avec le nombre de fichiers.
        #expect(ntfs.mftRecordCount > 1_000)
        #expect(ntfs.mft.clusterCount > 1_000)
    }

    /// Le slack de l'époque, mesuré sur le profil qui en souffre : une
    /// secrétaire de 1996 et ses milliers de petits documents, sur un volume de
    /// 2 Go que `FORMAT` a découpé en clusters de 32 Ko. Un tiers du disque
    /// part en pure perte, et c'est *la* signature de l'année.
    @Test("Les clusters de 32 Ko de 1996 perdent un tiers du volume")
    func slackOfNineteenNinetySix() {
        var rng = SeededGenerator(seed: 1_996)
        var events: [FSEvent] = []
        var id: UInt32 = 0

        // Des documents Word 6, des modèles, des fichiers de configuration :
        // médiane de 25 Ko, la distribution du `.doc` de l'époque.
        for _ in 0..<6_000 {
            id += 1
            events.append(.create(id: id,
                                  bytes: UInt64(max(600, rng.logNormal(median: 25_000, sigma: 0.9))),
                                  hint: .normal))
        }

        // 2 000 Mo, et non 2 048 : au-delà de 65 524 clusters de 32 Ko, FAT16
        // doit passer à 64 Ko. C'est exactement là que se situait la limite des
        // « 2 Go » du format, et le calcul de FORMAT la retrouve tout seul.
        let volumeBytes: UInt64 = 2_000 * 1_024 * 1_024
        let fat16 = FAT16Profile.forVolume(bytes: volumeBytes)
        // C'est bien le calcul de FORMAT qui impose 32 Ko, pas une valeur posée
        // à la main.
        #expect(fat16.clusterBytes == 32 * 1_024)

        var dos = FATAllocator(profile: fat16,
                               clusterCount: UInt32(volumeBytes / UInt64(fat16.clusterBytes)),
                               scan: .fromVolumeStart)
        let fat32Profile = FAT32Profile(clusterKB: 4)
        var fat32 = FATAllocator(profile: fat32Profile,
                                 clusterCount: UInt32(volumeBytes / UInt64(fat32Profile.clusterBytes)),
                                 scan: .fromLastAllocated)

        let onFAT16 = replay(events, on: &dos)
        let onFAT32 = replay(events, on: &fat32)

        // La fourchette visée pour un profil secrétaire de 1996 : 30 à 40 % du
        // volume perdu à la fin des clusters.
        #expect(onFAT16.metrics.slackRatio > 0.28)
        #expect(onFAT16.metrics.slackRatio < 0.45)
        // Le même contenu, en FAT32, ne perd presque rien.
        #expect(onFAT32.metrics.slackRatio < 0.10)
        // Le même contenu occupe donc près d'un tiers de disque en plus : sur
        // un volume de 2 Go, c'est un demi-gigaoctet qui disparaît sans qu'un
        // seul fichier de plus ait été écrit.
        #expect(onFAT16.metrics.allocatedBytes > onFAT32.metrics.allocatedBytes * 13 / 10)
    }

    /// Le mécanisme le plus caractéristique de NTFS : tant que le volume reste
    /// sous le seuil, la zone MFT est intouchable et la MFT est d'un seul
    /// tenant. Passé le seuil, les données s'y installent, la MFT n'a plus de
    /// réserve et se fragmente à son tour. C'est pour cela qu'un NTFS plein se
    /// dégrade d'un coup et non progressivement.
    @Test("La zone MFT cède quand le volume se remplit, et la MFT se fragmente")
    func mftZoneYields() {
        let clusterCount: UInt32 = 262_144          // 1 Go en clusters de 4 Ko
        var rng = SeededGenerator(seed: 2_003)
        var allocator = NTFSAllocator(profile: NTFSProfile(clusterKB: 4),
                                      clusterCount: clusterCount)

        #expect(allocator.mftZoneIsProtected)
        #expect(allocator.mft.extents.count == 1)

        var files: [FileEntry] = []
        var id: UInt32 = 1
        var breachedAt: Double?

        // On remplit jusqu'à 96 % avec des fichiers de taille ordinaire.
        while allocator.bitmap.fill < 0.96 {
            var file = FileEntry(id: id,
                                 logicalSize: UInt64(max(2_000, rng.logNormal(median: 90_000, sigma: 1.3))),
                                 hint: .normal)
            id += 1
            allocator.place(file: &file)
            if file.extents.isEmpty && !file.isResident { break }
            files.append(file)
            if breachedAt == nil, allocator.mftZoneBreached {
                breachedAt = allocator.bitmap.fill
            }
        }

        // La zone n'a cédé qu'au voisinage du seuil annoncé, pas avant.
        guard let breachedAt else {
            Issue.record("la zone MFT n'a jamais cédé, à \(allocator.bitmap.fill * 100) % de remplissage")
            return
        }
        #expect(breachedAt > 0.80)
        #expect(!allocator.mftZoneIsProtected)

        // Et la MFT, privée de sa réserve, finit par se fragmenter.
        for _ in 0..<4_000 {
            allocator.noteFileCreated(logicalSize: 4_096)
        }
        #expect(allocator.mft.extents.count > 1)
    }

    /// Le fichier d'échange à taille fixe est le cas type du placement
    /// contraint : un seul extent, sur les trois systèmes.
    @Test("Un fichier à placement contraint reste d'un seul tenant")
    func reservedContiguousStaysWhole() {
        let events = developerHistory(seed: 42, volumeBytes: Self.volumeBytes)
        var (fat16, fat32, ntfs) = Self.volumes()

        for result in [replay(events, on: &fat16),
                       replay(events, on: &fat32),
                       replay(events, on: &ntfs)] {
            let reserved = result.files.filter { $0.hint == .reservedContiguous }
            #expect(reserved.count == 1)
            #expect(reserved.first?.extents.count == 1)
        }
    }

    /// Le retour au début du volume est ce qui distingue FAT32 de FAT16 : tant
    /// que le curseur avance, l'écriture est propre.
    @Test("Le curseur next-free finit par revenir au début")
    func fat32Wraps() {
        let events = developerHistory(seed: 7, volumeBytes: Self.volumeBytes)
        var (fat16, fat32, _) = Self.volumes()
        replay(events, on: &fat16)
        replay(events, on: &fat32)

        #expect(fat32.wrapCount > 0)
        // Le scan depuis le début ne revient jamais en arrière : il n'a jamais
        // avancé.
        #expect(fat16.wrapCount == 0)
    }

    /// Le déterminisme, mais au niveau qui compte : deux volumes construits à
    /// partir de la même graine doivent être identiques cluster par cluster.
    @Test("La même graine produit le même volume, sur les trois systèmes")
    func determinism() {
        let first = developerHistory(seed: 2_003, volumeBytes: Self.volumeBytes)
        let second = developerHistory(seed: 2_003, volumeBytes: Self.volumeBytes)

        var (a16, a32, ants) = Self.volumes()
        var (b16, b32, bnts) = Self.volumes()

        let ra = (replay(first, on: &a16), replay(first, on: &a32), replay(first, on: &ants))
        let rb = (replay(second, on: &b16), replay(second, on: &b32), replay(second, on: &bnts))

        #expect(ra.0.metrics == rb.0.metrics)
        #expect(ra.1.metrics == rb.1.metrics)
        #expect(ra.2.metrics == rb.2.metrics)

        // Les métriques peuvent coïncider par hasard : on compare aussi les
        // extents, fichier par fichier.
        #expect(ra.0.files.map(\.extents) == rb.0.files.map(\.extents))
        #expect(ra.1.files.map(\.extents) == rb.1.files.map(\.extents))
        #expect(ra.2.files.map(\.extents) == rb.2.files.map(\.extents))
        #expect(ants.mft.extents == bnts.mft.extents)
    }
}
