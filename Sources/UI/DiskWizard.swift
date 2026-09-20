import SwiftUI
import DiskCore

// MARK: - Ce que l'assistant propose

/// Les systèmes qu'un démarrage sait raconter, et ce qu'ils installent.
///
/// Un profil nomme son système deux fois : par son époque (`os`, que lit le
/// démarrage) et par les manifestes qu'il pose sur le disque (`installs`). Les
/// deux vont ensemble ; l'assistant les tient d'une seule main.
struct SystemOption: Identifiable {
    let id: String
    let name: String
    let year: Int
    let manifests: [String]

    static let all: [SystemOption] = [
        SystemOption(id: "msdos-6.22+win31", name: "MS-DOS 6.22 et Windows 3.1", year: 1994,
                     manifests: ["msdos-6", "win31"]),
        SystemOption(id: "win95-osr1", name: "Windows 95", year: 1996, manifests: ["win95"]),
        SystemOption(id: "win98se", name: "Windows 98 SE", year: 1999, manifests: ["win98se"]),
        SystemOption(id: "winxp-sp1", name: "Windows XP", year: 2002, manifests: ["winxp"]),
        SystemOption(id: "vista", name: "Windows Vista", year: 2007, manifests: ["vista"]),
    ]

    static var manifestIDs: Set<String> { Set(all.flatMap(\.manifests)) }
}

/// L'année de sortie des logiciels du catalogue, pour dire ce qui est d'époque.
enum SoftwareYears {
    static let year: [String: Int] = [
        "bc31": 1992, "works3": 1993, "office95": 1995, "vc42": 1996, "netscape3": 1996,
        "doom2": 1994, "quake": 1996, "office97": 1997, "ie5": 1999, "winamp": 1997,
        "halflife": 1998, "officexp": 2001, "vsnet": 2002, "ut2003": 2002, "nero": 1997,
        "office2007": 2007, "crysis": 2007, "itunes7": 2006,
    ]

    /// Les logiciels proposés, du plus ancien au plus récent ; les systèmes
    /// sont choisis à part.
    static var applications: [AppManifest] {
        AppLibrary.all
            .filter { !SystemOption.manifestIDs.contains($0.id) }
            .sorted { (year[$0.id] ?? 0, $0.displayName) < (year[$1.id] ?? 0, $1.displayName) }
    }
}

extension CivilDate {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }

    init(_ date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}

extension ProfileSpec {

    /// Le point de départ d'un disque neuf : un poste de bureau de 1996.
    static func blank() -> ProfileSpec {
        ProfileSpec(id: CustomDiskStore.newIdentifier(),
                    displayName: "Nouveau disque",
                    summary: nil,
                    seed: UInt64.random(in: 1...9_999_999),
                    disk: DiskSpec(sizeMB: 1_080, rpm: 5_400, averageSeekMs: 12),
                    fileSystem: FileSystemSpec(type: .vfat),
                    os: "win95-osr1",
                    timeline: TimelineSpec(start: CivilDate(year: 1996, month: 3, day: 1),
                                           end: CivilDate(year: 1998, month: 3, day: 1)),
                    installs: ["win95", "office95"],
                    activity: ActivitySpec(
                        maintenance: .init(updatesPerYear: 2, filesPerUpdate: 40),
                        browse: .init(perDay: 1, pagesPerSession: 15),
                        office: .init(newDocumentsPerWeek: 5, savesPerDocumentPerWeek: 1)))
    }
}

// MARK: - L'assistant

/// Construire un disque usagé — maquettes 06 et 07.
///
/// Six étapes, et un seul brouillon qui passe de l'une à l'autre. On y règle
/// l'**histoire** du disque : son matériel, son format, ce qu'on y installe,
/// combien de temps il sert et comment. Jamais le résultat : la fragmentation
/// ne se lit qu'à la dernière étape, une fois le disque fabriqué.
struct DiskWizardSheet: View {

    @ObservedObject var library: DiskLibraryModel
    let onHandover: DiskHandover

    @State private var draft: ProfileSpec
    @State private var step = 0
    @State private var saved = false
    /// Le disque que la galerie montrait avant l'assistant.
    ///
    /// L'assistant fabrique par `library.build`, qui prend la sélection de la
    /// galerie : la fiche ouverte en dessous se mettait alors à montrer le
    /// brouillon, et y restait après « Fermer » (`UX_REVIEW.md` §2.7). On lui
    /// rend sa sélection en partant.
    @State private var previousSelection: String?
    /// Fermer perdrait un brouillon fabriqué et non enregistré.
    @State private var confirmsClose = false
    @Environment(\.dismiss) private var dismiss

    init(library: DiskLibraryModel, spec: ProfileSpec, onHandover: @escaping DiskHandover) {
        self.library = library
        self.onHandover = onHandover
        _draft = State(initialValue: spec)
        _previousSelection = State(initialValue: library.selectedID)
    }

    /// Un brouillon fabriqué que « Mes disques » ne connaît pas : le fermer le
    /// perd, et il a coûté six étapes et une fabrication.
    private var losesDraft: Bool {
        library.selectedID == draft.id && library.state.disk != nil
            && !library.customs.contains { $0.id == draft.id }
    }

    /// Ferme, en rendant à la galerie le disque qu'elle montrait.
    private func close() {
        if library.selectedID != previousSelection, let previousSelection {
            library.selectedID = previousSelection
        }
        dismiss()
    }

    private static let titles = ["Le matériel", "Le format", "Le système et les logiciels",
                                 "La période d'usage", "Les habitudes", "La graine et le résultat"]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ÉTAPE \(step + 1) SUR 6")
                                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.read)
                            Text(Self.titles[step])
                                .font(.dynamic(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.text)
                        }
                        switch step {
                        case 0: HardwareStep(draft: $draft)
                        case 1: FormatStep(draft: $draft)
                        case 2: SoftwareStep(draft: $draft)
                        case 3: PeriodStep(draft: $draft)
                        case 4: HabitsStep(draft: $draft)
                        default: resultStep
                        }
                        IssuesPanel(issues: draft.issues)
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { stepBar }
            .navigationTitle(draft.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        if losesDraft { confirmsClose = true } else { close() }
                    }
                }
            }
            .confirmationDialog("Fermer sans enregistrer ?", isPresented: $confirmsClose,
                                titleVisibility: .visible) {
                Button("Enregistrer et fermer") {
                    library.save(draft)
                    saved = true
                    close()
                }
                Button("Fermer sans enregistrer", role: .destructive) { close() }
                Button("Continuer", role: .cancel) {}
            } message: {
                Text("« \(draft.displayName) » est fabriqué mais n'est pas dans Mes disques : "
                     + "sa graine et son histoire seraient perdues.")
            }
        }
        .tint(Theme.read)
        .preferredColorScheme(.dark)
    }

    private var stepBar: some View {
        HStack(spacing: 10) {
            Button {
                step -= 1
            } label: {
                Text("Retour")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.16)))
            }
            .disabled(step == 0)
            .opacity(step == 0 ? 0.4 : 1)

            if step < 5 {
                Button {
                    step += 1
                } label: {
                    Text(step == 4 ? "La graine →" : "Suivant →")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.read))
                        .foregroundStyle(Theme.background)
                }
            }
        }
        .font(.dynamic(size: 15, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    // MARK: Étape 6

    @ViewBuilder
    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Nom du disque", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)
            TextField("Une phrase qui le raconte", text: Binding(
                get: { draft.summary ?? "" },
                set: { draft.summary = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Graine \(FrenchFormat.integer(Int(draft.seed)))")
                    .font(.dynamic(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("🎲 Autre graine") { draft.seed = UInt64.random(in: 1...9_999_999) }
                    .buttonStyle(.bordered)
            }
            Text("Même histoire, autre disque : la graine change l'ordre exact des écritures.")
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim)
            Button {
                saved = false
                library.build(draft: draft)
            } label: {
                Text(isBuilt ? "Refabriquer le disque" : "Fabriquer le disque")
                    .font(.dynamic(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.read))
                    .foregroundStyle(Theme.background)
            }
            .buttonStyle(.plain)
            .disabled(!draft.isBuildable)
            .opacity(draft.isBuildable ? 1 : 0.4)
        }
        .panel()

        if library.selectedID == draft.id {
            DiskLibraryView(model: library) { disk, activity, strategy in
                try onHandover(disk, activity, strategy)
                // Partir vers la passe laisse la galerie sur le brouillon :
                // c'est bien lui qu'on écoute, et sa fiche est celle qu'on
                // retrouvera en revenant.
                dismiss()
            }

            if library.state.disk != nil {
                otherFormats
                Button {
                    library.save(draft)
                    saved = true
                } label: {
                    Label(saved ? "Enregistré dans Mes disques" : "Enregistrer dans Mes disques",
                          systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                        .font(.dynamic(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
            }
        }
    }

    private var isBuilt: Bool { library.selectedID == draft.id && library.state.disk != nil }

    /// Le même vécu sur un autre format : c'est la comparaison la plus
    /// parlante, et elle ne coûte qu'une fabrication.
    private var otherFormats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REFAIRE AVEC LES MÊMES HABITUDES")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            HStack(spacing: 8) {
                ForEach([FileSystemKind.fat16, .vfat, .fat32, .ntfs], id: \.self) { kind in
                    if kind != draft.fileSystem.type {
                        Button(kind.rawValue.uppercased()) {
                            draft.fileSystem = FileSystemSpec(type: kind)
                            saved = false
                            library.build(draft: draft)
                        }
                        .buttonStyle(.bordered)
                        .font(.dynamic(size: 13, weight: .semibold, design: .monospaced))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: - Les étapes

private struct HardwareStep: View {
    @Binding var draft: ProfileSpec

    private var year: Binding<Int> {
        Binding(get: { draft.timeline.start.year }, set: { newYear in
            let shift = newYear - draft.timeline.start.year
            draft.timeline.start.year = newYear
            draft.timeline.end.year += shift
        })
    }

    var body: some View {
        let geometry = DriveGeometry.era(model: "", capacityBytes: draft.disk.sizeBytes,
                                         rpm: max(draft.disk.rpm, 1),
                                         year: draft.timeline.start.year, zbr: draft.disk.zbr)
        let platters = (geometry.heads + 1) / 2
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: year, in: 1990...2008) {
                labeled("Année d'achat", "\(draft.timeline.start.year)")
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled("Capacité", draft.capacityLabel)
                Slider(value: Binding(
                    get: { log10(Double(max(draft.disk.sizeMB, 10))) },
                    set: { draft.disk.sizeMB = Self.rounded(pow(10, $0)) }),
                       in: log10(20)...log10(500_000))
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled("Régime", draft.rpmLabel)
                Picker("Régime", selection: $draft.disk.rpm) {
                    ForEach([3_600, 4_500, 5_400, 7_200], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled("Seek moyen", FrenchFormat.decimal(draft.disk.averageSeekMs, digits: 1) + " ms")
                Slider(value: $draft.disk.averageSeekMs, in: 7...25, step: 0.5)
            }
        }
        .panel()

        VStack(alignment: .leading, spacing: 8) {
            Text("GÉOMÉTRIE DÉDUITE")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            labeled("Plateaux", "\(platters) (\(geometry.heads) têtes)")
            labeled("Cylindres", FrenchFormat.integer(geometry.cylinders))
            labeled("Débit bord → moyeu", "\(FrenchFormat.decimal(geometry.outerSustainedMBs, digits: 1)) → "
                    + "\(FrenchFormat.decimal(geometry.innerSustainedMBs, digits: 1)) Mo/s")
            if platters > 4 {
                Text("Une capacité en avance sur son époque ajoute des plateaux : \(platters) ici. "
                     + "La densité d'une face est celle des disques vendus en \(draft.timeline.start.year).")
                    .font(.dynamic(size: 11))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Des capacités comme sur une étiquette : deux chiffres significatifs.
    private static func rounded(_ megabytes: Double) -> UInt64 {
        let magnitude = pow(10, floor(log10(megabytes)) - 1)
        return UInt64(max((megabytes / magnitude).rounded() * magnitude, 10))
    }
}

private struct FormatStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        let profile = draft.resolvedFileSystem()
        VStack(alignment: .leading, spacing: 14) {
            Picker("Système de fichiers", selection: Binding(
                get: { draft.fileSystem.type },
                set: { draft.fileSystem = FileSystemSpec(type: $0) })) {
                Text("FAT16").tag(FileSystemKind.fat16)
                Text("VFAT").tag(FileSystemKind.vfat)
                Text("FAT32").tag(FileSystemKind.fat32)
                Text("NTFS").tag(FileSystemKind.ntfs)
            }
            .pickerStyle(.segmented)
            Text(Self.explanation(draft.fileSystem.type))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Taille de cluster", selection: $draft.fileSystem.clusterKB) {
                Text("Comme FORMAT").tag(UInt32?.none)
                ForEach([1, 2, 4, 8, 16, 32, 64] as [UInt32], id: \.self) { kb in
                    Text("\(kb) Ko").tag(UInt32?.some(kb))
                }
            }
            labeled("Clusters de", "\(profile.clusterBytes / 1_024) Ko")
            labeled("Clusters sur le volume", FrenchFormat.integer(Int(draft.clusterCount)))
        }
        .panel()
    }

    private static func explanation(_ kind: FileSystemKind) -> String {
        switch kind {
        case .fat16: return "MS-DOS sert le premier cluster libre depuis le début du volume : les trous se rebouchent aussitôt."
        case .vfat:  return "Le même format, servi par Windows 95 : le curseur reprend au dernier cluster alloué."
        case .fat32: return "Des clusters de 4 Ko sur de grands volumes, et le même curseur que VFAT."
        case .ntfs:  return "Choisit le trou qui convient plutôt que le premier venu, et réserve une zone à sa MFT."
        }
    }
}

private struct SoftwareStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYSTÈME")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Picker("Système", selection: Binding(get: { draft.os }, set: select(system:))) {
                ForEach(SystemOption.all) { option in
                    Text("\(option.name) · \(String(option.year))").tag(option.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .panel()

        VStack(alignment: .leading, spacing: 10) {
            Text("LOGICIELS INSTALLÉS AU DÉPART")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            ForEach(SoftwareYears.applications, id: \.id) { app in
                let year = SoftwareYears.year[app.id]
                let late = year.map { $0 > draft.timeline.end.year } ?? false
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: installed(app.id)) {
                        HStack {
                            Text(app.displayName).foregroundStyle(Theme.text)
                            if let year {
                                Text(late ? "\(String(year)) · trop récent" : String(year))
                                    .font(.dynamic(size: 11, design: .monospaced))
                                    .foregroundStyle(late ? Theme.read : Theme.dim)
                            }
                        }
                    }
                    if draft.installs.contains(app.id) {
                        uninstallRow(app.id)
                    }
                }
            }
        }
        .panel()
    }

    private func select(system id: String) {
        guard let option = SystemOption.all.first(where: { $0.id == id }) else { return }
        draft.os = id
        draft.installs.removeAll { SystemOption.manifestIDs.contains($0) }
        draft.installs.insert(contentsOf: option.manifests, at: 0)
    }

    private func installed(_ id: String) -> Binding<Bool> {
        Binding(get: { draft.installs.contains(id) }, set: { on in
            if on {
                draft.installs.append(id)
            } else {
                draft.installs.removeAll { $0 == id }
                draft.uninstalls?.removeAll { $0.app == id }
            }
        })
    }

    @ViewBuilder
    private func uninstallRow(_ id: String) -> some View {
        let index = draft.uninstalls?.firstIndex { $0.app == id }
        HStack {
            Toggle("Désinstallé", isOn: Binding(get: { index != nil }, set: { on in
                if on {
                    let middle = CivilDate.from(dayNumber: (draft.timeline.start.dayNumber
                                                            + draft.timeline.end.dayNumber) / 2)
                    draft.uninstalls = (draft.uninstalls ?? []) + [.init(app: id, date: middle)]
                } else {
                    draft.uninstalls?.removeAll { $0.app == id }
                }
            }))
            .font(.dynamic(size: 12))
            .foregroundStyle(Theme.dim)
            if let index, let uninstalls = draft.uninstalls {
                DatePicker("", selection: Binding(
                    get: { uninstalls[index].date.date },
                    set: { draft.uninstalls?[index].date = CivilDate($0) }),
                           in: draft.timeline.start.date...draft.timeline.end.date,
                           displayedComponents: .date)
                    .labelsHidden()
            }
        }
        .padding(.leading, 12)
    }
}

private struct PeriodStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        let days = max(draft.timeline.start.days(until: draft.timeline.end), 0)
        VStack(alignment: .leading, spacing: 12) {
            Text("Combien de temps ce disque a servi, du formatage au jour où on l'écoute.")
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
            DatePicker("Début", selection: date(\.start), displayedComponents: .date)
            DatePicker("Fin", selection: date(\.end), displayedComponents: .date)
            labeled("Durée simulée", Self.span(days: days))
        }
        .panel()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DÉFRAGMENTATIONS PLANIFIÉES")
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Button("+ ajouter") {
                    let middle = CivilDate.from(dayNumber: (draft.timeline.start.dayNumber
                                                            + draft.timeline.end.dayNumber) / 2)
                    draft.defragRuns = (draft.defragRuns ?? []) + [middle]
                }
                .font(.dynamic(size: 13, weight: .semibold))
            }
            ForEach(Array((draft.defragRuns ?? []).enumerated()), id: \.offset) { index, run in
                HStack {
                    DatePicker("Une passe", selection: Binding(
                        get: { run.date },
                        set: { draft.defragRuns?[index] = CivilDate($0) }),
                               in: draft.timeline.start.date...draft.timeline.end.date,
                               displayedComponents: .date)
                    Button(role: .destructive) {
                        draft.defragRuns?.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Retirer cette défragmentation")
                }
            }
            Text("Une défragmentation au milieu de l'histoire change tout ce qui s'écrit ensuite.")
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    private func date(_ keyPath: WritableKeyPath<TimelineSpec, CivilDate>) -> Binding<Date> {
        Binding(get: { draft.timeline[keyPath: keyPath].date },
                set: { draft.timeline[keyPath: keyPath] = CivilDate($0) })
    }

    private static func span(days: Int) -> String {
        let years = days / 365
        let months = (days % 365) / 30
        switch (years, months) {
        case (0, _): return "\(months) mois"
        case (_, 0): return years == 1 ? "1 an" : "\(years) ans"
        default:     return "\(years) an\(years > 1 ? "s" : "") \(months) mois"
        }
    }
}

private struct HabitsStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        Text("Ce que la personne faisait de son disque. La fragmentation en découlera : elle ne se règle pas.")
            .font(.dynamic(size: 12))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)

        habit("Bureautique", \.office, .init(newDocumentsPerWeek: 5, savesPerDocumentPerWeek: 1)) { value in
            slider("Nouveaux documents / semaine", value.newDocumentsPerWeek, 0...40, step: 1) { draft.activity.office?.newDocumentsPerWeek = $0 }
            slider("Réenregistrements / document / semaine", value.savesPerDocumentPerWeek, 0...5, step: 0.1) { draft.activity.office?.savesPerDocumentPerWeek = $0 }
        }
        habit("Navigation", \.browse, .init(perDay: 1, pagesPerSession: 15)) { value in
            slider("Sessions / jour", value.perDay, 0...10, step: 0.5) { draft.activity.browse?.perDay = $0 }
            slider("Pages / session", Double(value.pagesPerSession), 1...100, step: 1) { draft.activity.browse?.pagesPerSession = Int($0) }
        }
        habit("Développement", \.build, .init(perDay: 5, objectFiles: 100, pchMB: 10)) { value in
            slider("Compilations / jour", value.perDay, 0...20, step: 1) { draft.activity.build?.perDay = $0 }
            slider("Fichiers objets", Double(value.objectFiles), 1...1_000, step: 10) { draft.activity.build?.objectFiles = Int($0) }
            slider("Précompilé (Mo)", Double(value.pchMB), 0...50, step: 1) { draft.activity.build?.pchMB = UInt64($0) }
        }
        habit("Médias", \.media, .init(filesPerWeek: 20)) { value in
            slider("Fichiers / semaine", value.filesPerWeek, 0...200, step: 5) { draft.activity.media?.filesPerWeek = $0 }
        }
        habit("Téléchargements", \.download, .init(perWeek: 3)) { value in
            slider("Téléchargements / semaine", value.perWeek, 0...30, step: 1) { draft.activity.download?.perWeek = $0 }
            slider("En parties de (Mo, 0 = d'un bloc)", Double(value.partMB ?? 0), 0...100, step: 1) {
                draft.activity.download?.partMB = $0 > 0 ? UInt64($0) : nil
            }
        }
        habit("Jeux", \.gaming, .init(installsPerYear: 4, uninstallsPerYear: 3, savesPerDay: 2)) { value in
            slider("Installations / an", value.installsPerYear, 0...30, step: 1) { draft.activity.gaming?.installsPerYear = $0 }
            slider("Désinstallations / an", value.uninstallsPerYear, 0...30, step: 1) { draft.activity.gaming?.uninstallsPerYear = $0 }
            slider("Sauvegardes / jour", value.savesPerDay, 0...20, step: 1) { draft.activity.gaming?.savesPerDay = $0 }
        }
        habit("Accumulation", \.hoarding, .init(gigabytesPerYear: 1, tidiesUpAt: 0.9)) { value in
            slider("Go accumulés / an", value.gigabytesPerYear, 0...100, step: 0.1) { draft.activity.hoarding?.gigabytesPerYear = $0 }
            slider("Fait le ménage à (% plein, 100 = jamais)", (value.tidiesUpAt ?? 1) * 100, 50...100, step: 1) {
                draft.activity.hoarding?.tidiesUpAt = $0 >= 100 ? nil : $0 / 100
            }
        }
        habit("Mises à jour", \.maintenance, .init(updatesPerYear: 2, filesPerUpdate: 40)) { value in
            slider("Vagues / an", value.updatesPerYear, 0...24, step: 1) { draft.activity.maintenance?.updatesPerYear = $0 }
            slider("Fichiers / vague", Double(value.filesPerUpdate), 1...500, step: 5) { draft.activity.maintenance?.filesPerUpdate = Int($0) }
        }
    }

    /// Une habitude qu'on active ou non ; activée, elle part de valeurs
    /// ordinaires et se règle.
    private func habit<Value, Content: View>(_ title: String,
                                             _ keyPath: WritableKeyPath<ActivitySpec, Value?>,
                                             _ defaults: Value,
                                             @ViewBuilder content: @escaping (Value) -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { draft.activity[keyPath: keyPath] != nil },
                                 set: { draft.activity[keyPath: keyPath] = $0 ? defaults : nil })) {
                Text(title)
                    .font(.dynamic(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            if let value = draft.activity[keyPath: keyPath] {
                content(value)
            }
        }
        .panel()
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, step: Double,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            labeled(label, step < 1 ? FrenchFormat.decimal(value, digits: 1) : FrenchFormat.integer(Int(value.rounded())))
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set),
                   in: range, step: step)
        }
    }
}

/// Les remarques sur le brouillon, sous chaque étape.
private struct IssuesPanel: View {
    let issues: [ProfileIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity == .blocking ? "xmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(issue.severity == .blocking ? Color.red : Theme.read)
                        Text(issue.message)
                            .font(.dynamic(size: 12))
                            .foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}

private func labeled(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label)
            .font(.dynamic(size: 13))
            .foregroundStyle(Theme.text)
        Spacer()
        Text(value)
            .font(.dynamic(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.read)
            .monospacedDigit()
    }
}
