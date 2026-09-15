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

    /// Couleurs de la carte des clusters. Le défragmenteur d'époque n'en avait
    /// que deux ; ici chaque famille de fichiers a la sienne, pour qu'on voie
    /// l'arborescence se reconstituer bloc par bloc.
    static func categoryColor(_ category: ClusterCategory) -> Color {
        switch category {
        case .free:        return Color(white: 0.16)
        case .system:      return Color(red: 0.36, green: 0.55, blue: 0.86)
        case .application: return Color(red: 0.62, green: 0.48, blue: 0.86)
        case .document:    return Color(red: 0.42, green: 0.76, blue: 0.52)
        case .archive:     return Color(red: 0.38, green: 0.60, blue: 0.62)
        case .churn:       return Color(red: 0.86, green: 0.58, blue: 0.30)
        case .swap:        return Color(red: 0.84, green: 0.36, blue: 0.40)
        case .reserved:    return Color(white: 0.72)
        }
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
