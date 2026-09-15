import SwiftUI

/// Carte des clusters, dans l'esprit de celle qu'affichait le défragmenteur de
/// Windows 95 : un bloc par paquet de clusters, recolorié au fil de la passe.
///
/// Comme sur l'original, un bloc vaut plusieurs clusters — la partition en
/// compte des dizaines de milliers, et l'intérêt de la vue est la silhouette
/// d'ensemble : le volume mité au départ, tassé contre le début à l'arrivée.
struct ClusterMapView: View {

    static var columns: Int { ClusterMapPlayer.columns }
    static var rows: Int { ClusterMapPlayer.rows }

    let cells: [UInt8]
    let clustersPerCell: Int
    /// Cellule en cours de lecture ou d'écriture, et sens de l'accès.
    let activeCell: Int?
    let activeIsWrite: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = floor(min(proxy.size.width / CGFloat(Self.columns),
                                 proxy.size.height / CGFloat(Self.rows)))
            Canvas { context, _ in
                let inset: CGFloat = side > 5 ? 1 : 0.5
                for index in 0..<min(cells.count, Self.columns * Self.rows) {
                    let column = index % Self.columns
                    let row = index / Self.columns
                    let rect = CGRect(x: CGFloat(column) * side,
                                      y: CGFloat(row) * side,
                                      width: side - inset, height: side - inset)
                    let category = ClusterCategory(rawValue: cells[index]) ?? .free
                    context.fill(Path(roundedRect: rect, cornerRadius: side > 6 ? 1 : 0),
                                 with: .color(Theme.categoryColor(category)))
                }

                guard let active = activeCell, active < Self.columns * Self.rows else { return }
                let column = active % Self.columns
                let row = active / Self.columns
                let rect = CGRect(x: CGFloat(column) * side - 1,
                                  y: CGFloat(row) * side - 1,
                                  width: side + 1, height: side + 1)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                               with: .color(activeIsWrite ? Theme.write : Theme.read),
                               lineWidth: 1.5)
            }
            .frame(width: side * CGFloat(Self.columns), height: side * CGFloat(Self.rows))
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .aspectRatio(CGFloat(Self.columns) / CGFloat(Self.rows), contentMode: .fit)
    }
}

/// Légende : seules les catégories réellement présentes sont listées.
struct ClusterLegend: View {
    let categories: [ClusterCategory]
    let clustersPerCell: Int
    let clusterBytes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(spacing: 10) {
                ForEach(categories, id: \.rawValue) { category in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.categoryColor(category))
                            .frame(width: 9, height: 9)
                        Text(category.label)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            Text("1 bloc = \(clustersPerCell) clusters = \(clustersPerCell * clusterBytes / 1024) Ko")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim.opacity(0.8))
        }
    }
}

/// Disposition en lignes qui se replient — la légende compte huit entrées et ne
/// tient pas sur une ligne d'iPhone.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
