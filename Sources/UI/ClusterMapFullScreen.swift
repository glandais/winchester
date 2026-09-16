import SwiftUI
import UIKit
import DiskCore

/// La carte des clusters en plein écran.
///
/// Deux choses seulement la distinguent de la carte en pouce, et les deux
/// viennent de la même cause : elle a mille fois plus de place, donc des blocs
/// de cinq points au lieu de quinze, et des dizaines de milliers de blocs au
/// lieu de mille deux cent quarante-huit.
///
/// - la **grille se dérive de la surface** plutôt que de se figer. 192 × 108
///   est du 16:9, un iPhone en paysage du 19,5:9 : une grille figée y laisserait
///   deux bandes noires. Le repliement en lignes n'a aucune signification
///   physique — la carte est une suite linéaire de clusters — donc remplir
///   l'écran est gratuit ;
/// - la **teinte est proportionnelle** : à ce compte de blocs, un bloc vaut des
///   milliers de clusters sur un gros volume, et la catégorie dominante seule
///   le montrerait plein alors qu'il est au quart.
///
/// Le reste est du confort de veille : une passe dure de quelques minutes à
/// plusieurs heures, on la laisse tourner, donc l'écran ne doit pas s'éteindre
/// — et doit se rallumer tout seul en sortant.
private struct FullScreenMapChrome<Map: View, Transport: View>: View {

    let title: String
    let detail: String
    /// Appelé avec la surface réellement offerte à la carte, à l'ouverture et à
    /// chaque rotation. C'est de là que sort la grille.
    let onSurface: (CGSize) -> Void
    @ViewBuilder let map: () -> Map
    @ViewBuilder let transport: () -> Transport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 8) {
                header
                GeometryReader { proxy in
                    map()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // La surface est mesurée ici, à l'endroit exact où la
                        // carte est dessinée : mesurer l'écran entier donnerait
                        // une grille plus grande que la place disponible, donc
                        // des cellules plus petites que voulu.
                        .onAppear { onSurface(proxy.size) }
                        .onChange(of: proxy.size) { _, size in onSurface(size) }
                }
                transport()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        // Les zones sûres sont respectées : en paysage, l'encoche mange un côté
        // de l'écran, et une carte qui passerait dessous perdrait une colonne
        // de blocs sans le dire.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // Une passe dure de quelques minutes à plusieurs heures : c'est
            // fait pour être laissé tourner, et l'écran qui s'éteint au bout de
            // trente secondes interromprait ce qu'on est venu regarder.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            // Rétabli sans condition, et depuis la vue elle-même : un écran
            // qui ne s'éteint plus après coup vide la batterie en silence.
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.dynamic(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(detail)
                .font(.dynamic(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.dynamic(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Quitter le plein écran")
        }
    }
}

/// Le plein écran d'une passe de défragmentation : la carte, et le minimum de
/// transport pour ne pas avoir à en sortir — lecture/pause, avancement, temps.
struct DefragFullScreenMap: View {

    @ObservedObject var model: SimulationModel
    @ObservedObject var engine: DiskNoiseEngine
    @State private var selected: Int?

    private var time: Double { engine.currentTime }

    var body: some View {
        FullScreenMapChrome(
            title: model.label.title,
            detail: detail,
            onSurface: { size in
                model.setMapGrid(MapGrid.fitting(width: size.width, height: size.height))
            },
            map: {
                ClusterMapView(grid: model.mapGrid,
                               shades: model.clusterShades(at: time),
                               shading: true,
                               trail: model.mapTrail(),
                               selectedCell: selected,
                               onCellTap: { cell in selected = (selected == cell) ? nil : cell })
                // Par-dessus la carte et non à la place du transport : la
                // surface de la carte ne doit pas changer, sinon la grille se
                // redécoupe et le bloc touché ne désigne plus rien.
                .overlay(alignment: .bottom) {
                    if let selected, let playback = model.defrag {
                        passCellInfo(selected, clusterCount: playback.partition.clusterCount,
                                     clusterBytes: playback.partition.clusterBytes)
                    }
                }
            },
            transport: { transport })
        // Une rotation change la grille : le même numéro de bloc ne désigne
        // plus les mêmes clusters.
        .onChange(of: model.mapGrid) { _, _ in selected = nil }
        .onDisappear {
            // La carte en pouce reprend sa grille historique : la laisser à la
            // finesse du plein écran donnerait des blocs d'un tiers de point.
            model.setMapGrid(.standard)
        }
    }

    private var detail: String {
        let grid = model.mapGrid
        return "\(grid.columns)×\(grid.rows) · 1 bloc \(FrenchFormat.clustersPerCell(model.clustersPerCell))"
    }

    /// Ce qu'on sait d'un bloc pendant la passe : sa catégorie et son
    /// remplissage à l'instant écouté. Pas ses fichiers — ils bougent, et la
    /// carte rejouée n'en garde que les couleurs.
    private func passCellInfo(_ cell: Int, clusterCount: Int, clusterBytes: Int) -> some View {
        let shades = model.clusterShades(at: time)
        let shade = shades.indices.contains(cell) ? shades[cell] : .empty
        let clusters = model.clusters(ofCell: cell)
        let start = clusters.lowerBound
        let end = clusters.upperBound
        let category = ClusterCategory(rawValue: shade.category) ?? .free
        return CellInfoBar(
            swatch: Theme.categoryColor(category, contiguous: shade.contiguous),
            title: shade.fill == 0 ? "Libre" : category.label,
            line: "Bloc \(FrenchFormat.integer(cell + 1)) · clusters \(FrenchFormat.integer(start)) à "
                + "\(FrenchFormat.integer(max(end - 1, start))) · "
                + "\(FrenchFormat.percent(Double(shade.fill) / 255)) occupé",
            files: [],
            note: "Les fichiers ne sont pas suivis pendant une passe : ils changent de place.",
            onClose: { selected = nil })
    }

    private var transport: some View {
        let progress = model.defragProgress ?? 0
        return HStack(spacing: 14) {
            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying || engine.isBuffering
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.dynamic(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.text)
            }
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Lecture")

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.read)
                        .frame(width: max(proxy.size.width * CGFloat(progress), 2))
                }
            }
            .frame(height: 5)

            Text(String(format: "%.0f %%", progress * 100))
                .font(.dynamic(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .monospacedDigit()
            Text(time.clockString)
                .font(.dynamic(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .monospacedDigit()
        }
        .frame(height: 38)
    }
}

/// Le plein écran d'un disque de la galerie : la même carte, sans transport —
/// un volume au repos n'avance pas.
///
/// C'est le cas que la teinte proportionnelle est faite pour sauver : un NTFS
/// de 320 Go compte quatre-vingt-deux millions de clusters, soit près de cinq
/// mille par bloc, et la catégorie dominante seule le montrerait uniformément
/// plein.
struct LibraryFullScreenMap: View {

    @ObservedObject var model: DiskLibraryModel
    let title: String
    let clusterBytes: Int
    @State private var selected: Int?
    @State private var contents: CellContents?

    var body: some View {
        FullScreenMapChrome(
            title: title,
            detail: detail,
            onSurface: { size in
                model.setGrid(MapGrid.fitting(width: size.width, height: size.height))
            },
            map: {
                ClusterMapView(grid: model.grid, shades: model.shades, shading: true,
                               selectedCell: selected,
                               onCellTap: select)
                .overlay(alignment: .bottom) {
                    if let selected, let contents {
                        libraryCellInfo(selected, contents)
                    }
                }
            },
            transport: {
                ClusterLegend(categories: model.presentCategories,
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: clusterBytes)
            })
        .onChange(of: model.grid) { _, _ in select(nil) }
        .onDisappear { model.setGrid(.standard) }
    }

    private func select(_ cell: Int?) {
        guard let cell, cell != selected, let disk = model.state.disk else {
            selected = nil
            contents = nil
            return
        }
        selected = cell
        contents = disk.contents(ofCell: cell, cellCount: model.grid.cellCount, limit: 3)
    }

    /// Un volume au repos se lit fichier par fichier : le catalogue dit qui
    /// occupe chaque cluster.
    private func libraryCellInfo(_ cell: Int, _ contents: CellContents) -> some View {
        let shades = model.shades
        let shade = shades.indices.contains(cell) ? shades[cell] : .empty
        let category = ClusterCategory(rawValue: shade.category) ?? .free
        let size = Double(contents.clusters.count)
        let others = contents.fileCount - contents.occupants.count
        var note: String? = nil
        if contents.systemClusters > 0 {
            note = "\(FrenchFormat.integer(Int(contents.systemClusters))) clusters réservés par le système de fichiers."
        }
        if others > 0 {
            let more = "Et \(FrenchFormat.integer(others)) autre\(others > 1 ? "s" : "") fichier\(others > 1 ? "s" : "")."
            note = note.map { "\(more) \($0)" } ?? more
        }
        return CellInfoBar(
            swatch: Theme.categoryColor(category, contiguous: shade.contiguous),
            title: contents.usedClusters == 0 ? "Libre" : category.label,
            line: "Bloc \(FrenchFormat.integer(cell + 1)) · clusters "
                + "\(FrenchFormat.integer(Int(contents.clusters.lowerBound))) à "
                + "\(FrenchFormat.integer(Int(max(contents.clusters.upperBound, contents.clusters.lowerBound + 1) - 1))) · "
                + "\(FrenchFormat.percent(size > 0 ? Double(contents.usedClusters) / size : 0)) occupé",
            files: contents.occupants.map { occupant in
                let pieces = occupant.fragments > 1 ? "\(occupant.fragments) morceaux" : "d'un seul tenant"
                return (occupant.path,
                        "\(FrenchFormat.megabytes(occupant.logicalSize, smallInKilobytes: true)) · \(pieces)")
            },
            note: note,
            onClose: { select(nil) })
    }

    private var detail: String {
        "\(model.grid.columns)×\(model.grid.rows) · 1 bloc \(FrenchFormat.clustersPerCell(model.clustersPerCell))"
    }
}

/// Ce qu'on sait du bloc touché, à la place du transport ou de la légende.
private struct CellInfoBar: View {
    let swatch: Color
    let title: String
    let line: String
    let files: [(path: String, detail: String)]
    let note: String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(swatch).frame(width: 14, height: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.dynamic(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(line)
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 6) {
                        Text(file.path)
                            .font(.dynamic(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(file.detail)
                            .font(.dynamic(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                }
                if let note {
                    Text(note)
                        .font(.dynamic(size: 10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.dynamic(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .padding(6)
            }
            .accessibilityLabel("Fermer le détail du bloc")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
        .padding(8)
        .accessibilityElement(children: .combine)
    }
}

/// Le bouton qui ouvre le plein écran : discret, posé sur le coin de la carte,
/// et doublé par la carte elle-même qui est tapable. Le point d'entrée doit se
/// découvrir sans encombrer un panneau déjà dense.
struct FullScreenMapButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.dynamic(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Carte en plein écran")
    }
}
