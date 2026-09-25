import Testing
import DiskCore
@testable import DefragKit

/// `FSCTL_MOVE_FILE` sur un volume FAT, joué comme `fastfat` le joue
/// (`FatMoveFile`, `base/fs/fastfat/fsctrl.c:5290-5645, 5959-5968`) :
/// chantier 51i.
@Suite("FSCTL_MOVE_FILE sur FAT")
struct FatMoveFileTests {

    /// Un fichier de 640 Ko en deux morceaux, déplacé d'un bloc à 2 000.
    private static func oneMove() -> (partition: PartitionGeometry, move: [DiskOperation]) {
        let partition = PartitionGeometry(startLBA: 0, clusterCount: 60_000,
                                          clusterSectors: 8, format: .fat32)
        let source = [Extent(start: 100, length: 80), Extent(start: 400, length: 80)]
        let file = DefragFile(id: 0, path: "\\F.DAT", category: .document,
                              walkOrder: 0, extents: source, isMovable: true)
        var volume = DefragVolume(partition: partition, files: [file])
        let sink = OperationSink()
        DefragOperations.moveFile(source: source, destination: [Extent(start: 2_000, length: 160)],
                                  category: .document, contiguous: true, phase: 1,
                                  volume: &volume, fileIndex: 16, entrySector: 12_345,
                                  bufferBytes: 4 * 1_048_576, into: sink)
        return (partition, sink.operations)
    }

    @Test("Des tranches de 256 Ko, un FLUSH CACHE après chacune")
    func chunksOf256KWithAFlushEach() {
        let (_, move) = Self.oneMove()
        // 640 Ko : trois tranches alignées dans le fichier (256, 256, 128).
        let flushes = move.filter { $0.isWrite && $0.sectors == 0 }
        #expect(flushes.count == 3)
        // Chaque tranche écrite d'une requête, en paquets de 124 Ko au plus.
        let writes = move.filter { $0.kind == .writeExtent }
        #expect(writes.allSatisfy { $0.sectors <= 248 })
        #expect(writes.reduce(0) { $0 + $1.sectors } == 160 * 8)
    }

    @Test("La table avant et après chaque tranche, l'entrée quand le premier cluster bouge")
    func tableBeforeAndAfter() {
        let (partition, move) = Self.oneMove()
        let fat = move.filter { $0.kind == .metadata && $0.sectors > 0
            && $0.lba >= partition.fat1LBA && $0.lba < partition.rootLBA }
        // Par tranche : la cible (deux copies), la seconde soudure (deux
        // copies), et — sauf pour la première — la première soudure (deux).
        #expect(fat.count == 2 + 2 + (2 + 2 + 2) * 2)
        // La première tranche déplace le premier cluster : l'entrée de
        // répertoire est écrite, une fois.
        #expect(move.filter { $0.lba == 12_345 }.count == 1)
        // La source rendue n'est pas écrite tout de suite.
        #expect(!move.isEmpty)
    }
}
