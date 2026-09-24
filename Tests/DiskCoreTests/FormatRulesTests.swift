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
                                  formatting: NTFSAllocator.Formatting) -> NTFSAllocator {
        NTFSAllocator(profile: NTFSProfile(clusterKB: 4),
                      clusterCount: clusterCount,
                      formatting: formatting)
    }

    /// `$Boot` fait huit kilo-octets — deux clusters à 4 Ko —, et `$MFTMirr`
    /// n'est que la copie des **quatre premiers enregistrements** de la MFT,
    /// soit un seul cluster. Le modèle donnait l'inverse : un cluster pour
    /// `$Boot`, quatre pour le miroir.
    @Test("$Boot fait deux clusters, $MFTMirr un seul")
    func metafileSizes() {
        for formatting in [NTFSAllocator.Formatting.nt, .xp, .vista, .win7] {
            let ntfs = Self.allocator(clusterCount: 1_000_000, formatting: formatting)
            #expect(ntfs.bootExtent == Extent(start: 0, length: 2))
            #expect(ntfs.mftMirror.length == 1)
        }
    }

    /// Depuis XP, `$MFT` est à 3 Gio du début du volume — LCN 786 432 en
    /// clusters de 4 Ko —, et les données ordinaires se posent devant elle.
    /// Sous NT elle est en tête, derrière `$Boot`.
    @Test("$MFT est à 3 Gio depuis XP, en tête sous NT")
    func mftAtThreeGibibytes() {
        let clusterCount: UInt32 = 64_000_000     // les 250 Go de `dev-2007`
        for formatting in [NTFSAllocator.Formatting.xp, .vista, .win7] {
            let ntfs = Self.allocator(clusterCount: clusterCount, formatting: formatting)
            #expect(ntfs.mft.extents[0].start == 786_432, "\(formatting)")
            // Un premier fichier se pose devant la MFT, pas derrière sa zone.
            var copy = ntfs
            let placed = copy.allocate(clusterCount: 8, hint: .normal)
            #expect(placed.first.map { $0.end <= 786_432 } == true, "\(formatting)")
        }
        let nt = Self.allocator(clusterCount: clusterCount, formatting: .nt)
        #expect(nt.mft.extents[0].start == nt.bootExtent.end)
        // Vista et 7, un volume de moins de 24 Gio : la MFT au huitième, une
        // règle du modèle.
        let small = Self.allocator(clusterCount: 100_000, formatting: .vista)
        #expect(small.mft.extents[0].start == 12_500)
    }

    /// Sous XP, trois paliers (`format.cxx:585-593`) : au tiers du volume
    /// sous 2 Gio, à 1 Gio de 2 à 6 Gio, à 3 Gio au-delà — et non au
    /// huitième d'un volume de moins de 24 Gio.
    @Test("$MFT par paliers sous XP : au tiers, à 1 Gio, à 3 Gio")
    func xpMFTTiers() {
        // 400 Mo : (secteurs / 3) / secteurs par cluster.
        #expect(Self.allocator(clusterCount: 100_000, formatting: .xp).mft.extents[0].start
                == (100_000 * 8 + 1) / 3 / 8)
        // 4 Gio : 1 Gio.
        #expect(Self.allocator(clusterCount: 1 << 20, formatting: .xp).mft.extents[0].start == 262_144)
        // 10 Gio : 3 Gio, là où le modèle d'avant mettait 1,25 Gio.
        #expect(Self.allocator(clusterCount: 10 << 18, formatting: .xp).mft.extents[0].start == 786_432)
    }

    /// La disposition de `FORMAT` sous XP SP1 (`LOGFILE_PLACEMENT_V1`) :
    /// `$LogFile`, la bitmap de la MFT et `$MFT` à la suite, à 3 Gio ;
    /// `$MFTMirr`, `$AttrDef`, `$Bitmap`, `$UpCase` et l'index racine à la
    /// suite, au milieu (`format.cxx:329-341, 585-618, 904-1175`,
    /// `logfile.cxx:223-233`, `mftfile.cxx:289-293`, `mftref.cxx:177-182`).
    @Test("Sous XP, le journal finit devant la MFT, et la bitmap est au milieu")
    func xpLayout() {
        let clusterCount: UInt32 = 9_765_624          // les 40 Go de `secretaire-2003`
        let ntfs = Self.allocator(clusterCount: clusterCount, formatting: .xp)
        let layout = NTFSAllocator.layout(profile: NTFSProfile(clusterKB: 4),
                                          clusterCount: clusterCount, formatting: .xp)
        let mft = ntfs.mft.extents[0]
        #expect(mft.start == 786_432)
        // 16 enregistrements (`FIRST_USER_FILE_NUMBER`), quatre clusters.
        #expect(mft.length == 4 && ntfs.mftRecordCount == 16)
        // La bitmap de la MFT juste devant elle ; le journal finit à
        // `MftLcn` moins les 8 Ko réservés à cette bitmap, soit deux clusters.
        #expect(layout.mftBitmap == Extent(start: 786_431, length: 1))
        #expect(ntfs.logFile.end == 786_430)
        #expect(UInt64(ntfs.logFile.length) * 4_096 == 64 << 20)
        #expect(!ntfs.bitmap.isAllocated(786_430))
        // Le milieu : le miroir, puis ce que `_NextAlloc` pose derrière lui.
        #expect(ntfs.mftMirror.start == clusterCount / 2)
        #expect(layout.attrDef == Extent(start: ntfs.mftMirror.end, length: 1))
        #expect(ntfs.volumeBitmap.start == layout.attrDef.end)
        #expect(UInt64(ntfs.volumeBitmap.length) * 4_096 * 8 >= UInt64(clusterCount))
        #expect(layout.upCase == Extent(start: ntfs.volumeBitmap.end, length: 32))
        #expect(layout.rootIndex == Extent(start: layout.upCase.end, length: 1))
        #expect(ntfs.formattedRootIndex == layout.rootIndex)
        for extent in [layout.mftBitmap, layout.attrDef, layout.upCase] {
            #expect(ntfs.systemExtents.contains(extent))
        }
        #expect(!ntfs.systemExtents.contains(layout.rootIndex!), "l'index racine est à la racine")
        // La zone MFT n'a pas bougé : 12,5 % depuis la MFT.
        #expect(ntfs.mftZone.upperBound == 786_432 + UInt32(Double(clusterCount) * 0.125))
        // Un premier fichier se pose devant le journal, en tête.
        var copy = ntfs
        #expect(copy.allocate(clusterCount: 8, hint: .normal).first?.start == ntfs.bootExtent.end)
    }

    /// La taille du journal sous XP est une rampe (`logfile.cxx:48-56,
    /// 869-888`) : 1 % jusqu'à 400 Mo, au moins 2 Mo ; au-delà, 4 Mo plus un
    /// deux-centième de ce qui dépasse, plafonné à 64 Mo, arrondi à 16 Ko.
    @Test("Le journal de XP suit une rampe, pas des paliers")
    func xpLogFileRamp() {
        let mebibyte: UInt64 = 1 << 20
        #expect(NTFSAllocator.xpLogFileBytes(volumeBytes: 100 * mebibyte) == 2 * mebibyte)
        #expect(NTFSAllocator.xpLogFileBytes(volumeBytes: 400 * mebibyte) == 4 * mebibyte)
        // 2 Go : environ 12 Mo, là où les paliers de `mkntfs` donnaient 4.
        let two = NTFSAllocator.xpLogFileBytes(volumeBytes: 2_000_000_000)
        #expect(two > 12_000_000 && two < 12_200_000 && two % 16_384 == 0)
        // 8 Gio : environ 43 Mo.
        let eight = NTFSAllocator.xpLogFileBytes(volumeBytes: 8 << 30)
        #expect(eight > 42 * mebibyte && eight < 44 * mebibyte)
        // Le plafond, vers 12,1 Gio : tous les NTFS de la galerie.
        #expect(NTFSAllocator.xpLogFileBytes(volumeBytes: 13 << 30) == 64 * mebibyte)
        #expect(NTFSAllocator.xpLogFileBytes(volumeBytes: 3 << 40) == 64 * mebibyte)
    }

    /// `$MFTMirr` est au milieu du volume de NT 4 à Vista, et au LCN 2
    /// depuis Windows 7 (Sedory) : les deux époques restent.
    @Test("Le miroir est au milieu jusqu'à Vista, au LCN 2 sous Windows 7")
    func mirrorPlacement() {
        let clusterCount: UInt32 = 1_000_000
        for formatting in [NTFSAllocator.Formatting.nt, .xp, .vista] {
            let ntfs = Self.allocator(clusterCount: clusterCount, formatting: formatting)
            #expect(ntfs.mftMirror.start == clusterCount / 2, "\(formatting)")
        }
        let seven = Self.allocator(clusterCount: clusterCount, formatting: .win7)
        #expect(seven.mftMirror.start == 2)
        #expect(seven.mft.extents[0].start > seven.logFile.end)
    }

    /// La zone MFT : 12,5 % du volume jusqu'à XP, 200 Mo depuis Vista
    /// (KB 961095), renouvelés quand la MFT les a remplis.
    @Test("La zone MFT fait 12,5 % sous XP et 200 Mo depuis Vista")
    func mftZoneSize() {
        let clusterCount: UInt32 = 64_000_000
        let xp = Self.allocator(clusterCount: clusterCount, formatting: .xp)
        #expect(xp.mftZone.upperBound - xp.mft.extents[0].start == clusterCount / 8)
        let vista = Self.allocator(clusterCount: clusterCount, formatting: .vista)
        #expect(vista.mftZone.upperBound - vista.mft.extents[0].start == (200 << 20) / 4_096)
    }

    /// La disposition suit le système du profil, pas son année.
    @Test("La disposition suit le champ os du profil")
    func formattingFollowsTheOS() throws {
        for (id, expected) in [("dev-2003", NTFSAllocator.Formatting.xp),
                               ("dev-2007", .vista), ("dev-2012", .win7)] {
            #expect(DiskGenerator.formatting(for: try ScenarioLibrary.load(id)) == expected, "\(id)")
        }
        var spec = try ScenarioLibrary.load("dev-2003")
        spec.os = "nt4"
        spec.timeline = TimelineSpec(start: CivilDate(year: 1999, month: 1, day: 1),
                                     end: CivilDate(year: 2000, month: 1, day: 1))
        #expect(DiskGenerator.formatting(for: spec) == .nt)
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

    /// `$Bitmap` est posée derrière la zone MFT hors XP — au milieu sous XP
    /// (`NTFSMetafileTests.xpLayout`) —, et elle couvre le volume.
    @Test("La table d'occupation NTFS a sa place, derrière la zone MFT hors XP")
    func ntfsBitmapHasItsPlace() {
        let clusters: UInt32 = 1_000_000
        let ntfs = NTFSAllocator(profile: NTFSProfile(clusterKB: 4), clusterCount: clusters,
                                 formatting: .vista)
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
