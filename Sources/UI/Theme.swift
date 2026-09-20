import SwiftUI
import DiskCore

enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.070)
    static let panel = Color(red: 0.098, green: 0.104, blue: 0.125)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color(white: 0.92)
    /// Texte secondaire. #858585 fait 4,7:1 sur un panneau : juste au-dessus du
    /// seuil pour un texte courant, et en dessous dès qu'on l'atténue encore.
    /// « Augmenter le contraste » le remonte à 7,7:1.
    static let dim = Color(uiColor: UIColor { traits in
        UIColor(white: traits.accessibilityContrast == .high ? 0.68 : 0.52, alpha: 1)
    })

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
                .font(.dynamic(size: 28, weight: .semibold, design: .rounded))
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

    static func integer(_ value: Int) -> String { FrenchUnits.integer(value) }

    static func decimal(_ value: Double, digits: Int) -> String {
        FrenchUnits.decimal(value, digits: digits)
    }

    /// La part d'un bloc de carte : « = 43 clusters » quand elle tombe juste,
    /// « ≈ 3,8 clusters » sinon — un bloc de plein écran vaut rarement un
    /// nombre entier de clusters. Le seuil ne sert qu'à absorber l'erreur de
    /// la division flottante : 9,97 clusters ne s'écrivent pas « = 10 ».
    static func clustersPerCell(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9 { return "= \(integer(Int(rounded))) clusters" }
        // 9,97 arrondi à une décimale s'écrirait « 10,0 » : la virgule n'y dit
        // plus rien.
        let text = decimal(value, digits: value < 10 ? 1 : 0)
        return "≈ \(text.hasSuffix(",0") ? String(text.dropLast(2)) : text) clusters"
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
    ///
    /// La conversion est celle de `FrenchUnits`, et il n'y en a pas d'autre :
    /// voir ce qu'une seconde a coûté (`UX_REVIEW.md` §3).
    static func megabytes(_ bytes: UInt64, smallInKilobytes: Bool = false) -> String {
        FrenchUnits.megabytes(bytes, smallInKilobytes: smallInKilobytes)
    }

    /// Depuis quand, en français courant : « à l'instant », « il y a 3 min »,
    /// « hier », puis la date en toutes lettres au-delà d'une semaine.
    ///
    /// Écrit à la main comme le reste de ce fichier : `RelativeDateTimeFormatter`
    /// dirait « il y a 3 minutes » là où une carte n'a la place que de « 3 min »,
    /// et suivrait la locale de l'appareil alors que toute l'application est en
    /// français.
    static func sinceNow(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "à l'instant" }
        if minutes < 60 { return "il y a \(minutes)\u{00A0}min" }
        let hours = minutes / 60
        if hours < 24 { return "il y a \(hours)\u{00A0}h" }
        let days = hours / 24
        if days == 1 { return "hier" }
        if days < 7 { return "il y a \(days)\u{00A0}jours" }
        let civil = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = civil.year, let month = civil.month, let day = civil.day else { return "plus tôt" }
        return "le " + Self.date(CivilDate(year: year, month: month, day: day))
    }

    /// Un temps écouté : « 42 s », « 12 min 41 », « 1 h 07 ».
    static func duration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
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

extension Font {
    /// La police des écrans : une taille de maquette, mise à l'échelle de la
    /// taille de texte choisie dans les réglages de l'iPhone.
    ///
    /// `Font.system(size:)` ne suit pas Dynamic Type, et `Font.custom(_:size:relativeTo:)`
    /// perdrait le dessin monospace des chiffres et arrondi des titres : on passe
    /// donc par `UIFontMetrics`, avec le style « corps » pour tout le monde — les
    /// maquettes n'ont pas de hiérarchie de styles, seulement des tailles.
    ///
    /// L'agrandissement s'arrête à la troisième taille d'accessibilité : au-delà,
    /// une tuile de deux colonnes ne tient plus un chiffre de six caractères, et
    /// l'app deviendrait une suite de troncatures. Ce qui est déjà grand — titres,
    /// gros chiffres, boutons du transport — grandit d'un quart au plus.
    static func dynamic(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: TypeScale.scaled(size), weight: weight, design: design)
    }
}

/// La taille de texte de l'iPhone, lue sur l'application.
enum TypeScale {

    static let largest = UIContentSizeCategory.accessibilityLarge
    /// La même borne pour les polices du système — titres de navigation, barre
    /// d'onglets.
    static let largestDynamicTypeSize = DynamicTypeSize.accessibility3

    static func scaled(_ size: CGFloat) -> CGFloat {
        let category = MainActor.assumeIsolated { UIApplication.shared.preferredContentSizeCategory }
        let clamped = category > largest ? largest : category
        let traits = UITraitCollection(preferredContentSizeCategory: clamped)
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
        return size >= 24 ? min(scaled, size * 1.25) : scaled
    }
}
