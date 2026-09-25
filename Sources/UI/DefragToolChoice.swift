import SwiftUI
import DiskCore

/// Ce qu'un écran confie à la passe : un disque, ce qu'on veut en entendre, et
/// pour une défragmentation l'outil choisi — `nil` laisse le format décider.
typealias DiskHandover = (GeneratedDisk, GeneratedActivity, (any DefragStrategy)?) throws -> Void

/// Un défragmenteur tel que l'écran de choix le présente.
///
/// Les durées ne sont pas estimées : aucun calcul ne les donne avant la passe.
/// Ce sont les fourchettes **mesurées** sur les vingt-quatre disques de la
/// galerie (bilans de `Tools/Measure`, en dernier ceux du chantier 51 de
/// `LEDGER.md`), par format, et rien quand l'outil n'y a pas été mesuré. Une
/// estimation fausse d'un facteur dix serait pire que pas d'estimation. Elles
/// sont à refaire quand un chantier change les passes.
struct DefragTool: Identifiable {

    let strategy: any DefragStrategy
    let name: String
    let origin: String
    let principle: String
    let sound: String
    /// L'outil de son époque, pour ce format : Windows 95 sur FAT, XP sur NTFS.
    let periodFormats: Set<FormatFamily>
    /// Réservé à une famille de formats. Rien n'empêche le moteur de passer la
    /// stratégie de 95 sur un NTFS ; ce serait un contresens de vingt-huit
    /// millions de requêtes, et l'écran ne le propose pas.
    let onlyOn: FormatFamily?
    let isAdvanced: Bool
    let measured: [FormatFamily: String]

    var id: String { strategy.id }

    enum FormatFamily: Hashable {
        case fat, ntfs

        init(_ format: VolumeFormat) {
            switch format {
            case .fat16, .fat32: self = .fat
            case .ntfs:          self = .ntfs
            }
        }
    }

    func refusal(on format: VolumeFormat, label: String) -> String? {
        guard let onlyOn, onlyOn != FormatFamily(format) else { return nil }
        return onlyOn == .ntfs
            ? String(localized: "tool.refusal.ntfsOnly",
                     defaultValue: "NTFS only · this volume is \(label)",
                     comment: "Pourquoi un outil est grisé pour ce volume")
            : String(localized: "tool.refusal.fatOnly",
                     defaultValue: "FAT only · this volume is NTFS")
    }

    func isPeriodTool(on format: VolumeFormat) -> Bool {
        periodFormats.contains(FormatFamily(format))
    }

    /// La liste, pour un disque d'une année donnée : l'outil de 95 y porte le
    /// nom qu'il avait cette année-là — `DEFRAG` sous MS-DOS 6, le même
    /// algorithme (`Windows95Strategy.year`).
    static func all(year: Int? = nil) -> [DefragTool] {
        let dos = year.map { $0 < 1995 } ?? false
        let vista = year.map { $0 >= 2007 && $0 < 2009 } ?? false
        let seven = year.map { $0 >= 2009 } ?? false
        func strategy(_ id: String) -> any DefragStrategy {
            guard let found = DefragPlanner.strategy(named: id) else {
                preconditionFailure("stratégie inconnue : \(id)")
            }
            return found
        }
        func jk(_ id: String, _ name: String, _ principle: String, _ sound: String,
                fat: String?, ntfs: String?) -> DefragTool {
            var measured: [FormatFamily: String] = [:]
            measured[.fat] = fat
            measured[.ntfs] = ntfs
            return DefragTool(strategy: strategy(id), name: name, origin: String(localized: "tool.jkDefrag.advanced.origin", defaultValue: "JkDefrag 3.36 · 2008"),
                              principle: principle, sound: sound, periodFormats: [], onlyOn: nil,
                              isAdvanced: true, measured: measured)
        }
        return [
            DefragTool(strategy: strategy("windows95"),
                       name: dos
                           ? String(localized: "tool.msdos6.name", defaultValue: "MS-DOS 6 DEFRAG")
                           : String(localized: "tool.windows95.name", defaultValue: "Windows 95/98 Defragmenter"),
                       origin: dos
                           ? String(localized: "tool.msdos6.origin", defaultValue: "1993 · FAT only · same engine as Windows 95")
                           : String(localized: "tool.windows95.origin", defaultValue: "1995 · FAT only"),
                       principle: String(localized: "tool.windows95.principle", defaultValue: "Packs everything to the start of the disk, in tree order, evicting whatever is in the way."),
                       sound: String(localized: "tool.windows95.sound", defaultValue: "Constant back-and-forth, and a “clack” at the edge of the platter for every file."),
                       periodFormats: [.fat], onlyOn: .fat, isAdvanced: false,
                       measured: [.fat: String(localized: "tool.windows95.fat.measured", defaultValue: "a few seconds to 1 h")]),
            DefragTool(strategy: strategy("windowsXP"),
                       name: seven
                           ? String(localized: "tool.win7.name", defaultValue: "Windows 7 Defragmenter")
                           : vista
                           ? String(localized: "tool.vista.name", defaultValue: "Windows Vista Defragmenter")
                           : String(localized: "tool.windowsXP.name", defaultValue: "Windows XP Defragmenter"),
                       origin: seven
                           ? String(localized: "tool.win7.origin", defaultValue: "2009 · NTFS only · same engine as XP, fragments under 64 MB")
                           : vista
                           ? String(localized: "tool.vista.origin", defaultValue: "2007 · NTFS only · same engine as XP, fragments under 64 MB")
                           : String(localized: "tool.windowsXP.origin", defaultValue: "2001 · NTFS only"),
                       principle: String(localized: "tool.windowsXP.principle", defaultValue: "Repairs files in pieces, smallest first, into the smallest hole that fits; empties a region when none does; then packs everything towards the start."),
                       sound: String(localized: "tool.windowsXP.sound", defaultValue: "Bursts of small 64 KB copies, a quiet stretch, then the long sweep of the packing."),
                       periodFormats: [.ntfs], onlyOn: .ntfs, isAdvanced: false,
                       measured: [.ntfs: String(localized: "tool.windowsXP.ntfs.measured", defaultValue: "2 min to 3 h 55")]),
            DefragTool(strategy: strategy("ultraDefrag"),
                       name: String(localized: "tool.ultraDefrag.name", defaultValue: "UltraDefrag 7.1.1"),
                       origin: String(localized: "tool.ultraDefrag.origin", defaultValue: "2018 · all formats"),
                       principle: String(localized: "tool.ultraDefrag.principle", defaultValue: "Merges the small splinters without moving the big blocks, and evicts nobody."),
                       sound: String(localized: "tool.ultraDefrag.sound", defaultValue: "Many short requests; far fewer pieces at the end."),
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: String(localized: "tool.ultraDefrag.fat.measured", defaultValue: "a few seconds to 7 min"),
                                  .ntfs: String(localized: "tool.ultraDefrag.ntfs.measured", defaultValue: "a few seconds to 46 min")]),
            DefragTool(strategy: strategy("jkDefrag"),
                       name: String(localized: "tool.jkDefrag.name", defaultValue: "JkDefrag 3.36"),
                       origin: String(localized: "tool.jkDefrag.origin", defaultValue: "2008 · default mode"),
                       principle: String(localized: "tool.jkDefrag.principle", defaultValue: "Tidies the volume by zones and fills the holes, never evicting."),
                       sound: String(localized: "tool.jkDefrag.sound", defaultValue: "Fast as long as there is room; almost nothing on a full disk."),
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: String(localized: "tool.jkDefrag.fat.measured", defaultValue: "a few seconds to 29 min"), .ntfs: String(localized: "tool.jkDefrag.ntfs.measured", defaultValue: "4 min to 1 h 55")]),
            // Les deux derniers n'imitent aucun outil : ils ont été écrits dans
            // ce projet, chacun pour un format, à partir de ce que les autres
            // font mal. Proposés sur leur format seulement.
            DefragTool(strategy: strategy("frontierCompaction"),
                       name: String(localized: "tool.frontierCompaction.name", defaultValue: "Frontier compaction"),
                       origin: String(localized: "tool.frontierCompaction.origin", defaultValue: "written for Winchester · FAT only"),
                       principle: String(localized: "tool.frontierCompaction.principle", defaultValue: "Packs the volume in the order it is in: files slide towards the start in runs, and no write ever lands on data that is still referenced."),
                       sound: String(localized: "tool.frontierCompaction.sound", defaultValue: "A short shuttle working its way up the platter; long on a full disk."),
                       periodFormats: [], onlyOn: .fat, isAdvanced: false,
                       measured: [.fat: String(localized: "tool.frontierCompaction.fat.measured", defaultValue: "6 min to 1 h")]),
            DefragTool(strategy: strategy("fragmentMerge"),
                       name: String(localized: "tool.fragmentMerge.name", defaultValue: "Thrifty merge"),
                       origin: String(localized: "tool.fragmentMerge.origin", defaultValue: "written for Winchester · NTFS only"),
                       principle: String(localized: "tool.fragmentMerge.principle", defaultValue: "Only copies the small pieces, next to their big neighbour or into the nearest hole, and gathers the free space."),
                       sound: String(localized: "tool.fragmentMerge.sound", defaultValue: "Blocks read piece by piece then written in one go, and a checkpoint every sixteen moves."),
                       periodFormats: [], onlyOn: .ntfs, isAdvanced: false,
                       measured: [.ntfs: String(localized: "tool.fragmentMerge.ntfs.measured", defaultValue: "a few seconds to 13 min")]),
            // Le rangement intelligent vise ce qu'on mesure après la passe —
            // le démarrage, les morceaux, les trous —, pas sa durée.
            DefragTool(strategy: strategy("smart"),
                       name: String(localized: "tool.smart.name", defaultValue: "Smart tidying"),
                       origin: String(localized: "tool.smart.origin", defaultValue: "written for Winchester · all formats"),
                       principle: String(localized: "tool.smart.principle", defaultValue: "Lays what the boot reads at the head, in the order it reads it, then packs the rest behind: not a piece left, almost no holes."),
                       sound: String(localized: "tool.smart.sound", defaultValue: "A great removal at the start of the disk, then the shuttle of the packing; long on NTFS, where all the contents pass under the heads."),
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: String(localized: "tool.smart.fat.measured", defaultValue: "7 min to 1 h 05"), .ntfs: String(localized: "tool.smart.ntfs.measured", defaultValue: "5 min to 4 h 20")]),
            jk("jkDefragForcedFill", String(localized: "tool.jkDefragForcedFill.name", defaultValue: "Pack to the start"),
               String(localized: "tool.jkDefragForcedFill.principle", defaultValue: "Fills every hole with the end of the highest fragment of the volume."),
               String(localized: "tool.jkDefragForcedFill.sound", defaultValue: "Short, but it breaks more files than it repairs."),
               fat: String(localized: "tool.jkDefragForcedFill.fat.measured", defaultValue: "up to 13 min"), ntfs: String(localized: "tool.jkDefragForcedFill.ntfs.measured", defaultValue: "up to 24 min")),
            jk("jkDefragMoveUp", String(localized: "tool.jkDefragMoveUp.name", defaultValue: "Pack to the end"),
               String(localized: "tool.jkDefragMoveUp.principle", defaultValue: "Fills every hole, from the far end towards the start, with the files taken below."),
               String(localized: "tool.jkDefragMoveUp.sound", defaultValue: "The start of the volume empties little by little."),
               fat: String(localized: "tool.jkDefragMoveUp.fat.measured", defaultValue: "up to 10 min"), ntfs: String(localized: "tool.jkDefragMoveUp.ntfs.measured", defaultValue: "3 to 31 min")),
            jk("jkDefragSortName", String(localized: "tool.jkDefragSortName.name", defaultValue: "Sort by name"),
               String(localized: "tool.jkDefragSortName.principle", defaultValue: "Puts every file back at its rank, evicting whatever holds its place."),
               String(localized: "tool.jkDefragSortName.sound", defaultValue: "The only JkDefrag mode that evicts: long, and what leaves comes back."),
               fat: String(localized: "tool.jkDefragSortName.fat.measured", defaultValue: "a few seconds to 1 h 20"), ntfs: String(localized: "tool.jkDefragSortName.ntfs.measured", defaultValue: "7 min to 5 h 40")),
            jk("jkDefragSortSize", String(localized: "tool.jkDefragSortSize.name", defaultValue: "Sort by size"),
               String(localized: "tool.jkDefragSortSize.principle", defaultValue: "Puts every file back at its rank by size, evicting whatever is in the way."),
               String(localized: "tool.jkDefragSortSize.sound", defaultValue: "Long: what is evicted comes back down when its turn arrives."),
               fat: String(localized: "tool.jkDefragSortSize.fat.measured", defaultValue: "a few seconds to 1 h 25"), ntfs: String(localized: "tool.jkDefragSortSize.ntfs.measured", defaultValue: "9 min to 1 h 55")),
            jk("jkDefragSortAccess", String(localized: "tool.jkDefragSortAccess.name", defaultValue: "Sort by last access"),
               String(localized: "tool.jkDefragSortAccess.principle", defaultValue: "Puts every file back by its last read, evicting whatever is in the way."),
               String(localized: "tool.jkDefragSortAccess.sound", defaultValue: "Long: what is evicted comes back down when its turn arrives."),
               fat: String(localized: "tool.jkDefragSortAccess.fat.measured", defaultValue: "a few seconds to 1 h 25"), ntfs: String(localized: "tool.jkDefragSortAccess.ntfs.measured", defaultValue: "7 min to 7 h 20")),
            jk("jkDefragSortChange", String(localized: "tool.jkDefragSortChange.name", defaultValue: "Sort by last change"),
               String(localized: "tool.jkDefragSortChange.principle", defaultValue: "Puts every file back by its last write, evicting whatever is in the way."),
               String(localized: "tool.jkDefragSortChange.sound", defaultValue: "Long: what is evicted comes back down when its turn arrives."),
               fat: String(localized: "tool.jkDefragSortChange.fat.measured", defaultValue: "a few seconds to 1 h 30"), ntfs: String(localized: "tool.jkDefragSortChange.ntfs.measured", defaultValue: "7 min to 4 h")),
            jk("jkDefragSortCreation", String(localized: "tool.jkDefragSortCreation.name", defaultValue: "Sort by creation date"),
               String(localized: "tool.jkDefragSortCreation.principle", defaultValue: "Puts every file back by its creation date, evicting whatever is in the way."),
               String(localized: "tool.jkDefragSortCreation.sound", defaultValue: "Long: what is evicted comes back down when its turn arrives."),
               fat: String(localized: "tool.jkDefragSortCreation.fat.measured", defaultValue: "a few seconds to 1 h 30"), ntfs: String(localized: "tool.jkDefragSortCreation.ntfs.measured", defaultValue: "7 min to 4 h")),
        ]
    }
}

/// « Avec quel outil ? » — maquette 08.
///
/// L'outil de l'époque du volume est présélectionné et marqué comme tel ; les
/// autres sont des points de comparaison. Une durée affichée est une fourchette
/// mesurée sur la galerie, jamais un compte à rebours.
struct DefragToolChoiceScreen: View {

    let disk: GeneratedDisk
    let onHandover: DiskHandover

    @State private var selectedID: String
    @State private var showsAdvanced = false
    /// Déplacer par blocs pleins : l'option de XP, UltraDefrag et JkDefrag qui
    /// les fait déplacer comme le recollage économe. Ce n'est pas le
    /// comportement de l'outil ; elle sert à comparer les algorithmes à
    /// primitive égale.
    @State private var fullBlocks = false
    @State private var failure: String?

    private var tools: [DefragTool] { DefragTool.all(year: disk.spec.timeline.start.year) }
    private let format: VolumeFormat

    init(disk: GeneratedDisk, onHandover: @escaping DiskHandover) {
        self.disk = disk
        self.onHandover = onHandover
        let format = GeneratedVolumeBridge.format(of: disk)
        self.format = format
        let period = DefragPlanner.strategy(for: format, year: disk.spec.timeline.start.year).id
        _selectedID = State(initialValue: period)
    }

    private var formatLabel: String { disk.spec.fileSystemLabel }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("tool.choice.title")
                            .font(.dynamic(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.text)
                        Text(verbatim: "\(disk.spec.displayName) · \(formatLabel)")
                            .font(.dynamic(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }

                    ForEach(tools.filter { !$0.isAdvanced }) { tool in
                        card(tool)
                    }

                    DisclosureGroup(isExpanded: $showsAdvanced) {
                        VStack(spacing: 10) {
                            ForEach(tools.filter(\.isAdvanced)) { tool in
                                card(tool)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("tool.choice.advanced")
                                .font(.dynamic(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("tool.choice.advanced.note")
                                .font(.dynamic(size: 11))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .panel()

                    Text("tool.choice.durations")
                        .font(.dynamic(size: 11))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { launchBar }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
    }

    private func card(_ tool: DefragTool) -> some View {
        let refusal = tool.refusal(on: format, label: formatLabel)
        let isSelected = tool.id == selectedID && refusal == nil
        return Button {
            if refusal == nil { selectedID = tool.id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Theme.read : Theme.dim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name)
                            .font(.dynamic(size: 15, weight: .semibold))
                            .foregroundStyle(refusal == nil ? Theme.text : Theme.dim)
                        Text(refusal ?? tool.origin)
                            .font(.dynamic(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    if refusal != nil {
                        badge("tool.badge.unavailable", color: Theme.dim)
                    } else if tool.isPeriodTool(on: format) {
                        badge("tool.badge.period", color: Theme.read)
                    }
                }
                if refusal == nil {
                    Text(tool.principle)
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(tool.sound)
                        .font(.dynamic(size: 12))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let measured = tool.measured[DefragTool.FormatFamily(format)] {
                        Text(verbatim: String(localized: "tool.measured",
                                              defaultValue: "Measured on the gallery: \(measured)"))
                            .font(.dynamic(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.write)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? Theme.read : Theme.stroke, lineWidth: isSelected ? 1.5 : 1))
            )
            .opacity(refusal == nil ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// La clé porte déjà ses capitales : le catalogue décide, pas la locale.
    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.dynamic(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private var selectedTool: DefragTool? { tools.first { $0.id == selectedID } }

    private var launchBar: some View {
        VStack(spacing: 6) {
            if let tool = selectedTool, DefragPlanner.withFullBlocks(tool.strategy) != nil {
                Toggle(isOn: $fullBlocks) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("tool.option.fullBlocks")
                            .font(.dynamic(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("tool.option.fullBlocks.note")
                            .font(.dynamic(size: 10))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.read)
            }
            if let failure {
                Text(failure)
                    .font(.dynamic(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                failure = nil
                guard let tool = selectedTool else { return }
                let strategy = fullBlocks
                    ? DefragPlanner.withFullBlocks(tool.strategy) ?? tool.strategy
                    : tool.strategy
                do {
                    try onHandover(disk, .defrag, strategy)
                } catch {
                    failure = "\(error)"
                }
            } label: {
                Text("tool.start")
                    .font(.dynamic(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.read))
                    .foregroundStyle(Theme.background)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.background.opacity(0.95))
    }
}
