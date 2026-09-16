import SwiftUI
import DiskCore

/// Les profils de la galerie, tels que les nomment les scénarios.
///
/// Le profil n'est pas un champ de `ProfileSpec` : il est le préfixe de son
/// identifiant (`secretaire-1996`). Un identifiant inconnu n'a pas de profil,
/// et n'apparaît que sous « Tous ».
enum Persona: String, CaseIterable, Identifiable {
    case secretaire
    case dev
    case famille
    case gamer
    case poweruser

    var id: String { rawValue }

    /// Le nom que portent les `displayName` des scénarios.
    var title: String {
        switch self {
        case .secretaire: return "Secrétariat"
        case .dev:        return "Développeur"
        case .famille:    return "Famille"
        case .gamer:      return "Joueur"
        case .poweruser:  return "Bidouilleur"
        }
    }

    init?(spec: ProfileSpec) {
        guard let prefix = spec.id.split(separator: "-").first else { return nil }
        self.init(rawValue: String(prefix))
    }
}

extension ProfileSpec {

    var year: Int { timeline.start.year }

    /// « IDE 850 Mo · 5 400 tr/min » : le disque n'a pas de marque, le modèle le
    /// déduit de sa capacité, de son régime et de son année.
    var hardwareLine: String { "IDE \(capacityLabel) · \(rpmLabel)" }

    /// Capacité commerciale, en gigaoctets de mille mégaoctets : « 1,08 Go »,
    /// « 6,4 Go », « 40 Go », comme sur l'étiquette.
    var capacityLabel: String {
        guard disk.sizeMB >= 1_000 else { return "\(disk.sizeMB) Mo" }
        var digits = String(format: "%.2f", Double(disk.sizeMB) / 1_000)
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.hasSuffix(".") { digits.removeLast() }
        return digits.replacingOccurrences(of: ".", with: ",") + " Go"
    }

    var rpmLabel: String {
        String(format: "%d\u{202F}%03d tr/min", disk.rpm / 1_000, disk.rpm % 1_000)
    }

    var fileSystemLabel: String {
        switch fileSystem.type {
        case .fat16: return "FAT16"
        case .vfat:  return "VFAT"
        case .fat32: return "FAT32"
        case .ntfs:  return "NTFS"
        }
    }

    /// Le nom du système, celui que dit aussi le démarrage.
    var osName: String {
        BootScript.Era.all.first { $0.os == os }?.osName ?? os
    }
}

/// Les vingt disques en cartes, filtrables par époque et par profil.
///
/// Une carte ne dit que ce qui est connu avant fabrication. Le taux de
/// fichiers fragmentés n'apparaît que pour un disque déjà généré dans la
/// session : avant, il n'existe pas.
struct DiskGallery: View {

    @ObservedObject var model: DiskLibraryModel

    @State private var year: Int?
    @State private var persona: Persona?

    private var years: [Int] { model.byEpoch.map(\.year) }

    private var shown: [ProfileSpec] {
        model.scenarios
            .filter { year == nil || $0.year == year }
            .filter { persona == nil || Persona(spec: $0) == persona }
            .sorted { ($0.year, $0.displayName) < ($1.year, $1.displayName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "Toutes", isOn: year == nil) { year = nil }
                    ForEach(years, id: \.self) { y in
                        FilterChip(title: String(y), isOn: year == y) { year = (year == y) ? nil : y }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: "Tous", isOn: persona == nil) { persona = nil }
                    ForEach(Persona.allCases) { p in
                        FilterChip(title: p.title, isOn: persona == p) { persona = (persona == p) ? nil : p }
                    }
                }
            }

            LazyVStack(spacing: 10) {
                ForEach(shown, id: \.id) { spec in
                    NavigationLink(value: spec.id) {
                        DiskCard(spec: spec, fragmentedRatio: model.fragmentedRatios[spec.id])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            if shown.isEmpty {
                Text("Aucun disque pour ce filtre.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.background : Theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isOn ? Theme.read : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct DiskCard: View {
    let spec: ProfileSpec
    let fragmentedRatio: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spec.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(spec.fileSystemLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
                }
                Text("\(spec.hardwareLine) · \(spec.osName)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = spec.summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fragmentedRatio {
                    Text("déjà généré · \(FrenchFormat.percent(fragmentedRatio)) fragmentés")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.read)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .contentShape(Rectangle())
    }
}

/// Un disque de la galerie, ouvert : il se génère en arrivant.
struct DiskDetailScreen: View {

    @ObservedObject var library: DiskLibraryModel
    let id: String
    let onHandover: DiskHandover

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                DiskLibraryView(model: library, onHandover: onHandover)
                    .padding(16)
            }
        }
        // Le titre est dans la page, en grand : la barre ne le répète pas.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear { library.open(id) }
    }
}
