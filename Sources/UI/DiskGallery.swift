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
        case .secretaire: return String(localized: "persona.secretaire", defaultValue: "Office work")
        case .dev:        return String(localized: "persona.dev", defaultValue: "Developer")
        case .famille:    return String(localized: "persona.famille", defaultValue: "Family")
        case .gamer:      return String(localized: "persona.gamer", defaultValue: "Gamer")
        case .poweruser:  return String(localized: "persona.poweruser", defaultValue: "Tinkerer")
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
    /// déduit de sa capacité, de son régime et de son année — et le câble de
    /// l'année, « SATA » en 2012. Un disque nommé porte son nom :
    /// « VelociRaptor 500 Go · 10 000 tr/min ».
    var hardwareLine: String {
        let name = disk.reference?.shortName ?? DriveInterface.era(year: year).busName
        return "\(name) \(capacityLabel) · \(rpmLabel)"
    }

    /// Capacité commerciale, en gigaoctets de mille mégaoctets : « 1,08 Go »,
    /// « 6,4 Go », « 40 Go », comme sur l'étiquette. Celle d'un disque nommé
    /// est celle de sa fiche : « 1 To ».
    var capacityLabel: String {
        // Un disque nommé porte la capacité de son étiquette, en unités de mille.
        let bytes = disk.reference.map { Double($0.capacityBytes) } ?? Double(disk.sizeMB) * 1e6
        guard bytes >= 1e9 else {
            return String(localized: "disk.capacity.megabytes", defaultValue: "\(disk.sizeMB) MB")
        }
        if bytes >= 1e12 {
            let value = (bytes / 1e12).formatted(.number.precision(.fractionLength(0...1)))
            return String(localized: "disk.capacity.terabytes", defaultValue: "\(value) TB")
        }
        // Deux décimales au plus, et les zéros de fin retirés : « 1,08 Go »,
        // « 6,4 Go », « 40 Go », comme sur l'étiquette — et plus aucune au-delà
        // de cent : l'étiquette du VelociRaptor dit « 500 Go », pas « 500,11 ».
        // Le séparateur décimal est celui de la langue.
        let value = (bytes / 1e9)
            .formatted(.number.precision(.fractionLength(0...(bytes >= 1e11 ? 0 : 2))))
        return String(localized: "disk.capacity.gigabytes", defaultValue: "\(value) GB")
    }

    var rpmLabel: String {
        let value = Format.integer(disk.rpm)
        return String(localized: "disk.rpm", defaultValue: "\(value) rpm")
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
    /// Le disque qu'on écoute, pour le marquer dans la liste.
    var playingDiskID: String?

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
                    FilterChip(title: String(localized: "gallery.filter.allYears", defaultValue: "All"), isOn: year == nil) { year = nil }
                    ForEach(years, id: \.self) { y in
                        FilterChip(title: String(y), isOn: year == y) { year = (year == y) ? nil : y }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FilterChip(title: String(localized: "gallery.filter.allPersonas", defaultValue: "All"), isOn: persona == nil) { persona = nil }
                    ForEach(Persona.allCases) { p in
                        FilterChip(title: p.title, isOn: persona == p) { persona = (persona == p) ? nil : p }
                    }
                }
            }

            LazyVStack(spacing: 10) {
                ForEach(shown, id: \.id) { spec in
                    NavigationLink(value: spec.id) {
                        DiskCard(spec: spec, fragmentedRatio: model.fragmentedRatios[spec.id],
                                 state: history.state(of: spec.id),
                                 isPlaying: playingDiskID == spec.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            if shown.isEmpty {
                Text("gallery.empty")
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
    /// C'est ce disque-là qu'on écoute en ce moment.
    var isPlaying = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spec.displayName)
                        .font(.dynamic(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if isPlaying {
                        Text("gallery.playing.badge")
                            .font(.dynamic(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.read))
                            .accessibilityLabel("gallery.playing.label")
                    }
                    Spacer()
                    Text(spec.fileSystemLabel)
                        .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
                }
                Text(verbatim: "\(spec.hardwareLine) · \(spec.osName)")
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
                    Text(verbatim: String(localized: "gallery.alreadyGenerated",
                                          defaultValue: "already generated · \(Format.percent(fragmentedRatio)) fragmented"))
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
                            Button("disk.action.editHistory", systemImage: "pencil") { onEdit(spec) }
                        }
                        Button("disk.action.duplicateAndEdit", systemImage: "plus.square.on.square") {
                            onEdit(library.duplicate(spec))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("disk.action.buildFrom")
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
        case .install: return String(localized: "pass.title.install",
                                     defaultValue: "Installing \(digest.toolLabel)")
        case .boot:    return String(localized: "pass.title.boot", defaultValue: "Boot")
        case .day:     return String(localized: "pass.title.day",
                                     defaultValue: "A day of use, \(digest.toolLabel.lowercased())")
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
            Text("disk.passes.header")
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
            Text(Format.duration(digest.duration))
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
        let when = Format.sinceNow(digest.finishedAt)
        guard let fragments = digest.fragmentsAfter, let holes = digest.holesAfter else { return when }
        return String(localized: "disk.pass.subtitle",
                      defaultValue: "\(Format.integer(fragments)) pieces · \(Format.integer(holes)) holes · \(when)",
                      comment: "Ce qu'une passe a donné, et quand")
    }
}
