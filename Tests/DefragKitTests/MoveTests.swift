import Testing
import Foundation
import DiskCore
@testable import DefragKit

/// Ce qu'un déplacement écrit sur la carte.
///
/// Le calcul des clusters libérés cherche désormais la destination par
/// dichotomie, au lieu de la parcourir à chaque tronçon. L'oracle est l'ancien
/// calcul, recopié tel quel : sur des destinations morcelées, dans le désordre
/// et recouvrant la source, les mutations doivent être les mêmes, dans le même
/// ordre.
@Suite("Déplacement d'un fichier")
struct MoveTests {

    @Test("Les clusters libérés sont ceux de l'ancien calcul", arguments: 1...200)
    func freedMatchesOracle(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let source = Self.extents(in: 0..<600, rng: &rng)
        let destination = Self.extents(in: 0..<600, rng: &rng)
        let partition = PartitionGeometry(startLBA: 0, sectors: 400_000,
                                          clusterSectors: 8, format: .fat16)
        let bufferBytes = Int.random(in: 1...40, using: &rng) * partition.clusterBytes

        let sink = OperationSink()
        DefragOperations.move(source: source, destination: destination,
                              category: .document, phase: 0,
                              partition: partition, bufferBytes: bufferBytes,
                              into: sink)

        let expected = Self.oracle(source: source, destination: destination,
                                   buffer: UInt32(bufferBytes / partition.clusterBytes))
        let actual = sink.mutations.map { [$0.start, $0.count, Int($0.category.rawValue)] }
        #expect(actual == expected.map { [$0.start, $0.count, Int($0.category.rawValue)] })
    }

    /// Des extents disjoints tirés dans `range`, rendus dans le désordre.
    private static func extents(in range: Range<UInt32>,
                                rng: inout SeededGenerator) -> [Extent] {
        var cuts = Set<UInt32>()
        for _ in 0..<Int.random(in: 1...30, using: &rng) {
            cuts.insert(UInt32.random(in: range, using: &rng))
        }
        let bounds = ([range.lowerBound] + cuts.sorted() + [range.upperBound])
        var result: [Extent] = []
        for index in 0..<(bounds.count - 1) where Bool.random(using: &rng) {
            let length = bounds[index + 1] - bounds[index]
            if length > 0 { result.append(Extent(start: bounds[index], length: length)) }
        }
        if result.isEmpty { result = [Extent(start: range.lowerBound, length: 7)] }
        return result.shuffled(using: &rng)
    }

    /// Les mutations de l'ancien `move`, avec son `freed` d'origine.
    private static func oracle(source: [Extent], destination: [Extent],
                               buffer: UInt32) -> [MapMutation] {
        var mutations: [MapMutation] = []
        var sourceIndex = 0
        var sourceOffset: UInt32 = 0
        var destinationIndex = 0
        var destinationOffset: UInt32 = 0
        let kept = destination

        while sourceIndex < source.count && destinationIndex < destination.count {
            let from = source[sourceIndex]
            let to = destination[destinationIndex]
            let length = min(from.length - sourceOffset, to.length - destinationOffset, max(buffer, 1))
            guard length > 0 else { break }
            let readStart = from.start + sourceOffset
            let writeStart = to.start + destinationOffset
            mutations.append(MapMutation(start: Int(writeStart), count: Int(length),
                                         category: .document))
            mutations.append(contentsOf: freed(start: readStart, length: length, kept: kept))
            sourceOffset += length
            destinationOffset += length
            if sourceOffset == from.length { sourceIndex += 1; sourceOffset = 0 }
            if destinationOffset == to.length { destinationIndex += 1; destinationOffset = 0 }
        }
        return mutations
    }

    private static func freed(start: UInt32, length: UInt32,
                              kept: [Extent]) -> [MapMutation] {
        var mutations: [MapMutation] = []
        var cursor = start
        let end = start + length

        while cursor < end {
            if let covering = kept.first(where: { $0.start <= cursor && $0.end > cursor }) {
                cursor = min(covering.end, end)
                continue
            }
            let next = kept.filter { $0.start > cursor }.map(\.start).min() ?? end
            let stop = min(next, end)
            if stop > cursor {
                mutations.append(MapMutation(start: Int(cursor), count: Int(stop - cursor),
                                             category: .free))
            }
            cursor = max(stop, cursor + 1)
        }
        return mutations
    }
}
