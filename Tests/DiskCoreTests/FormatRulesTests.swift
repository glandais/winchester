import Testing
import Foundation
@testable import DiskCore

/// Ce que l'outil de formatage de l'époque aurait décidé, et que rien n'a le
/// droit de contredire.
///
/// Trois des huit erreurs de fait du lot 2 étaient de la même famille : une
/// description de scénario qui affirmait, sur un point vérifiable, autre chose
/// que la règle. Les trois volumes de 1993 portaient des clusters de 8 Ko là où
/// `FORMAT` en donnait 4 ; `gamer-1999` des clusters de 4 Ko sur 8,2 Gio là où
/// la table FAT32 bascule à 8. Le modèle, lui, avait déjà raison : interrogé,
/// `FAT16Profile.forVolume` répondait bien 4 Ko.
///
/// Le filet n'est donc pas un test par correction, c'en est un seul : **aucune
/// description ne doit pouvoir contredire la règle de format**. La table
/// ci-dessous est écrite ici, indépendamment de celles du modèle, pour que le
/// test dise quelque chose — deux copies du même calcul ne prouveraient rien.
@Suite("Règles de formatage")
struct FormatRulesTests {

    /// Taille de cluster, en kilo-octets, telle que la publient les tables de
    /// `FORMAT` — et non telle que le modèle la calcule.
    ///
    /// - FAT16 : la plus petite puissance de deux qui fasse tenir le volume
    ///   sous les 65 524 entrées d'une table sur seize bits. La frontière
    ///   4 / 8 Ko tombe donc à 256 Mo, celle de 8 / 16 Ko à 512 Mo.
    /// - FAT32 : une table écrite en dur dans l'outil, qui double à chaque
    ///   puissance de deux à partir de 8 Gio.
    /// - NTFS : 4 Ko au-delà de 2 Gio, et c'est resté vrai jusqu'à 16 To.
    static func formatWouldChoose(kind: FileSystemKind, bytes: UInt64) -> UInt32 {
        let mebibyte: UInt64 = 1 << 20
        let gibibyte: UInt64 = 1 << 30
        switch kind {
        case .fat16, .vfat:
            switch bytes {
            case ..<(128 * mebibyte): return 2
            case ..<(256 * mebibyte): return 4
            case ..<(512 * mebibyte): return 8
            case ..<gibibyte:         return 16
            case ..<(2 * gibibyte):   return 32
            default:                  return 64
            }
        case .fat32:
            switch bytes {
            case ..<(8 * gibibyte):  return 4
            case ..<(16 * gibibyte): return 8
            case ..<(32 * gibibyte): return 16
            default:                 return 32
            }
        case .ntfs:
            switch bytes {
            case ..<(512 * mebibyte): return 1
            case ..<gibibyte:         return 1
            case ..<(2 * gibibyte):   return 2
            default:                  return 4
            }
        }
    }

    @Test("Aucune description ne contredit la table de FORMAT")
    func everyScenarioFollowsTheFormatTable() throws {
        for spec in try ScenarioLibrary.loadAll().sorted(by: { $0.id < $1.id }) {
            let chosen = spec.resolvedFileSystem().clusterBytes / 1_024
            let expected = Self.formatWouldChoose(kind: spec.fileSystem.type,
                                                  bytes: spec.disk.sizeBytes)
            let why = "\(spec.id) : \(spec.disk.sizeMB) Mo en \(spec.fileSystem.type.rawValue) "
                + "donnent des clusters de \(chosen) Ko, quand FORMAT en donnait \(expected)"
            #expect(chosen == expected, "\(why)")
        }
    }

    /// Le corollaire : une description qui ne dit rien de ses clusters doit
    /// retomber sur la même valeur qu'une description qui les impose. C'est ce
    /// qui autorise à retirer la clé des scénarios, et donc à ne plus pouvoir
    /// s'y tromper.
    @Test("La règle donne ce que la clé imposait, quand elle disait vrai")
    func silenceIsTheRule() throws {
        for spec in try ScenarioLibrary.loadAll() {
            var imposed = spec
            imposed.fileSystem.clusterKB = Self.formatWouldChoose(kind: spec.fileSystem.type,
                                                                  bytes: spec.disk.sizeBytes)
            #expect(imposed.resolvedFileSystem().clusterBytes
                    == spec.resolvedFileSystem().clusterBytes, "\(spec.id)")
        }
    }

    /// Les deux frontières que les erreurs E1 et E2 franchissaient, prises au
    /// plus près.
    @Test("Les frontières des deux tables sont à leur place")
    func tableBoundaries() {
        let mebibyte: UInt64 = 1 << 20
        let gibibyte: UInt64 = 1 << 30
        // FAT16 : 170 et 210 Mo sont sous 256 Mo, 340 Mo au-dessus.
        #expect(FAT16Profile.forVolume(bytes: 170 * mebibyte).clusterBytes == 4 * 1_024)
        #expect(FAT16Profile.forVolume(bytes: 210 * mebibyte).clusterBytes == 4 * 1_024)
        #expect(FAT16Profile.forVolume(bytes: 340 * mebibyte).clusterBytes == 8 * 1_024)
        // FAT32 : 6 400 Mo restent sous 8 Gio, 8 400 Mo — soit 8,20 Gio — non.
        #expect(FAT32Profile.forVolume(bytes: 6_400 * mebibyte).clusterBytes == 4 * 1_024)
        #expect(FAT32Profile.forVolume(bytes: 8_400 * mebibyte).clusterBytes == 8 * 1_024)
        #expect(FAT32Profile.forVolume(bytes: 20 * gibibyte).clusterBytes == 16 * 1_024)
        #expect(FAT32Profile.forVolume(bytes: 64 * gibibyte).clusterBytes == 32 * 1_024)
    }
}

/// Les métafichiers que `FORMAT` pose avant tout fichier, et l'époque qui les
/// déplace.
@Suite("Métafichiers NTFS")
struct NTFSMetafileTests {

    private static func allocator(clusterCount: UInt32,
                                  placement: NTFSAllocator.MirrorPlacement) -> NTFSAllocator {
        NTFSAllocator(profile: NTFSProfile(clusterKB: 4),
                      clusterCount: clusterCount,
                      mirrorPlacement: placement)
    }

    /// `$Boot` fait huit kilo-octets — deux clusters à 4 Ko —, et `$MFTMirr`
    /// n'est que la copie des **quatre premiers enregistrements** de la MFT,
    /// soit un seul cluster. Le modèle donnait l'inverse : un cluster pour
    /// `$Boot`, quatre pour le miroir.
    @Test("$Boot fait deux clusters, $MFTMirr un seul")
    func metafileSizes() {
        for placement in [NTFSAllocator.MirrorPlacement.nearStart, .volumeMiddle] {
            let ntfs = Self.allocator(clusterCount: 1_000_000, placement: placement)
            #expect(ntfs.bootExtent == Extent(start: 0, length: 2))
            #expect(ntfs.mftMirror.length == 1)
        }
    }

    /// « Près du début », c'est derrière `$Boot`. Posé à la frontière de la
    /// zone MFT, le miroir tombait à 12,5 % du volume — 31 Go du début sur un
    /// 250 Go —, c'est-à-dire ni au milieu ni près du début, et pile sur le
    /// premier cluster où les données ont le droit d'aller.
    @Test("Près du début, le miroir est derrière $Boot et non à la frontière de la zone")
    func mirrorNearStart() {
        let clusterCount: UInt32 = 64_000_000     // les 250 Go de `dev-2007`
        let ntfs = Self.allocator(clusterCount: clusterCount, placement: .nearStart)

        #expect(ntfs.mftMirror.start >= ntfs.bootExtent.end)
        #expect(ntfs.mftMirror.start <= 32,
                "le miroir est à \(ntfs.mftMirror.start), soit \(ntfs.mftMirror.start / 256) Mo du début")
        // Et il ne coupe plus en deux le premier cluster des données.
        #expect(ntfs.mftMirror.end <= ntfs.mftZone.lowerBound)
    }

    /// Au milieu, il y reste : c'est l'aller-retour par écriture de métadonnées
    /// qui a fait déplacer le miroir, et le modèle doit garder les deux
    /// époques.
    @Test("Au milieu du volume, le miroir est au milieu")
    func mirrorAtMiddle() {
        let clusterCount: UInt32 = 1_000_000
        let ntfs = Self.allocator(clusterCount: clusterCount, placement: .volumeMiddle)
        #expect(ntfs.mftMirror.start == clusterCount / 2)
    }

    /// Le déplacement accompagne NTFS 3.0, donc **Windows 2000**, et non XP.
    /// Aucun scénario embarqué ne démarre en 2000 : sans ce test, la borne
    /// pourrait redevenir 2001 sans que rien ne le dise.
    @Test("Le miroir remonte en 2000, pas en 2001")
    func mirrorMovesWithWindows2000() throws {
        let reference = try ScenarioLibrary.load("dev-2003")
        for (year, expected) in [(1999, NTFSAllocator.MirrorPlacement.volumeMiddle),
                                 (2000, .nearStart),
                                 (2001, .nearStart)] {
            var spec = reference
            spec.timeline = TimelineSpec(start: CivilDate(year: year, month: 1, day: 1),
                                         end: CivilDate(year: year + 1, month: 1, day: 1))
            let ntfs = DiskGenerator.ntfsAllocator(for: spec)
            let middle = ntfs.mftMirror.start == spec.clusterCount / 2
            #expect(middle == (expected == .volumeMiddle),
                    "un volume de \(year) pose son miroir en \(ntfs.mftMirror.start)")
        }
    }
}

/// Ce que le pilote sait du fichier qu'il écrit — c'est-à-dire rien.
@Suite("Le hint système sur FAT")
struct FATSystemHintTests {

    /// `FileCategory.systemCore.hint` vaut `.system`, et `systemCore` est la
    /// catégorie de toutes les DLL, de tous les pilotes et de tous les fichiers
    /// des vagues de mise à jour. Le pilote VFAT ou FAT32 ne connaît rien de
    /// tel : il sert son curseur `next-free`, pour tout le monde. Forcer le
    /// cluster 0 re-mitait le devant du volume en permanence — les 786
    /// `UPD*.DLL` de `gamer-1999` avaient une position moyenne à 1 % du volume.
    ///
    /// Seul le scan complet de MS-DOS repart du début, et pour tous ses
    /// fichiers, système ou non.
    @Test("Un fichier système ne retourne pas en tête de volume sur VFAT et FAT32",
          arguments: [FATAllocator.Scan.fromLastAllocated, .fromVolumeStart])
    func systemFilesFollowTheCursor(scan: FATAllocator.Scan) {
        let clusterCount: UInt32 = 20_000
        var allocator = FATAllocator(profile: FAT32Profile(clusterKB: 4),
                                     clusterCount: clusterCount,
                                     scan: scan)
        // Le volume se remplit à la suite, puis on rouvre un trou tout devant :
        // c'est la place qu'une mise à jour irait prendre.
        _ = allocator.allocate(clusterCount: 10_000, hint: .normal)
        allocator.free([Extent(start: 100, length: 200)])

        let placed = allocator.allocate(clusterCount: 8, hint: .system)
        #expect(!placed.isEmpty)
        if scan == .fromVolumeStart {
            #expect(placed[0].start == 100, "MS-DOS sert le premier trou venu, et celui-ci est devant")
        } else {
            #expect(placed[0].start >= 10_000,
                    "le curseur `next-free` est à 10 000 ; le fichier système est tombé en \(placed[0].start)")
        }
    }
}

/// Ce que le format pose devant la zone de données, déduit du volume.
@Suite("Place du format")
struct FormatOverheadTests {

    /// Le générateur et le simulateur décrivent le même volume : les clusters
    /// et leurs tables tiennent sur le disque décrit, sans un secteur de trop,
    /// et sans qu'il en reste assez pour un cluster de plus.
    @Test("Les clusters et leurs tables tiennent sur le disque")
    func clustersAndTablesFit() throws {
        for spec in try ScenarioLibrary.loadAll() {
            let sectors = Int(spec.disk.sizeBytes / 512)
            let clusterSectors = Int(spec.resolvedFileSystem().clusterBytes) / 512
            let count = Int(spec.clusterCount)
            let kind = spec.fileSystem.type
            let used = FormatOverhead.overheadSectors(clusterCount: count, kind: kind)
                + count * clusterSectors
            #expect(used <= sectors, "\(spec.id) : \(used) secteurs pour \(sectors)")
            let more = FormatOverhead.overheadSectors(clusterCount: count + 1, kind: kind)
                + (count + 1) * clusterSectors
            #expect(more > sectors, "\(spec.id) : un cluster de plus tenait")
            // Aucun profil du catalogue n'est tronqué par le plafond du format.
            #expect(spec.unclampedClusterCount == UInt64(count), "\(spec.id)")
        }
    }

    /// Le cas que la revue citait : 8,2 Gio en FAT32, dont les deux tables
    /// faisaient 17 Mo en clusters de 4 Ko — 8,4 Mo depuis que le lot 2 lui a
    /// rendu ses clusters de 8 Ko.
    @Test("Les deux tables de gamer-1999 ne sont plus des clusters")
    func gamer1999LosesItsTables() throws {
        let spec = try ScenarioLibrary.load("gamer-1999")
        let naive = spec.disk.sizeBytes / UInt64(spec.resolvedFileSystem().clusterBytes)
        let tables = 2 * FormatOverhead.tableSectors(clusterCount: Int(spec.clusterCount), kind: .fat32)
        #expect(tables * 512 > 8 << 20)
        #expect(naive - UInt64(spec.clusterCount) >= UInt64(tables * 512) / 8_192)
    }

    /// `$Bitmap` est posée derrière la zone MFT, et elle couvre le volume.
    @Test("La table d'occupation NTFS a sa place, derrière la zone MFT")
    func ntfsBitmapHasItsPlace() {
        let clusters: UInt32 = 1_000_000
        let ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: clusters)
        #expect(ntfs.volumeBitmap.start == ntfs.mftZone.upperBound)
        #expect(UInt64(ntfs.volumeBitmap.length) * 4_096 * 8 >= UInt64(clusters))
        #expect(ntfs.systemExtents.contains(ntfs.volumeBitmap))
        #expect(ntfs.bitmap.isAllocated(ntfs.volumeBitmap.start))
    }
}

/// Une commutation de tête est un basculement électronique suivi d'une
/// micro-correction d'asservissement : elle est toujours plus rapide qu'un
/// déplacement du bras, fût-il d'une seule piste.
@Suite("Commutation de tête")
struct HeadSwitchTests {

    /// La valeur de référence — 2,0 ms — n'était mise à l'échelle que par le
    /// facteur du seek **moyen**, jamais par le piste-à-piste, qui est appliqué
    /// après. Sur six des huit disques du catalogue, changer de tête coûtait
    /// donc plus cher que déplacer le bras d'une piste : 1,48 ms contre 0,95 sur
    /// un Barracuda ATA IV.
    @Test("Changer de tête coûte moins qu'un pas de piste, sur les huit disques")
    func headSwitchIsFasterThanATrackStep() {
        for drive in DriveCatalog.all {
            let seek = drive.seekModel
            let trackStep = seek.duration(distance: 1)
            print(String(format: "%@ (%d) — piste-à-piste %.2f ms, commutation %.2f ms",
                         drive.shortName, drive.year, trackStep * 1_000,
                         seek.headSwitchDuration * 1_000))
            let why = "\(drive.shortName) : commutation \(seek.headSwitchDuration * 1_000) ms "
                + "pour un pas de piste de \(trackStep * 1_000) ms"
            #expect(seek.headSwitchDuration < trackStep, "\(why)")
            // Et elle reste dans l'ordre de grandeur annoncé sur la période.
            #expect(seek.headSwitchDuration < 0.002_5)
        }
    }

    /// Elle décroît comme le piste-à-piste, et non comme la course complète de
    /// l'actionneur : deux disques de même seek moyen et de piste-à-piste
    /// différent n'ont pas la même commutation.
    @Test("Elle suit le piste-à-piste, pas le seek moyen")
    func headSwitchFollowsTrackToTrack() {
        let slow = SeekModel.calibrated(averageSeekMs: 9.0, trackToTrackMs: 3.0, cylinders: 4_000)
        let quick = SeekModel.calibrated(averageSeekMs: 9.0, trackToTrackMs: 1.0, cylinders: 4_000)
        #expect(quick.headSwitchDuration < slow.headSwitchDuration)
        #expect(abs(slow.headSwitchDuration / quick.headSwitchDuration - 3.0) < 0.01)
    }
}
