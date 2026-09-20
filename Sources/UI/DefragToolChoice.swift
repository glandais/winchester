import SwiftUI
import DiskCore

/// Ce qu'un écran confie à la passe : un disque, ce qu'on veut en entendre, et
/// pour une défragmentation l'outil choisi — `nil` laisse le format décider.
typealias DiskHandover = (GeneratedDisk, GeneratedActivity, (any DefragStrategy)?) throws -> Void

/// Un défragmenteur tel que l'écran de choix le présente.
///
/// Les durées ne sont pas estimées : aucun calcul ne les donne avant la passe.
/// Ce sont les fourchettes **mesurées** sur les vingt disques de la galerie
/// (README et `LEDGER.md`), par format, et rien quand l'outil n'y a pas été
/// mesuré. Une estimation fausse d'un facteur dix serait pire que pas
/// d'estimation.
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
            ? "Réservé à NTFS · ce volume est en \(label)"
            : "Réservé à FAT · ce volume est en NTFS"
    }

    func isPeriodTool(on format: VolumeFormat) -> Bool {
        periodFormats.contains(FormatFamily(format))
    }

    static func all() -> [DefragTool] {
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
            return DefragTool(strategy: strategy(id), name: name, origin: "JkDefrag 3.36 · 2008",
                              principle: principle, sound: sound, periodFormats: [], onlyOn: nil,
                              isAdvanced: true, measured: measured)
        }
        return [
            DefragTool(strategy: strategy("windows95"),
                       name: "Défragmenteur Windows 95/98",
                       origin: "1995 · FAT uniquement",
                       principle: "Tasse tout au début du disque, dans l'ordre de l'arborescence, en évacuant ce qui gêne.",
                       sound: "Des allers-retours permanents, et un « clac » au bord du plateau à chaque fichier.",
                       periodFormats: [.fat], onlyOn: .fat, isAdvanced: false,
                       measured: [.fat: "de 6 min à 1 h"]),
            DefragTool(strategy: strategy("windowsXP"),
                       name: "Défragmenteur Windows XP",
                       origin: "2001 · NTFS uniquement",
                       principle: "Ne répare que les fichiers en morceaux, en les recopiant dans un trou déjà libre.",
                       sound: "Court et calme ; il échoue quand aucun trou n'est à la taille.",
                       periodFormats: [.ntfs], onlyOn: .ntfs, isAdvanced: false,
                       measured: [.ntfs: "de quelques secondes à 45 min"]),
            DefragTool(strategy: strategy("ultraDefrag"),
                       name: "UltraDefrag 7.1.1",
                       origin: "2018 · tous formats",
                       principle: "Recolle les petits éclats sans déplacer les gros blocs, et n'évacue personne.",
                       sound: "Beaucoup de requêtes courtes ; bien moins de morceaux à la fin.",
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: "de quelques secondes à 9 min",
                                  .ntfs: "de quelques secondes à 40 min"]),
            DefragTool(strategy: strategy("jkDefrag"),
                       name: "JkDefrag 3.36",
                       origin: "2008 · mode par défaut",
                       principle: "Range le volume par zones et comble les trous, sans jamais évacuer.",
                       sound: "Rapide tant qu'il reste de la place ; presque rien sur un disque plein.",
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: "de quelques secondes à 10 min", .ntfs: "de 4 min à 1 h 15"]),
            // Les deux derniers n'imitent aucun outil : ils ont été écrits dans
            // ce projet, chacun pour un format, à partir de ce que les autres
            // font mal. Proposés sur leur format seulement.
            DefragTool(strategy: strategy("frontierCompaction"),
                       name: "Tassage à la frontière",
                       origin: "écrit pour Winchester · FAT uniquement",
                       principle: "Tasse le volume dans l'ordre où il est : les fichiers glissent vers le début par tronçons, et aucune écriture ne tombe sur une donnée encore référencée.",
                       sound: "Une navette courte qui remonte le plateau ; long sur un disque plein.",
                       periodFormats: [], onlyOn: .fat, isAdvanced: false,
                       measured: [.fat: "de 6 à 55 min"]),
            DefragTool(strategy: strategy("fragmentMerge"),
                       name: "Recollage économe",
                       origin: "écrit pour Winchester · NTFS uniquement",
                       principle: "Ne recopie que les petits morceaux, contre leur gros voisin ou dans le trou le plus proche, et regroupe l'espace libre.",
                       sound: "Des blocs lus morceau par morceau puis écrits d'un coup, et un point de contrôle tous les seize déplacements.",
                       periodFormats: [], onlyOn: .ntfs, isAdvanced: false,
                       measured: [.ntfs: "de quelques secondes à 20 min"]),
            // Le rangement intelligent vise ce qu'on mesure après la passe —
            // le démarrage, les morceaux, les trous —, pas sa durée.
            DefragTool(strategy: strategy("smart"),
                       name: "Rangement intelligent",
                       origin: "écrit pour Winchester · tous formats",
                       principle: "Pose en tête ce que lit le démarrage, dans l'ordre où il le lit, puis tasse le reste derrière : plus un morceau, presque plus de trous.",
                       sound: "Un grand déménagement au début du disque, puis la navette du tassage ; long sur NTFS, où tout le contenu passe sous les têtes.",
                       periodFormats: [], onlyOn: nil, isAdvanced: false,
                       measured: [.fat: "de 8 min à 1 h", .ntfs: "de 5 min à 4 h"]),
            jk("jkDefragForcedFill", "Tasser au début",
               "Remplit chaque trou par la fin du fragment le plus haut du volume.",
               "Court, mais il casse plus de fichiers qu'il n'en répare.",
               fat: "jusqu'à 2 min", ntfs: "jusqu'à 25 min"),
            jk("jkDefragMoveUp", "Tasser à la fin",
               "Remplit chaque trou, du fond vers le début, par les fichiers pris dessous.",
               "Le début du volume se vide peu à peu.",
               fat: "de 1 à 6 min", ntfs: "de 2 à 25 min"),
            jk("jkDefragSortName", "Trier par nom",
               "Repose chaque fichier à son rang, en délogeant ce qui occupe sa place.",
               "Le seul mode de JkDefrag qui évacue : long, et ce qui part revient.",
               fat: "de 6 à 32 min", ntfs: "de 3 min à 3 h 30"),
            jk("jkDefragSortSize", "Trier par taille",
               "Repose chaque fichier à son rang de taille, en délogeant ce qui gêne.",
               "Long : ce qu'on évacue redescend quand vient son tour.",
               fat: "de 7 à 21 min", ntfs: "de 4 min à 1 h 15"),
            jk("jkDefragSortAccess", "Trier par dernier accès",
               "Repose chaque fichier selon sa dernière lecture, en délogeant ce qui gêne.",
               "Long : ce qu'on évacue redescend quand vient son tour.",
               fat: "de 10 à 30 min", ntfs: "de 3 min à 3 h 50"),
            jk("jkDefragSortChange", "Trier par modification",
               "Repose chaque fichier selon sa dernière écriture, en délogeant ce qui gêne.",
               "Long : ce qu'on évacue redescend quand vient son tour.",
               fat: "de 10 à 35 min", ntfs: "de 3 min à 4 h 05"),
            jk("jkDefragSortCreation", "Trier par création",
               "Repose chaque fichier selon sa date de création, en délogeant ce qui gêne.",
               "Long : ce qu'on évacue redescend quand vient son tour.",
               fat: "de 10 à 35 min", ntfs: "de 3 min à 4 h 10"),
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

    private let tools = DefragTool.all()
    private let format: VolumeFormat

    init(disk: GeneratedDisk, onHandover: @escaping DiskHandover) {
        self.disk = disk
        self.onHandover = onHandover
        let format = GeneratedVolumeBridge.format(of: disk)
        self.format = format
        let period = DefragPlanner.strategy(for: format).id
        _selectedID = State(initialValue: period)
    }

    private var formatLabel: String { disk.spec.fileSystemLabel }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Avec quel outil ?")
                            .font(.dynamic(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.text)
                        Text("\(disk.spec.displayName) · \(formatLabel)")
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
                            Text("Options avancées")
                                .font(.dynamic(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("7 autres modes de JkDefrag")
                                .font(.dynamic(size: 11))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .panel()

                    Text("Les durées sont celles mesurées sur les disques de la galerie : un ordre de grandeur, pas un décompte. La vraie se découvre à l'écoute.")
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
                        badge("INDISPO.", color: Theme.dim)
                    } else if tool.isPeriodTool(on: format) {
                        badge("D'ÉPOQUE", color: Theme.read)
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
                        Text("Mesuré sur la galerie : \(measured)")
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

    private func badge(_ text: String, color: Color) -> some View {
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
                        Text("Déplacer par blocs pleins")
                            .font(.dynamic(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Pas le comportement de l'outil : pour le comparer au recollage économe. Les durées mesurées ne valent plus.")
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
                Text("Lancer la passe")
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
