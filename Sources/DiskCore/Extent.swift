import Foundation

/// Suite de clusters consécutifs appartenant à un même fichier.
///
/// Huit octets, et pas un de plus : un catalogue réaliste de 2003 compte des
/// centaines de milliers de fichiers, et un volume mité en produit plusieurs
/// extents chacun. Les indices sont des `UInt32` — un `Int` doublerait
/// l'empreinte pour une plage dont on n'a pas l'usage : 2³² clusters de 4 Ko
/// font déjà 16 To.
public struct Extent: Sendable, Hashable, Codable {

    public var start: UInt32
    public var length: UInt32

    public init(start: UInt32, length: UInt32) {
        self.start = start
        self.length = length
    }

    /// Premier cluster **après** l'extent.
    public var end: UInt32 { start &+ length }

    public var isEmpty: Bool { length == 0 }

    public func contains(_ cluster: UInt32) -> Bool {
        cluster >= start && cluster < end
    }

    /// Deux extents se suivent-ils sans trou ? C'est la seule question que pose
    /// le comptage de fragments : un fichier « fragmenté » est un fichier dont
    /// deux extents consécutifs ne sont pas adjacents.
    public func isAdjacent(to other: Extent) -> Bool {
        end == other.start
    }
}

extension Array where Element == Extent {

    /// Nombre total de clusters couverts.
    public var clusterCount: UInt32 {
        reduce(0) { $0 &+ $1.length }
    }

    /// Ajoute un cluster à la fin de la liste en prolongeant le dernier extent
    /// quand c'est possible. C'est la brique de tous les allocateurs : ils
    /// produisent des clusters dans l'ordre logique du fichier et la
    /// coalescence se fait au fil de l'eau, sans passe de compactage.
    public mutating func appendCluster(_ cluster: UInt32) {
        if var last = self.last, last.end == cluster {
            last.length &+= 1
            self[count - 1] = last
        } else {
            append(Extent(start: cluster, length: 1))
        }
    }

    /// Même chose pour une suite de clusters déjà contiguë.
    public mutating func appendRun(start: UInt32, length: UInt32) {
        guard length > 0 else { return }
        if var last = self.last, last.end == start {
            last.length &+= length
            self[count - 1] = last
        } else {
            append(Extent(start: start, length: length))
        }
    }

    /// Fusionne les extents adjacents **dans l'ordre de la liste**. Ne trie
    /// pas : l'ordre d'une liste d'extents est l'ordre logique du fichier, et
    /// le perdre fausserait à la fois le calcul de fragmentation et le temps de
    /// lecture séquentielle.
    public func coalesced() -> [Extent] {
        guard count > 1 else { return self }
        var result: [Extent] = []
        result.reserveCapacity(count)
        for extent in self where !extent.isEmpty {
            if var last = result.last, last.end == extent.start {
                last.length &+= extent.length
                result[result.count - 1] = last
            } else {
                result.append(extent)
            }
        }
        return result
    }
}
