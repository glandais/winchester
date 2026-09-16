import SwiftUI
import UIKit

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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
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
                               trail: model.mapTrail())
            },
            transport: { transport })
        .onDisappear {
            // La carte en pouce reprend sa grille historique : la laisser à la
            // finesse du plein écran donnerait des blocs d'un tiers de point.
            model.setMapGrid(.standard)
        }
    }

    private var detail: String {
        let grid = model.mapGrid
        return "\(grid.columns)×\(grid.rows) · 1 bloc = \(model.clustersPerCell) clusters"
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
                    .font(.system(size: 34))
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .monospacedDigit()
            Text(time.clockString)
                .font(.system(size: 11, design: .monospaced))
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

    var body: some View {
        FullScreenMapChrome(
            title: title,
            detail: detail,
            onSurface: { size in
                model.setGrid(MapGrid.fitting(width: size.width, height: size.height))
            },
            map: {
                ClusterMapView(grid: model.grid, shades: model.shades, shading: true)
            },
            transport: {
                ClusterLegend(categories: model.presentCategories,
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: clusterBytes)
            })
        .onDisappear { model.setGrid(.standard) }
    }

    private var detail: String {
        "\(model.grid.columns)×\(model.grid.rows) · 1 bloc = \(model.clustersPerCell) clusters"
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
                .font(.system(size: 11, weight: .semibold))
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
