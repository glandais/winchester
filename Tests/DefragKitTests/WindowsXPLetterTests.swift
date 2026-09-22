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

        // La queue part d'un bloc vers le premier trou qui la tient : 16..<24.
        var after = before
        after.mftExtents = [mft[0], Extent(start: 16, length: 8)]
        let writes = Self.recordWrites(plan)
        #expect(writes.contains(after.mftRecordLBA(70)), "l'enregistrement n'est pas écrit à la nouvelle place")
        #expect(!writes.contains(before.mftRecordLBA(70)), "l'enregistrement est écrit dans l'ancienne queue")
        #expect(plan.partition.mftExtents == after.mftExtents)
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
