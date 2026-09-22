import SwiftUI

/// Les adresses que l'app cite, toutes ici : le site (`docs/`), la fiche de
/// l'App Store et le dépôt.
///
/// Chaque ligne s'ouvre dans Safari ou dans l'App Store : l'app elle-même ne
/// touche pas au réseau — `docs/privacy/` le dit. Aucun lien de don ici : un
/// pourboire, dans l'app, passerait par l'achat intégré (directive 3.1.1,
/// chantier 36).
enum AboutLink: CaseIterable, Identifiable {
    case website
    case support
    case privacy
    case source
    case rate
    case moreApps

    static let appStoreID = "6814382619"
    static let developerID = "1891310404"

    var id: Self { self }

    var url: URL {
        switch self {
        case .website:  return URL(string: "https://glandais.github.io/winchester/")!
        case .support:  return URL(string: "https://glandais.github.io/winchester/support/")!
        case .privacy:  return URL(string: "https://glandais.github.io/winchester/privacy/")!
        case .source:   return URL(string: "https://github.com/glandais/winchester")!
        case .rate:     return URL(string: "https://apps.apple.com/app/id\(Self.appStoreID)?action=write-review")!
        case .moreApps: return URL(string: "https://apps.apple.com/developer/id\(Self.developerID)")!
        }
    }

    var symbol: String {
        switch self {
        case .website:  return "globe"
        case .support:  return "questionmark.circle"
        case .privacy:  return "hand.raised"
        case .source:   return "chevron.left.forwardslash.chevron.right"
        case .rate:     return "star"
        case .moreApps: return "square.grid.2x2"
        }
    }

    var title: String {
        switch self {
        case .website:
            return String(localized: "settings.about.website", defaultValue: "Website",
                          comment: "Ligne « À propos » des Réglages : le site de l'app")
        case .support:
            return String(localized: "settings.about.support", defaultValue: "Help and support",
                          comment: "Ligne « À propos » des Réglages : la page d'assistance du site")
        case .privacy:
            return String(localized: "settings.about.privacy", defaultValue: "Privacy policy",
                          comment: "Ligne « À propos » des Réglages : la politique de confidentialité")
        case .source:
            return String(localized: "settings.about.source", defaultValue: "Source code on GitHub",
                          comment: "Ligne « À propos » des Réglages : le dépôt GitHub")
        case .rate:
            return String(localized: "settings.about.rate", defaultValue: "Rate on the App Store",
                          comment: "Ligne « À propos » des Réglages : écrire un avis sur l'App Store")
        case .moreApps:
            return String(localized: "settings.about.moreApps", defaultValue: "More apps by the developer",
                          comment: "Ligne « À propos » des Réglages : la page développeur de l'App Store")
        }
    }
}

/// La section « À propos », en bas des Réglages : six liens sortants, dans un
/// seul panneau.
struct AboutSection: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.about.title")
                .font(.dynamic(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(AboutLink.allCases) { link in
                    if link != AboutLink.allCases.first {
                        Divider().overlay(Theme.stroke)
                    }
                    row(link)
                }
            }
            .panel()
            Text("settings.about.note")
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ link: AboutLink) -> some View {
        Link(destination: link.url) {
            HStack(spacing: 12) {
                Image(systemName: link.symbol)
                    .font(.dynamic(size: 15))
                    .foregroundStyle(Theme.write)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(verbatim: link.title)
                    .font(.dynamic(size: 15))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}
