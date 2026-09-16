import SwiftUI
import DiskCore

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

/// Les nombres et les dates tels qu'on les écrit en français : espace fine
/// insécable entre les milliers, virgule décimale, mois en toutes lettres.
enum FrenchFormat {

    private static let thin = "\u{202F}"

    static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "−" : "") + groups.joined(separator: thin)
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Un rapport entre 0 et 1, arrondi à l'unité — sauf sous 10 %, où la
    /// décimale dit encore quelque chose.
    static func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        if value > 0 && value < 0.05 { return "<\u{00A0}0,1\u{00A0}%" }
        let text = value < 10 && value > 0 ? decimal(value, digits: 1) : integer(Int(value.rounded()))
        return text + "\u{00A0}%"
    }

    /// Une taille en Mo, en Go au-delà d'un gigaoctet, avec une décimale sous
    /// dix mégaoctets ; en Ko sous un mégaoctet si on le demande.
    static func megabytes(_ bytes: UInt64, smallInKilobytes: Bool = false) -> String {
        if smallInKilobytes && bytes < 1_048_576 {
            return integer(Int(bytes / 1_024)) + "\u{00A0}Ko"
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1_024 { return decimal(mb / 1_024, digits: 1) + "\u{00A0}Go" }
        if mb < 10 { return decimal(mb, digits: 1) + "\u{00A0}Mo" }
        return integer(Int(mb.rounded())) + "\u{00A0}Mo"
    }

    /// Un temps écouté : « 42 s », « 12 min 41 », « 1 h 07 ».
    static func duration(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        if h > 0 { return "\(h)\u{00A0}h\u{00A0}" + String(format: "%02d", m) }
        if m > 0 { return "\(m)\u{00A0}min\u{00A0}" + String(format: "%02d", s) }
        return "\(s)\u{00A0}s"
    }

    private static let months = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
                                 "août", "septembre", "octobre", "novembre", "décembre"]

    /// « 14 mars 1997 »
    static func date(_ date: CivilDate) -> String {
        let month = (1...12).contains(date.month) ? months[date.month - 1] : "\(date.month)"
        return "\(date.day == 1 ? "1er" : String(date.day)) \(month) \(date.year)"
    }
}
