import Foundation

/// Un fichier présent dans un bloc de la carte.
public struct CellOccupant: Sendable, Equatable {
    public let path: String
    public let category: FileCategory
    /// Clusters du fichier qui tombent dans le bloc.
    public let clustersInCell: UInt32
    /// Morceaux du fichier entier, pas seulement ceux du bloc.
    public let fragments: Int
    public let logicalSize: UInt64
}

/// Ce que contient un bloc de la carte d'un disque généré.
public struct CellContents: Sendable {
    public let clusters: Range<UInt32>
    /// Les fichiers les plus présents dans le bloc, du plus au moins présent.
    public let occupants: [CellOccupant]
    /// Nombre de fichiers qui touchent le bloc, y compris ceux qui ne sont
    /// pas listés.
    public let fileCount: Int
    /// Clusters du bloc tenus par ce que le système se réserve — MFT, `$Boot`,
    /// `$MFTMirr` — et qu'aucun fichier du catalogue ne décrit.
    public let systemClusters: UInt32
    /// Clusters du bloc occupés, fichiers et système confondus.
    public let usedClusters: UInt32
}

extension GeneratedDisk {

    /// La plage de clusters que représente un bloc, sur une carte de
    /// `cellCount` blocs.
    ///
    /// Le découpage est celui de `shaded(count:)` — une part fractionnaire de
    /// clusters par bloc —, arrondi au cluster : les plages se suivent sans
    /// trou ni recouvrement, et le dernier bloc va jusqu'au bout du volume.
    public func clusterRange(ofCell cell: Int, cellCount: Int) -> Range<UInt32> {
        precondition(cellCount > 0 && cell >= 0 && cell < cellCount)
        let total = bitmap.clusterCount
        let perCell = max(Double(total) / Double(cellCount), 1)
        func bound(_ index: Int) -> UInt32 {
            UInt32(min(Double(total), (Double(index) * perCell).rounded(.down)))
        }
        let start = bound(cell)
        let end = cell == cellCount - 1 ? total : bound(cell + 1)
        return start..<max(start, end)
    }

    /// Les fichiers d'un bloc, pour qu'on sache ce qu'on regarde en le
    /// touchant.
    ///
    /// Parcourt tout le catalogue : quelques dizaines de millisecondes sur le
    /// plus gros volume de la galerie, pour un geste de l'utilisateur, pas pour
    /// une image.
    public func contents(ofCell cell: Int, cellCount: Int, limit: Int = 5) -> CellContents {
        let range = clusterRange(ofCell: cell, cellCount: cellCount)

        func overlap(_ extents: [Extent]) -> UInt32 {
            var total: UInt32 = 0
            for extent in extents where !extent.isEmpty {
                let lower = max(extent.start, range.lowerBound)
                let upper = min(extent.end, range.upperBound)
                if upper > lower { total += upper - lower }
            }
            return total
        }

        let systemClusters = overlap(systemExtents)
        var occupants: [CellOccupant] = []
        var fileClusters: UInt32 = 0
        for record in catalog.files where !record.isResident {
            let inCell = overlap(record.extents)
            guard inCell > 0 else { continue }
            fileClusters += inCell
            occupants.append(CellOccupant(path: catalog.path(of: record),
                                          category: record.category,
                                          clustersInCell: inCell,
                                          fragments: record.extents.coalesced().count,
                                          logicalSize: record.logicalSize))
        }
        let fileCount = occupants.count
        occupants.sort {
            ($0.clustersInCell, $1.path) > ($1.clustersInCell, $0.path)
        }
        return CellContents(clusters: range,
                            occupants: Array(occupants.prefix(max(limit, 0))),
                            fileCount: fileCount,
                            systemClusters: systemClusters,
                            usedClusters: fileClusters + systemClusters)
    }
}
