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
    /// Ce que chaque disque garde de ce qu'on lui a fait, d'un lancement à
    /// l'autre : c'est ce que porte la dernière ligne d'une carte.
    @ObservedObject var history: PassHistory

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
                        DiskCard(spec: spec, fragmentedRatio: model.fragmentedRatios[spec.id],
                                 state: history.state(of: spec.id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            if shown.isEmpty {
                Text("Aucun disque pour ce filtre.")
                    .font(.dynamic(size: 12))
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
                .font(.dynamic(size: 12, weight: isOn ? .semibold : .regular))
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

struct DiskCard: View {
    let spec: ProfileSpec
    let fragmentedRatio: Double?
    /// Ce qu'on a déjà fait à ce disque, gardé d'un lancement à l'autre.
    var state: DiskState?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spec.displayName)
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(spec.fileSystemLabel)
                        .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
                }
                Text("\(spec.hardwareLine) · \(spec.osName)")
                    .font(.dynamic(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = spec.summary {
                    Text(summary)
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // L'état du disque prime sur son taux de départ : c'est ce
                // qu'on lui a fait qu'on vient chercher en revenant, et la
                // carte ne disait rien jusqu'ici (`UX_REVIEW.md` §2.1).
                if let digest = state?.tidied ?? state?.last {
                    DiskStateBadge(digest: digest)
                } else if let fragmentedRatio {
                    Text("déjà généré · \(FrenchFormat.percent(fragmentedRatio)) fragmentés")
                        .font(.dynamic(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.read)
                }
            }
            Image(systemName: "chevron.right")
                .font(.dynamic(size: 12, weight: .semibold))
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
    /// Ce que ce disque garde de ce qu'on lui a fait, d'un lancement à l'autre.
    @ObservedObject var history: PassHistory
    let id: String
    /// Les passes entendues sur ce disque, et le bilan qu'on en ouvre.
    var records: [PassRecord] = []
    var onOpenRecord: (PassRecord) -> Void = { _ in }
    /// Ouvre l'assistant sur un profil : une copie d'un disque de la galerie,
    /// ou le disque construit lui-même.
    var onEdit: (ProfileSpec) -> Void = { _ in }
    let onHandover: DiskHandover

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DiskLibraryView(model: library, onHandover: onHandover,
                                    state: history.state(of: id),
                                    tidyMap: tidied?.map, tidyDisk: tidied?.disk)
                    if !history.state(of: id).isEmpty { heard }
                }
                .padding(16)
            }
        }
        // Le titre est dans la page, en grand : la barre ne le répète pas.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            if let spec = library.spec(id: id) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if CustomDiskStore.isCustom(id) {
                            Button("Modifier l'histoire", systemImage: "pencil") { onEdit(spec) }
                        }
                        Button("Dupliquer et modifier", systemImage: "plus.square.on.square") {
                            onEdit(library.duplicate(spec))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Construire à partir de ce disque")
                }
            }
        }
        .onAppear { library.open(id) }
    }

    private func icon(of digest: PassDigest) -> String {
        switch digest.kind {
        case .defrag:  return "waveform"
        case .boot:    return "power"
        case .install: return "opticaldisc"
        case .day:     return "calendar"
        }
    }

    private func title(of digest: PassDigest) -> String {
        switch digest.kind {
        case .defrag:  return digest.toolLabel
        case .install: return "Installation de \(digest.toolLabel)"
        case .boot:    return "Démarrage"
        case .day:     return "Journée d'usage, \(digest.toolLabel.lowercased())"
        }
    }

    /// Le disque tel que le dernier outil l'a laissé pendant cette session, et
    /// sa carte : de quoi montrer l'avant et l'après sur la fiche.
    ///
    /// Les deux viennent du bilan complet, qui meurt avec la session : au
    /// relancement il ne reste que la ligne d'état, et la bascule disparaît.
    /// Le disque rangé se refait à chaque passage — reposer les extents d'un
    /// volume de quelques milliers de fichiers coûte quelques millisecondes,
    /// et le garder demanderait de le porter dans l'état d'une vue.
    private var tidied: (map: (grid: MapGrid, shades: [ClusterShade]), disk: GeneratedDisk)? {
        guard let record = records.last(where: {
            $0.kind == .defrag && $0.diskID == id && $0.endMap != nil && !$0.arrangement.isEmpty
        }), let map = record.endMap, let original = record.disk else { return nil }
        let places = Dictionary(record.arrangement.map { ($0.id, $0.extents) },
                                uniquingKeysWith: { _, last in last })
        return (map, original.rearranged(extents: places))
    }

    /// Ce qu'on a déjà écouté de ce disque, de la plus récente à la plus
    /// ancienne passe.
    ///
    /// La liste est celle des **résumés**, qui survivent au relancement ; le
    /// bilan complet, lui, ne vit que le temps de la session qui l'a produit.
    /// Une ligne dont le bilan est encore là s'ouvre ; les plus anciennes
    /// disent ce qu'elles ont donné sans prétendre le remontrer.
    private var heard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PASSES ENTENDUES")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            ForEach(history.state(of: id).passes) { digest in
                let record = records.first { $0.id == digest.id && $0.kind != .boot }
                Button {
                    if let record { onOpenRecord(record) }
                } label: {
                    row(digest, openable: record != nil)
                }
                .buttonStyle(.plain)
                // Pas `disabled` : il grise la ligne entière, et une passe
                // d'avant-hier n'est pas une commande indisponible — c'est un
                // fait, qui se lit. Seul le chevron dit ce qui s'ouvre.
                .allowsHitTesting(record != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func row(_ digest: PassDigest, openable: Bool) -> some View {
        HStack {
            Image(systemName: icon(of: digest))
                .foregroundStyle(Theme.dim)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(of: digest))
                    .font(.dynamic(size: 13))
                    .foregroundStyle(Theme.text)
                Text(subtitle(of: digest))
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            Text(FrenchFormat.duration(digest.duration))
                .font(.dynamic(size: 12, design: .monospaced))
                .foregroundStyle(Theme.dim)
            if openable {
                Image(systemName: "chevron.right")
                    .font(.dynamic(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
        }
        .contentShape(Rectangle())
    }

    /// Ce que la passe a donné, et quand : la date est ce qui manquait pour
    /// s'y retrouver entre deux passes du même outil.
    private func subtitle(of digest: PassDigest) -> String {
        let when = FrenchFormat.sinceNow(digest.finishedAt)
        guard let fragments = digest.fragmentsAfter, let holes = digest.holesAfter else { return when }
        return "\(FrenchFormat.integer(fragments)) morceaux · \(FrenchFormat.integer(holes)) trous · \(when)"
    }
}
