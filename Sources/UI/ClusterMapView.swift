import SwiftUI
import CoreGraphics

/// Carte des clusters, dans l'esprit de celle qu'affichait le défragmenteur de
/// Windows 95 : un bloc par paquet de clusters, recolorié au fil de la passe.
///
/// Comme sur l'original, un bloc vaut plusieurs clusters — la partition en
/// compte des dizaines de milliers, et l'intérêt de la vue est la silhouette
/// d'ensemble : le volume mité au départ, tassé contre le début à l'arrivée.
///
/// Le dessin ne passe plus par un `Path` par cellule : la carte est une image
/// d'un pixel par cellule, agrandie sans interpolation. Un `Canvas` tenait les
/// 1 248 blocs de la grille historique, mais le plein écran en veut vingt mille
/// et SwiftUI plie bien avant. Fabriquer le buffer et le `CGImage` d'une grille
/// de 192 × 108 coûte 0,1 ms, pour un budget d'image de 16 ms : il n'y a rien à
/// accélérer au-delà, et surtout rien qui justifie Metal.
struct ClusterMapView: View {

    /// Grille à dessiner. Elle vient du modèle qui a produit `shades` : la vue
    /// ne la choisit pas, elle ne saurait pas l'accorder au découpage déjà
    /// fait.
    let grid: MapGrid
    /// Les blocs : leur catégorie, et ce qu'ils portent réellement.
    let shades: [ClusterShade]
    /// Teinte proportionnelle, ou catégorie dominante à pleine couleur.
    ///
    /// La carte en pouce reste **exactement** ce qu'elle était : à 48 × 26 un
    /// bloc vaut quelques dizaines de clusters et le taux d'occupation n'y
    /// dirait rien de plus, alors qu'il délaverait une carte déjà petite. Le
    /// plein écran, lui, a des blocs de milliers de clusters : c'est là que la
    /// modulation porte une information.
    var shading: Bool = false
    /// Accès encore visibles, du plus ancien au plus récent.
    var trail: [MapTrailPoint] = []
    /// Cellule en cours de lecture ou d'écriture, et sens de l'accès. C'est le
    /// liseré de la carte en pouce ; en plein écran, la rémanence le remplace.
    var activeCell: Int? = nil
    var activeIsWrite: Bool = false
    /// Le bloc qu'on a touché, entouré en blanc.
    var selectedCell: Int? = nil
    /// Appelé avec le bloc touché. Sans lui, la carte ne réagit pas au doigt
    /// et laisse le geste à ce qui l'entoure.
    var onCellTap: ((Int) -> Void)? = nil

    /// « Réduire les animations » : pas de rémanence qui s'efface. Le dernier
    /// accès reste montré, par le liseré de la carte en pouce.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let trail = reduceMotion ? [] : self.trail
        let activeCell = self.activeCell ?? (reduceMotion ? self.trail.last?.cell : nil)
        let activeIsWrite = self.activeCell != nil ? self.activeIsWrite : (self.trail.last?.isWrite ?? false)
        return GeometryReader { proxy in
            let side = floor(min(proxy.size.width / CGFloat(grid.columns),
                                 proxy.size.height / CGFloat(grid.rows)))
            ZStack(alignment: .topLeading) {
                ClusterMapImage(grid: grid, shades: shades, shading: shading)

                // La rémanence des accès, par-dessus l'image et non dedans :
                // la carte ne change qu'aux mutations, la traînée à chaque
                // image, et les peindre ensemble referait le `CGImage` soixante
                // fois par seconde pour quelques dizaines de blocs qui bougent.
                if !trail.isEmpty {
                    Canvas { context, _ in
                        for point in trail where point.cell < grid.cellCount {
                            let column = point.cell % grid.columns
                            let row = point.cell / grid.columns
                            let rect = CGRect(x: CGFloat(column) * side,
                                              y: CGFloat(row) * side,
                                              width: side, height: side)
                            let color = point.isWrite ? Theme.write : Theme.read
                            context.fill(Path(rect), with: .color(color.opacity(point.intensity)))
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Le liseré de la cellule active reste en SwiftUI, par-dessus
                // l'image. Il ne peut pas descendre dans le buffer : il fait
                // 1,5 pt de large là où une cellule vaut un seul pixel, donc
                // l'y peindre reviendrait à repeindre la cellule entière — et
                // ses voisines — au lieu de l'entourer.
                if let active = activeCell, active < grid.cellCount {
                    Canvas { context, _ in
                        let column = active % grid.columns
                        let row = active / grid.columns
                        let rect = CGRect(x: CGFloat(column) * side - 1,
                                          y: CGFloat(row) * side - 1,
                                          width: side + 1, height: side + 1)
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                                       with: .color(activeIsWrite ? Theme.write : Theme.read),
                                       lineWidth: 1.5)
                    }
                }

                if let selected = selectedCell, selected < grid.cellCount {
                    Canvas { context, _ in
                        let column = selected % grid.columns
                        let row = selected / grid.columns
                        let inset = max(side, 6)
                        let rect = CGRect(x: CGFloat(column) * side + side / 2 - inset,
                                          y: CGFloat(row) * side + side / 2 - inset,
                                          width: inset * 2, height: inset * 2)
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                                       with: .color(Theme.text), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: side * CGFloat(grid.columns), height: side * CGFloat(grid.rows))
            .modifier(CellTap(grid: grid, side: side, onCellTap: onCellTap))
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .aspectRatio(CGFloat(grid.columns) / CGFloat(grid.rows), contentMode: .fit)
        .modifier(MapAccessibility(shades: shades))
    }
}

/// VoiceOver lit la carte par zones — le début du disque, puis chaque quart —,
/// pas bloc par bloc. Le résumé n'est calculé que si VoiceOver écoute : il
/// parcourt tous les blocs, à chaque image.
private struct MapAccessibility: ViewModifier {
    let shades: [ClusterShade]
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        if voiceOver {
            let zones = MapZone.zones(of: shades)
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel("map.accessibility.label")
                .accessibilityChildren {
                    ForEach(zones.indices, id: \.self) { index in
                        Color.clear.accessibilityLabel(zones[index].description)
                    }
                }
        } else {
            content
        }
    }
}

/// Le toucher d'un bloc. Posé seulement quand quelqu'un l'attend : sinon la
/// carte ne capte rien, et le geste qui l'entoure — ouvrir le plein écran —
/// reste le sien.
private struct CellTap: ViewModifier {
    let grid: MapGrid
    let side: CGFloat
    let onCellTap: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let onCellTap, side > 0 {
            content
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    let column = min(max(Int(location.x / side), 0), grid.columns - 1)
                    let row = min(max(Int(location.y / side), 0), grid.rows - 1)
                    onCellTap(row * grid.columns + column)
                }
        } else {
            content
        }
    }
}

/// L'image de la carte, et rien d'autre.
///
/// Vue à part, et non un bout du corps de `ClusterMapView`, pour que SwiftUI
/// n'en réévalue le corps que lorsque les cellules changent : la cellule active
/// bouge à chaque image alors que la carte, elle, ne change qu'aux mutations.
/// C'est tout le cache qu'il faut ici — le `CGImage` n'est fabriqué qu'une fois
/// par image de rendu, et seulement quand il a une raison de l'être.
private struct ClusterMapImage: View {

    let grid: MapGrid
    let shades: [ClusterShade]
    let shading: Bool

    var body: some View {
        if let image = Self.render(grid: grid, shades: shades, shading: shading) {
            Image(decorative: image, scale: 1)
                // Sans cela, agrandir une image de 48 × 26 donnerait un dégradé
                // flou au lieu d'une carte de blocs.
                .interpolation(.none)
                .antialiased(false)
                .resizable()
        } else {
            Color.clear
        }
    }

    /// Un pixel par cellule. L'agrandissement fait le reste.
    ///
    /// Conséquence assumée : l'écart d'un point entre blocs, que le `Canvas`
    /// ménageait, ne survit pas — un pixel ne se creuse pas. La carte devient
    /// donc un aplat continu là où elle était une grille de petits carrés
    /// espacés. C'est exactement ce que faisait la carte d'origine quand les
    /// blocs devenaient fins, et c'est le prix d'un chemin de rendu unique :
    /// garder les deux — `Canvas` sous un certain seuil, image au-delà —
    /// aurait laissé le chemin qui compte, celui du plein écran, n'être jamais
    /// regardé. Si la respiration entre blocs devait manquer à faible densité,
    /// le remède tient dans le buffer lui-même : rendre n pixels par cellule et
    /// en laisser un de bordure, sans jamais ressortir un `Path`.
    static func render(grid: MapGrid, shades: [ClusterShade], shading: Bool) -> CGImage? {
        guard !shades.isEmpty else { return nil }

        var pixels = shading
            ? ClusterPalette.pixelBuffer(shades)
            : ClusterPalette.flatPixelBuffer(shades)
        // La grille et la carte viennent du même modèle et coïncident ; on
        // ajuste tout de même, parce qu'un buffer plus court que la grille ne
        // ferait pas une image tronquée mais une lecture hors des clous.
        if pixels.count > grid.cellCount {
            pixels.removeLast(pixels.count - grid.cellCount)
        } else if pixels.count < grid.cellCount {
            pixels.append(contentsOf: repeatElement(ClusterPalette.color(.free).pixel,
                                                    count: grid.cellCount - pixels.count))
        }

        // Un `UInt32` se range en mémoire selon le boutisme de la machine —
        // à l'envers sur tout ce qui fait tourner iOS — alors que Core Graphics
        // lit des octets. Sans ce retournement, la composante rouge de chaque
        // pixel est en fait son alpha : la carte s'affiche entièrement en
        // rouges et roses, ce qu'elle a effectivement fait au premier essai.
        for index in pixels.indices { pixels[index] = pixels[index].bigEndian }

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Les octets sont désormais du R, G, B, A dans l'ordre de la mémoire,
        // et `byteOrder32Big` dit à Core Graphics de les lire ainsi.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: grid.columns, height: grid.rows,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: grid.columns * 4,
                       space: space, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Légende : seules les catégories réellement présentes sont listées.
struct ClusterLegend: View {
    let categories: [ClusterCategory]
    let clustersPerCell: Double
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
                            .font(.dynamic(size: 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
                // Une seule entrée pour la nuance, montrée sur une catégorie
                // qui la porte : la répéter pour chacune doublerait la légende.
                if let sample = categories.first(where: { $0 != .free && $0 != .reserved }) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.categoryColor(sample, contiguous: true))
                            .frame(width: 9, height: 9)
                        Text("map.legend.contiguous")
                            .font(.dynamic(size: 10))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
            Text(verbatim: {
                let size = Format.megabytes(
                    UInt64((clustersPerCell * Double(clusterBytes)).rounded()), smallInKilobytes: true)
                return String(localized: "map.legend.blockSize",
                              defaultValue: "1 block \(Format.clustersPerCell(clustersPerCell)) = \(size)",
                              comment: "Légende de la carte : ce que vaut un bloc")
            }())
                .font(.dynamic(size: 10, design: .monospaced))
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
