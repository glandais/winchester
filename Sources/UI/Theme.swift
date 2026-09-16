import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.070)
    static let panel = Color(red: 0.098, green: 0.104, blue: 0.125)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.52)

    /// Ambre : lecture, voyant d'activité.
    static let read = Color(red: 1.0, green: 0.70, blue: 0.28)
    /// Turquoise : écriture.
    static let write = Color(red: 0.36, green: 0.82, blue: 0.82)
    static let arm = Color(red: 0.78, green: 0.80, blue: 0.86)

    /// Couleurs de la carte des clusters, telles que le modèle les définit.
    ///
    /// La palette elle-même vit dans `ClusterPalette` : le rendu de la carte
    /// écrit des pixels et ne peut rien faire d'une `Color`. Ici on ne fait que
    /// la traduire pour SwiftUI, de sorte que la légende et la carte ne
    /// puissent pas diverger.
    static func categoryColor(_ category: ClusterCategory, contiguous: Bool = false) -> Color {
        let c = ClusterPalette.color(category, contiguous: contiguous)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    static func phaseColor(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.42, green: 0.44, blue: 0.52),
            Color(red: 0.52, green: 0.56, blue: 0.70),
            Color(red: 0.40, green: 0.62, blue: 0.80),
            Color(red: 0.34, green: 0.74, blue: 0.70),
            Color(red: 1.00, green: 0.62, blue: 0.24),
            Color(red: 0.94, green: 0.48, blue: 0.36),
            Color(red: 0.80, green: 0.46, blue: 0.72),
            Color(red: 0.40, green: 0.42, blue: 0.50),
            Color(red: 0.52, green: 0.78, blue: 0.42),
            Color(red: 0.72, green: 0.84, blue: 0.32),
            Color(red: 0.60, green: 0.66, blue: 0.44),
            Color(red: 0.32, green: 0.34, blue: 0.40),
        ]
        return palette[index % palette.count]
    }
}

extension Double {
    var clockString: String {
        let minutes = Int(self) / 60
        let seconds = self - Double(minutes * 60)
        return String(format: "%01d:%04.1f", minutes, seconds)
    }
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

/// Le titre d'un onglet, comme en tête de chaque écran des maquettes.
struct ScreenTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
