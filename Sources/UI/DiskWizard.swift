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
                    displayName: String(localized: "wizard.newDisk", defaultValue: "New disk"),
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

    private static var titles: [String] {
        [String(localized: "wizard.step.hardware", defaultValue: "The hardware"),
         String(localized: "wizard.step.format", defaultValue: "The format"),
         String(localized: "wizard.step.system", defaultValue: "The system and the software"),
         String(localized: "wizard.step.period", defaultValue: "The period of use"),
         String(localized: "wizard.step.habits", defaultValue: "The habits"),
         String(localized: "wizard.step.seed", defaultValue: "The seed and the result")]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: String(localized: "wizard.stepCount",
                                                  defaultValue: "STEP \(step + 1) OF 6",
                                                  comment: "Compteur d'étapes de l'assistant, en capitales"))
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
                    Button("common.close") {
                        if losesDraft { confirmsClose = true } else { close() }
                    }
                }
            }
            .confirmationDialog("wizard.close.title", isPresented: $confirmsClose,
                                titleVisibility: .visible) {
                Button("wizard.close.save") {
                    library.save(draft)
                    saved = true
                    close()
                }
                Button("wizard.close.discard", role: .destructive) { close() }
                Button("onboarding.continue", role: .cancel) {}
            } message: {
                Text(verbatim: String(localized: "wizard.close.message",
                                      defaultValue: "“\(draft.displayName)” is built but is not in My disks: its seed and its history would be lost."))
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
                Text("wizard.back")
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
                    Text(step == 4 ? "wizard.toSeed" : "wizard.next")
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
            TextField("wizard.field.name", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)
            TextField("wizard.field.summary", text: Binding(
                get: { draft.summary ?? "" },
                set: { draft.summary = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(verbatim: String(localized: "wizard.seed",
                                      defaultValue: "Seed \(Format.integer(Int(draft.seed)))"))
                    .font(.dynamic(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("wizard.seed.another") { draft.seed = UInt64.random(in: 1...9_999_999) }
                    .buttonStyle(.bordered)
            }
            Text("wizard.seed.note")
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim)
            Button {
                saved = false
                library.build(draft: draft)
            } label: {
                Text(isBuilt ? "wizard.rebuild" : "wizard.build")
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
                    Label(saved ? "wizard.saved" : "wizard.save",
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
            Text("wizard.again.header")
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
                labeled(String(localized: "wizard.hw.year", defaultValue: "Year bought"), "\(draft.timeline.start.year)")
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled(String(localized: "wizard.hw.capacity", defaultValue: "Capacity"), draft.capacityLabel)
                Slider(value: Binding(
                    get: { log10(Double(max(draft.disk.sizeMB, 10))) },
                    set: { draft.disk.sizeMB = Self.rounded(pow(10, $0)) }),
                       in: log10(20)...log10(500_000))
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled(String(localized: "wizard.hw.rpm", defaultValue: "Spindle speed"), draft.rpmLabel)
                Picker(String(localized: "wizard.hw.rpm", defaultValue: "Spindle speed"), selection: $draft.disk.rpm) {
                    ForEach([3_600, 4_500, 5_400, 7_200], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                labeled(String(localized: "instruments.tile.averageSeek", defaultValue: "Average seek"),
                        Format.decimal(draft.disk.averageSeekMs, digits: 1) + " ms")
                Slider(value: $draft.disk.averageSeekMs, in: 7...25, step: 0.5)
            }
        }
        .panel()

        VStack(alignment: .leading, spacing: 8) {
            Text("wizard.hw.geometry.header")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            labeled(String(localized: "wizard.hw.platters", defaultValue: "Platters"),
                    String(localized: "wizard.hw.platters.value",
                           defaultValue: "\(platters) (\(geometry.heads) heads)"))
            labeled(String(localized: "wizard.hw.cylinders", defaultValue: "Cylinders"), Format.integer(geometry.cylinders))
            labeled(String(localized: "wizard.hw.throughput", defaultValue: "Throughput edge → hub"),
                    String(localized: "instruments.unit.megabytesPerSecond",
                           defaultValue: "\(Format.decimal(geometry.outerSustainedMBs, digits: 1)) → \(Format.decimal(geometry.innerSustainedMBs, digits: 1)) MB/s"))
            if platters > 4 {
                Text(verbatim: String(localized: "wizard.hw.platters.note",
                                      defaultValue: "A capacity ahead of its time adds platters: \(platters) here. The density of one surface is that of the disks sold in \(draft.timeline.start.year)."))
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
            Picker("wizard.fs.picker", selection: Binding(
                get: { draft.fileSystem.type },
                set: { draft.fileSystem = FileSystemSpec(type: $0) })) {
                Text(verbatim: "FAT16").tag(FileSystemKind.fat16)
                Text(verbatim: "VFAT").tag(FileSystemKind.vfat)
                Text(verbatim: "FAT32").tag(FileSystemKind.fat32)
                Text(verbatim: "NTFS").tag(FileSystemKind.ntfs)
            }
            .pickerStyle(.segmented)
            Text(Self.explanation(draft.fileSystem.type))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            Picker("wizard.fs.clusterSize", selection: $draft.fileSystem.clusterKB) {
                Text("wizard.fs.clusterSize.auto").tag(UInt32?.none)
                ForEach([1, 2, 4, 8, 16, 32, 64] as [UInt32], id: \.self) { kb in
                    Text(verbatim: String(localized: "disk.cluster.kilobytes",
                                          defaultValue: "\(kb) KB")).tag(UInt32?.some(kb))
                }
            }
            labeled(String(localized: "wizard.fs.clustersOf", defaultValue: "Clusters of"),
                    String(localized: "disk.cluster.kilobytes",
                           defaultValue: "\(profile.clusterBytes / 1_024) KB"))
            labeled(String(localized: "wizard.fs.clusterCount", defaultValue: "Clusters on the volume"),
                    Format.integer(Int(draft.clusterCount)))
        }
        .panel()
    }

    private static func explanation(_ kind: FileSystemKind) -> String {
        switch kind {
        case .fat16: return String(localized: "wizard.fs.note.fat16", defaultValue: "MS-DOS serves the first free cluster from the start of the volume: holes are plugged at once.")
        case .vfat:  return String(localized: "wizard.fs.note.vfat", defaultValue: "The same format, served by Windows 95: the cursor resumes at the last allocated cluster.")
        case .fat32: return String(localized: "wizard.fs.note.fat32", defaultValue: "4 KB clusters on large volumes, and the same cursor as VFAT.")
        case .ntfs:  return String(localized: "wizard.fs.note.ntfs", defaultValue: "Picks the hole that fits rather than the first one it meets, and reserves a zone for its MFT.")
        }
    }
}

private struct SoftwareStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wizard.system.header")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Picker("wizard.system.picker", selection: Binding(get: { draft.os }, set: select(system:))) {
                ForEach(SystemOption.all) { option in
                    Text(verbatim: "\(option.name) · \(String(option.year))").tag(option.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .panel()

        VStack(alignment: .leading, spacing: 10) {
            Text("wizard.software.header")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            ForEach(SoftwareYears.applications, id: \.id) { app in
                let year = SoftwareYears.year[app.id]
                let late = year.map { $0 > draft.timeline.end.year } ?? false
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: installed(app.id)) {
                        HStack {
                            Text(verbatim: app.displayName).foregroundStyle(Theme.text)
                            if let year {
                                Text(verbatim: late
                                     ? String(localized: "wizard.software.tooRecent",
                                              defaultValue: "\(String(year)) · too recent")
                                     : String(year))
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
            Toggle("wizard.software.uninstalled", isOn: Binding(get: { index != nil }, set: { on in
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
                DatePicker(String(), selection: Binding(
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
            Text("wizard.period.note")
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.dim)
            DatePicker("wizard.period.start", selection: date(\.start), displayedComponents: .date)
            DatePicker("wizard.period.end", selection: date(\.end), displayedComponents: .date)
            labeled(String(localized: "wizard.period.span", defaultValue: "Simulated duration"), Self.span(days: days))
        }
        .panel()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("wizard.defrags.header")
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Button("wizard.defrags.add") {
                    let middle = CivilDate.from(dayNumber: (draft.timeline.start.dayNumber
                                                            + draft.timeline.end.dayNumber) / 2)
                    draft.defragRuns = (draft.defragRuns ?? []) + [middle]
                }
                .font(.dynamic(size: 13, weight: .semibold))
            }
            ForEach(Array((draft.defragRuns ?? []).enumerated()), id: \.offset) { index, run in
                HStack {
                    DatePicker("wizard.defrags.one", selection: Binding(
                        get: { run.date },
                        set: { draft.defragRuns?[index] = CivilDate($0) }),
                               in: draft.timeline.start.date...draft.timeline.end.date,
                               displayedComponents: .date)
                    Button(role: .destructive) {
                        draft.defragRuns?.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("wizard.defrags.remove")
                }
            }
            Text("wizard.defrags.note")
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
        case (0, _):
            return String(localized: "wizard.span.months", defaultValue: "\(months) months",
                          comment: "Durée simulée, au pluriel de la langue")
        case (_, 0):
            return String(localized: "wizard.span.years", defaultValue: "\(years) years")
        default:
            return String(localized: "wizard.span.yearsMonths",
                          defaultValue: "\(String(localized: "wizard.span.years", defaultValue: "\(years) years")) \(String(localized: "wizard.span.months", defaultValue: "\(months) months"))")
        }
    }
}

private struct HabitsStep: View {
    @Binding var draft: ProfileSpec

    var body: some View {
        Text("wizard.habits.note")
            .font(.dynamic(size: 12))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)

        habit(String(localized: "habit.office", defaultValue: "Office work"), \.office, .init(newDocumentsPerWeek: 5, savesPerDocumentPerWeek: 1)) { value in
            slider(String(localized: "habit.office.newDocuments", defaultValue: "New documents / week"), value.newDocumentsPerWeek, 0...40, step: 1) { draft.activity.office?.newDocumentsPerWeek = $0 }
            slider(String(localized: "habit.office.saves", defaultValue: "Re-saves / document / week"), value.savesPerDocumentPerWeek, 0...5, step: 0.1) { draft.activity.office?.savesPerDocumentPerWeek = $0 }
        }
        habit(String(localized: "habit.browse", defaultValue: "Browsing"), \.browse, .init(perDay: 1, pagesPerSession: 15)) { value in
            slider(String(localized: "habit.browse.sessions", defaultValue: "Sessions / day"), value.perDay, 0...10, step: 0.5) { draft.activity.browse?.perDay = $0 }
            slider(String(localized: "habit.browse.pages", defaultValue: "Pages / session"), Double(value.pagesPerSession), 1...100, step: 1) { draft.activity.browse?.pagesPerSession = Int($0) }
        }
        habit(String(localized: "habit.build", defaultValue: "Development"), \.build, .init(perDay: 5, objectFiles: 100, pchMB: 10)) { value in
            slider(String(localized: "habit.build.compiles", defaultValue: "Builds / day"), value.perDay, 0...20, step: 1) { draft.activity.build?.perDay = $0 }
            slider(String(localized: "habit.build.objectFiles", defaultValue: "Object files"), Double(value.objectFiles), 1...1_000, step: 10) { draft.activity.build?.objectFiles = Int($0) }
            slider(String(localized: "habit.build.pch", defaultValue: "Precompiled (MB)"), Double(value.pchMB), 0...50, step: 1) { draft.activity.build?.pchMB = UInt64($0) }
        }
        habit(String(localized: "habit.media", defaultValue: "Media"), \.media, .init(filesPerWeek: 20)) { value in
            slider(String(localized: "habit.media.files", defaultValue: "Files / week"), value.filesPerWeek, 0...200, step: 5) { draft.activity.media?.filesPerWeek = $0 }
        }
        habit(String(localized: "habit.download", defaultValue: "Downloads"), \.download, .init(perWeek: 3)) { value in
            slider(String(localized: "habit.download.perWeek", defaultValue: "Downloads / week"), value.perWeek, 0...30, step: 1) { draft.activity.download?.perWeek = $0 }
            slider(String(localized: "habit.download.parts", defaultValue: "In parts of (MB, 0 = one block)"), Double(value.partMB ?? 0), 0...100, step: 1) {
                draft.activity.download?.partMB = $0 > 0 ? UInt64($0) : nil
            }
        }
        habit(String(localized: "habit.gaming", defaultValue: "Games"), \.gaming, .init(installsPerYear: 4, uninstallsPerYear: 3, savesPerDay: 2)) { value in
            slider(String(localized: "habit.gaming.installs", defaultValue: "Installs / year"), value.installsPerYear, 0...30, step: 1) { draft.activity.gaming?.installsPerYear = $0 }
            slider(String(localized: "habit.gaming.uninstalls", defaultValue: "Uninstalls / year"), value.uninstallsPerYear, 0...30, step: 1) { draft.activity.gaming?.uninstallsPerYear = $0 }
            slider(String(localized: "habit.gaming.saves", defaultValue: "Saved games / day"), value.savesPerDay, 0...20, step: 1) { draft.activity.gaming?.savesPerDay = $0 }
        }
        habit(String(localized: "habit.hoarding", defaultValue: "Hoarding"), \.hoarding, .init(gigabytesPerYear: 1, tidiesUpAt: 0.9)) { value in
            slider(String(localized: "habit.hoarding.gigabytes", defaultValue: "GB hoarded / year"), value.gigabytesPerYear, 0...100, step: 0.1) { draft.activity.hoarding?.gigabytesPerYear = $0 }
            slider(String(localized: "habit.hoarding.tidiesUp", defaultValue: "Clears out at (%% full, 100 = never)"), (value.tidiesUpAt ?? 1) * 100, 50...100, step: 1) {
                draft.activity.hoarding?.tidiesUpAt = $0 >= 100 ? nil : $0 / 100
            }
        }
        habit(String(localized: "habit.maintenance", defaultValue: "Updates"), \.maintenance, .init(updatesPerYear: 2, filesPerUpdate: 40)) { value in
            slider(String(localized: "habit.maintenance.waves", defaultValue: "Waves / year"), value.updatesPerYear, 0...24, step: 1) { draft.activity.maintenance?.updatesPerYear = $0 }
            slider(String(localized: "habit.maintenance.files", defaultValue: "Files / wave"), Double(value.filesPerUpdate), 1...500, step: 5) { draft.activity.maintenance?.filesPerUpdate = Int($0) }
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
            labeled(label, step < 1 ? Format.decimal(value, digits: 1) : Format.integer(Int(value.rounded())))
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
