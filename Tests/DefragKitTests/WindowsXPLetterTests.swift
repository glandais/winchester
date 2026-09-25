import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Les défauts du chantier 47 (`LEDGER-XP.md`) : ce que la passe de XP doit
/// faire d'après son code, et que le modèle faisait autrement.
@Suite("La passe de XP, à la lettre")
struct WindowsXPLetterTests {

    /// Un NTFS de test : chaque fichier porte son enregistrement de MFT quand
    /// on le donne, et la MFT ses extents quand on les donne.
    private static func volume(clusterCount: Int,
                               files: [(extents: [Extent], record: Int?)],
                               categories: [ClusterCategory] = [],
                               mft: [Extent] = []) -> DefragVolume {
        var partition = PartitionGeometry(startLBA: 0, clusterCount: clusterCount,
                                          clusterSectors: 8, format: .ntfs)
        if !mft.isEmpty { partition.mftExtents = mft }
        let records = files.enumerated().map { position, file in
            var record = DefragFile(id: UInt32(position), path: "\\Documents\\F\(position).dat",
                                    category: position < categories.count ? categories[position] : .document,
                                    walkOrder: position,
                                    extents: file.extents, isMovable: true)
            record.mftRecord = file.record
            return record
        }
        return DefragVolume(partition: partition, files: records,
                            systemExtents: mft, mftExtents: mft)
    }

    /// Les enregistrements de MFT que la passe écrit (validations).
    private static func recordWrites(_ plan: DefragPlan) -> [Int] {
        plan.operations.filter { $0.kind == .metadata }.map(\.lba)
    }

    // MARK: B#15

    /// `MFTDefrag` déplace la queue de la MFT ; une validation qui suit écrit
    /// l'enregistrement du fichier là où la MFT est maintenant, et non dans
    /// les clusters qu'elle vient de quitter.
    @Test("Après MFTDefrag, les validations suivent la MFT déplacée")
    func commitsFollowTheRelocatedMFT() throws {
        // La MFT en trois morceaux : 64 enregistrements en tête, puis deux
        // queues de 16. L'enregistrement 70 est dans la deuxième.
        let mft = [Extent(start: 0, length: 16), Extent(start: 100, length: 4), Extent(start: 200, length: 4)]
        let input = Self.volume(clusterCount: 2_000,
                                files: [([Extent(start: 300, length: 5), Extent(start: 400, length: 5)], 70)],
                                mft: mft)
        let before = input.partition
        let plan = input.planned(using: WindowsXPStrategy())

        // La queue part d'un bloc vers le premier trou qui tient toute la MFT
        // (24 clusters) : 16..<24, contre le premier extent. Le pilote fond
        // deux extents contigus en un (chantier 50) : la MFT est d'un tenant.
        var after = before
        after.mftExtents = [Extent(start: 0, length: 24)]
        // Sous XP, c'est le lazy writer qui écrit l'enregistrement, avec sa
        // page de 4 Ko : celle des enregistrements 68 à 71 (chantier 50).
        let writes = Self.recordWrites(plan)
        #expect(writes.contains(after.mftRecordLBA(68)), "l'enregistrement n'est pas écrit à la nouvelle place")
        #expect(!writes.contains(before.mftRecordLBA(68)), "l'enregistrement est écrit dans l'ancienne queue")
        #expect(plan.partition.mftExtents == after.mftExtents)
    }

    // MARK: Chantier 50 — MFTDefrag

    /// Une MFT en deux extents, sa queue d'un seul tenant : l'ancien modèle
    /// n'agissait qu'à partir de trois. XP agit dès deux (`lMFTFragments > 1`,
    /// `mftdefrag.cpp:122`).
    @Test("MFTDefrag agit dès deux extents")
    func mftDefragActsOnTwoExtents() {
        let mft = [Extent(start: 0, length: 16), Extent(start: 100, length: 4)]
        let input = Self.volume(clusterCount: 2_000,
                                files: [([Extent(start: 300, length: 5)], 40)], mft: mft)
        let plan = input.planned(using: WindowsXPStrategy())
        // Le premier trou qui tient toute la MFT (20 clusters) : 16..<100.
        #expect(plan.partition.mftExtents == [Extent(start: 0, length: 20)])
    }

    /// Le trou cherché tient la MFT **entière**, et il est hors de la zone MFT
    /// (`FindFreeSpaceChunk`, `MarkBitMapforNTFS`, `defragcommon.cpp:147-168`).
    @Test("MFTDefrag cherche un trou de toute la MFT, hors de la zone")
    func mftDefragTargetsAWholeMFTHoleOutsideTheZone() {
        // La queue fait 8 clusters, la MFT 40. Un trou de 10 à 40..<50, un de
        // 30 à 60..<90 : le premier tiendrait la queue, pas toute la MFT ; la
        // zone MFT couvre 100..<400 ; le premier trou de 40 hors d'elle est
        // à 400.
        let mft = [Extent(start: 0, length: 32), Extent(start: 1_000, length: 8)]
        let partition: PartitionGeometry = {
            var partition = PartitionGeometry(startLBA: 0, clusterCount: 2_000,
                                              clusterSectors: 8, format: .ntfs)
            partition.mftExtents = mft
            return partition
        }()
        let blockers = [Extent(start: 32, length: 8), Extent(start: 50, length: 10),
                        Extent(start: 90, length: 10), Extent(start: 440, length: 560),
                        Extent(start: 1_008, length: 992)]
        let files = blockers.enumerated().map { position, extent in
            DefragFile(id: UInt32(position), path: "\\S\(position)", category: .system,
                       walkOrder: position, extents: [extent], isMovable: false)
        }
        let input = DefragVolume(partition: partition, files: files, mftZone: 100..<400,
                                 systemExtents: mft, mftExtents: mft)
        let plan = input.planned(using: WindowsXPStrategy())
        #expect(plan.partition.mftExtents?.first == Extent(start: 0, length: 32))
        #expect(plan.partition.mftExtents?.dropFirst().first?.start == 400)
    }

    /// Faute de trou assez grand, `FindFreeSpaceChunk` rend le début du
    /// dernier trou examiné quand il touche la fin du volume, et l'outil tente
    /// le déplacement quand même. `FSCTL_MOVE_FILE` pose des blocs de 64 Kio
    /// jusqu'à buter sur la fin du volume (`deviosup.c:10515-10523`) : une
    /// partie de la queue a bougé, le reste non.
    @Test("Sans trou assez grand, MFTDefrag déplace ce qui tient jusqu'à la fin du volume")
    func mftDefragFallsBackOnTheLastHole() {
        // MFT de 128 clusters : 64 en tête, 64 en queue à 500. Le volume est
        // plein, sauf 30 clusters au fond, 1970..<2000.
        let mft = [Extent(start: 0, length: 64), Extent(start: 500, length: 64)]
        let blockers = [Extent(start: 64, length: 436), Extent(start: 564, length: 1_406)]
        var partition = PartitionGeometry(startLBA: 0, clusterCount: 2_000,
                                          clusterSectors: 8, format: .ntfs)
        partition.mftExtents = mft
        let files = blockers.enumerated().map { position, extent in
            DefragFile(id: UInt32(position), path: "\\S\(position)", category: .system,
                       walkOrder: position, extents: [extent], isMovable: false)
        }
        let input = DefragVolume(partition: partition, files: files,
                                 systemExtents: mft, mftExtents: mft)
        let plan = input.planned(using: WindowsXPStrategy())
        // Un bloc de 16 clusters à 1970 ; le suivant finirait à 2002. Le
        // second appel, à la fin de la passe, trouve le même trou de 14
        // clusters au fond, et son premier bloc ne tient déjà plus.
        #expect(plan.partition.mftExtents == [Extent(start: 0, length: 64),
                                              Extent(start: 1_970, length: 16),
                                              Extent(start: 516, length: 48)])
    }

    /// Le dernier trou examiné ne touche pas la fin du volume : `FindFreeExtent`
    /// rend zéro, et l'outil ne déplace rien.
    @Test("Sans trou assez grand ni trou au fond, MFTDefrag ne fait rien")
    func mftDefragGivesUpWithoutAnEndHole() {
        let mft = [Extent(start: 0, length: 64), Extent(start: 500, length: 64)]
        let blockers = [Extent(start: 64, length: 436), Extent(start: 564, length: 1_400),
                        Extent(start: 1_994, length: 6)]
        var partition = PartitionGeometry(startLBA: 0, clusterCount: 2_000,
                                          clusterSectors: 8, format: .ntfs)
        partition.mftExtents = mft
        let files = blockers.enumerated().map { position, extent in
            DefragFile(id: UInt32(position), path: "\\S\(position)", category: .system,
                       walkOrder: position, extents: [extent], isMovable: false)
        }
        let input = DefragVolume(partition: partition, files: files,
                                 systemExtents: mft, mftExtents: mft)
        let plan = input.planned(using: WindowsXPStrategy())
        #expect(plan.partition.mftExtents == mft)
    }

    // MARK: Chantier 50 — une transaction par bloc de 64 Kio

    /// Un fichier de 256 Ko en deux morceaux, recollé à 1 000 sur un volume
    /// formaté par `formatting` : les opérations d'un seul `FSCTL_MOVE_FILE`,
    /// puis celles de la fin de passe.
    private static func oneMove(formatting: NTFSAllocator.Formatting,
                                bytes: UInt64? = nil) -> (partition: PartitionGeometry,
                                                          move: [DiskOperation], final: [DiskOperation]) {
        var partition = PartitionGeometry(startLBA: 0, clusterCount: 4_000,
                                          clusterSectors: 8, format: .ntfs)
        partition.ntfsFormatting = formatting
        let source = [Extent(start: 100, length: 32), Extent(start: 200, length: 32)]
        var file = DefragFile(id: 0, path: "\\Documents\\F.dat", category: .document,
                              walkOrder: 0, extents: source, isMovable: true)
        file.mftRecord = 70
        file.bytes = bytes
        var volume = DefragVolume(partition: partition, files: [file])
        let sink = OperationSink()
        DefragOperations.moveFile(source: source, destination: [Extent(start: 1_000, length: 64)],
                                  category: .document, contiguous: true, phase: 1,
                                  volume: &volume, fileIndex: 70, bufferBytes: 64 * 1_024,
                                  validBytes: bytes, into: sink)
        let moved = sink.operations.count
        DefragOperations.final(partition: partition, phase: 2, into: sink)
        return (partition, Array(sink.operations[..<moved]), Array(sink.operations[moved...]))
    }

    /// Sous XP, `NtfsDefragFile` valide chaque bloc de 64 Kio
    /// (`NtfsCheckpointCurrentTransaction`, `deviosup.c:10617-10618`) sans
    /// écrire l'enregistrement de MFT ni la bitmap : le *lazy writer* les
    /// écrit plus tard, par pages de 4 Ko. Sous Vista, le modèle d'avant :
    /// une validation par fichier, écrite aussitôt.
    @Test("Sous XP, une transaction par bloc, et la MFT écrite par le lazy writer")
    func xpCommitsEachBlockLazily() {
        let xp = Self.oneMove(formatting: .xp)
        let vista = Self.oneMove(formatting: .vista)
        // 256 Ko, soit quatre blocs de 64 Kio, des deux côtés.
        #expect(xp.move.filter { $0.kind == .writeExtent }.count == 4)
        #expect(vista.move.filter { $0.kind == .writeExtent }.count == 4)
        // Vista écrit l'enregistrement juste après la copie.
        #expect(vista.move.contains { $0.kind == .metadata && $0.lba == vista.partition.mftRecordLBA(70) })
        // XP : rien pendant le déplacement — quatre transactions ne
        // remplissent pas une page de journal, et le lazy writer n'est pas
        // encore passé —, puis la page de 4 Ko des enregistrements 68 à 71
        // en fin de passe, avec celles de la bitmap.
        #expect(!xp.move.contains { $0.kind == .metadata })
        let page = xp.partition.mftRecordLBA(68)
        #expect(xp.final.contains { $0.kind == .metadata && $0.lba == page && $0.sectors == 8 })
        #expect(xp.final.contains { $0.kind == .metadata && $0.lba == xp.partition.bitmapLBA })
    }

    /// Au-delà de la `ValidDataLength`, les blocs sont réalloués sans être lus
    /// ni écrits (`deviosup.c:10530-10561`). Le test du pilote est
    /// `StartingVcn <= UpperBound`, `UpperBound` arrondi au cluster : le bloc
    /// qui commence juste à la borne est encore copié.
    @Test("Sous XP, au-delà des données valides, un bloc est réalloué sans copie")
    func xpSkipsBlocksBeyondValidData() {
        // 64 clusters alloués, 20 Ko de données valides : 5 clusters. Seul le
        // premier bloc (VCN 0) commence avant la borne ; les trois autres
        // (VCN 16, 32, 48) sont au-delà.
        let short = Self.oneMove(formatting: .xp, bytes: 20 * 1_024)
        #expect(short.move.filter { $0.kind == .writeExtent }.count == 1)
        #expect(short.move.filter { $0.kind == .readExtent }.count == 1)
        // 64 Ko tout juste : la borne tombe sur le VCN 16, dont le bloc est
        // encore copié.
        let edge = Self.oneMove(formatting: .xp, bytes: 64 * 1_024)
        #expect(edge.move.filter { $0.kind == .writeExtent }.count == 2)
        // Vista, rien de tel : le modèle copie tout ce qui est alloué.
        let vista = Self.oneMove(formatting: .vista, bytes: 20 * 1_024)
        #expect(vista.move.filter { $0.kind == .writeExtent }.count == 4)
    }

    // MARK: Chantier 50 — la consolidation

    /// Un volume de 1 000 clusters : des fichiers déplaçables là où on les
    /// pose, et des obstacles immobiles partout ailleurs sauf dans `free`.
    private static func walled(files: [[Extent]], free: [Extent],
                               mftZone: Range<UInt32>) -> DefragVolume {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 1_000,
                                          clusterSectors: 8, format: .ntfs)
        var taken = files.flatMap { $0 } + free
        taken.sort { $0.start < $1.start }
        var walls: [Extent] = []
        var cursor: UInt32 = 0
        for extent in taken {
            if extent.start > cursor { walls.append(Extent(start: cursor, length: extent.start - cursor)) }
            cursor = max(cursor, extent.end)
        }
        if cursor < 1_000 { walls.append(Extent(start: cursor, length: 1_000 - cursor)) }
        // La zone MFT est libre : les murs n'y vont pas.
        walls = walls.flatMap { wall -> [Extent] in
            guard wall.start < mftZone.upperBound, wall.end > mftZone.lowerBound else { return [wall] }
            var kept: [Extent] = []
            if wall.start < mftZone.lowerBound {
                kept.append(Extent(start: wall.start, length: mftZone.lowerBound - wall.start))
            }
            if wall.end > mftZone.upperBound {
                kept.append(Extent(start: mftZone.upperBound, length: wall.end - mftZone.upperBound))
            }
            return kept
        }
        var records = files.enumerated().map { position, extents in
            DefragFile(id: UInt32(position), path: "\\Documents\\F\(position).dat", category: .document,
                       walkOrder: position, extents: extents, isMovable: true)
        }
        records.append(DefragFile(id: 900, path: "\\SYSTEM", category: .system,
                                  walkOrder: 900, extents: walls, isMovable: false))
        return DefragVolume(partition: partition, files: records, mftZone: mftZone)
    }

    /// Vider la zone MFT s'arrête au premier fichier sans trou
    /// (`dfrgntfs.cpp:3858-3866`, `bDefragMftZone`), alors qu'une région en
    /// tolère dix. Le plus haut des trois fichiers de la zone ne tient nulle
    /// part : les deux autres, qui auraient trouvé un trou derrière la zone,
    /// restent.
    @Test("Vider la zone MFT s'arrête au premier fichier sans trou")
    func mftZoneStopsAtTheFirstFailure() throws {
        let small1 = [Extent(start: 410, length: 5)]
        let small2 = [Extent(start: 450, length: 5)]
        let big = [Extent(start: 480, length: 100)]
        let input = Self.walled(files: [small1, small2, big],
                                free: [Extent(start: 700, length: 20)], mftZone: 400..<600)
        let plan = input.planned(using: WindowsXPStrategy())
        #expect(plan.arrangement.first { $0.id == 0 }?.extents == small1)
        #expect(plan.arrangement.first { $0.id == 1 }?.extents == small2)
        #expect(plan.evacuations == 0)
    }

    /// Un trou qui traverse toute la zone MFT n'en garde, dans les listes de
    /// l'outil, que la partie d'avant (`freespace.cpp:305-318`) : la partie
    /// d'après, pourtant libre et hors zone, n'est offerte à personne.
    @Test("Un trou qui traverse la zone MFT n'en garde que la partie d'avant")
    func holeAcrossTheZoneKeepsItsHead() throws {
        // Le fichier cassé demande 150 clusters. Libre : 300..<700, zone MFT
        // 400..<500 ; avant elle, 100 clusters ; après, 200.
        let broken = [Extent(start: 100, length: 75), Extent(start: 800, length: 75)]
        let input = Self.walled(files: [broken], free: [Extent(start: 300, length: 400)],
                                mftZone: 400..<500)
        let plan = input.planned(using: WindowsXPStrategy())
        #expect(plan.arrangement.first { $0.id == 0 }?.extents == broken)
    }

    // MARK: B#16

    /// `SendStatusData` (`dfrgntfs.cpp:981-985`) borne le pourcentage sur le
    /// dernier envoyé : la barre ne recule jamais, même quand une phase
    /// revient au tour suivant.
    @Test("L'avancement de la passe XP ne recule pas")
    func progressNeverGoesBack() {
        // Un volume encombré, tiré d'un générateur déterministe : des fichiers
        // de 1 à 40 clusters, un sur trois en deux à quatre morceaux épars,
        // plein aux quatre cinquièmes. Les phases y reviennent tour après
        // tour, et chacune recommençait son avancement à sa propre plage.
        var seed: UInt64 = 47
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let clusterCount = 20_000
        var free = Array(repeating: true, count: clusterCount)
        var files: [(extents: [Extent], record: Int?)] = []
        var cursor = 0
        while cursor < clusterCount * 4 / 5 {
            let size = 1 + next(40)
            let pieces = next(3) == 0 ? 2 + next(3) : 1
            var extents: [Extent] = []
            var left = size
            for piece in 0..<pieces where left > 0 {
                let length = piece == pieces - 1 ? left : max(1, left / (pieces - piece))
                // Le premier morceau suit le curseur ; les autres vont loin.
                var at = piece == 0 ? cursor : next(clusterCount - length)
                while at + length <= clusterCount, !free[at..<(at + length)].allSatisfy({ $0 }) { at += 1 }
                guard at + length <= clusterCount else { break }
                for c in at..<(at + length) { free[c] = false }
                extents.append(Extent(start: UInt32(at), length: UInt32(length)))
                left -= length
                if piece == 0 { cursor = at + length + next(4) }
            }
            if !extents.isEmpty { files.append((extents: extents, record: nil)) }
            while cursor < clusterCount, !free[cursor] { cursor += 1 }
        }
        let input = Self.volume(clusterCount: clusterCount, files: files)
        final class Marks { var values: [Double] = [] }
        let marks = Marks()
        let sink = OperationSink { _, _, progress, _ in marks.values.append(progress) }
        let plan = WindowsXPStrategy().plan(volume: input, into: sink)

        #expect(plan.before.fragmentedFiles > 0)
        #expect(marks.values.count > 100)
        let setbacks = zip(marks.values, marks.values.dropFirst()).filter { $1 < $0 }
        #expect(setbacks.isEmpty, "l'avancement recule \(setbacks.count) fois, dont \(setbacks.first.map { "\($0.0) → \($0.1)" } ?? "")")
    }

    // MARK: B#17

    /// « Déjà en place » : contigus au départ, déplaçables, et jamais
    /// déplacés. Ni le fichier d'échange, ni ce que le tassement emmène.
    @Test("Déjà en place : ni les intouchables, ni ce qui a été déplacé")
    func alreadyInPlaceCountsOnlyUntouchedMovables() {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 2_000, clusterSectors: 8, format: .ntfs)
        let files = [
            // En tête, rien devant : reste.
            DefragFile(id: 0, path: "\\A.dat", category: .document, walkOrder: 0,
                       extents: [Extent(start: 0, length: 10)], isMovable: true),
            // Un fichier d'échange, immobile : pas compté.
            DefragFile(id: 1, path: "\\pagefile.sys", category: .swap, walkOrder: 1,
                       extents: [Extent(start: 500, length: 50)], isMovable: false),
            // Contigu mais loin, avec un trou devant : le tassement l'emmène.
            DefragFile(id: 2, path: "\\B.dat", category: .application, walkOrder: 2,
                       extents: [Extent(start: 1_500, length: 20)], isMovable: true),
            // Cassé : réparé, donc déplacé.
            DefragFile(id: 3, path: "\\C.dat", category: .document, walkOrder: 3,
                       extents: [Extent(start: 900, length: 5), Extent(start: 1_000, length: 5)], isMovable: true),
        ]
        let plan = DefragVolume(partition: partition, files: files).planned(using: WindowsXPStrategy())
        let far = plan.arrangement.first { $0.id == 2 }?.extents.first?.start ?? 0
        #expect(far < 1_500, "le tassement devait emmener le fichier du fond")
        #expect(plan.filesAlreadyInPlace == 1)
    }

    // MARK: B#21

    /// L'arrêt au premier fichier sans trou ne vaut que pour l'ordre par
    /// taille, où les suivants sont plus gros. Dans un autre ordre, un gros
    /// fichier sans trou ne fait pas sauter les petits qui suivent.
    @Test("Un autre ordre ne s'arrête pas au premier fichier sans trou")
    func otherOrdersKeepGoing() {
        // Un gros fichier en six morceaux, sans trou à sa taille, puis deux
        // petits en deux morceaux ; des trous de deux à dix clusters, aucun
        // de soixante, et rien à consolider.
        let files: [(extents: [Extent], record: Int?)] = [
            ((0..<6).map { Extent(start: UInt32(20 + $0 * 12), length: 10) }, nil),
            ([Extent(start: 10, length: 1), Extent(start: 100, length: 1)], nil),
            ([Extent(start: 11, length: 1), Extent(start: 101, length: 1)], nil),
            ([Extent(start: 102, length: 890)], nil),
        ]
        let input = Self.volume(clusterCount: 1_000, files: files)
        var strategy = WindowsXPStrategy()
        strategy.order = .mostFragmented
        let plan = input.planned(using: strategy)
        // Les deux petits sont réparés ; le gros reste en morceaux.
        #expect(plan.after.fragmentedFiles == 1)
    }

    // MARK: xp-defrag-tri

    /// `FileEntrySizeCompareRoutine` (`dfrgntfs.cpp:395-432`) : par taille,
    /// puis par numéro d'enregistrement — pas par l'identifiant du modèle.
    @Test("À taille égale, le plus petit numéro d'enregistrement passe d'abord")
    func tiesBreakOnTheMFTRecord() throws {
        // Deux fichiers de deux clusters ; l'identifiant 0 a l'enregistrement
        // le plus grand. Un seul trou de deux clusters, en tête.
        let files: [(extents: [Extent], record: Int?)] = [
            ([Extent(start: 10, length: 1), Extent(start: 30, length: 1)], 500),
            ([Extent(start: 20, length: 1), Extent(start: 40, length: 1)], 40),
            ([Extent(start: 2, length: 8), Extent(start: 11, length: 9), Extent(start: 21, length: 9),
              Extent(start: 31, length: 9), Extent(start: 41, length: 59)], nil),
        ]
        let input = Self.volume(clusterCount: 100, files: files,
                                categories: [.document, .application, .archive])
        let plan = input.planned(using: WindowsXPStrategy())
        // Le premier servi prend le trou de tête : c'est l'enregistrement 40,
        // l'application — et non l'identifiant 0, le document.
        let first = try #require(plan.mutations.first { $0.category != .free })
        #expect(first.start == 0)
        #expect(first.category == .application)
    }
}

private extension DefragVolume {
    func planned(using strategy: WindowsXPStrategy) -> DefragPlan {
        DefragPlanner.plan(volume: self, using: strategy)
    }
}
