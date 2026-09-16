import SwiftUI
import DiskCore

/// Le disque ouvert depuis la galerie : il se fabrique, et on regarde ce que
/// des années d'usage lui ont fait — carte, métriques, et les deux façons de
/// l'écouter.
///
/// La fragmentation n'y est pas une valeur mais une texture : passer de
/// `gamer-2003` à `secretaire-1993` change la carte du tout au tout.
struct DiskLibraryView: View {

    @ObservedObject var model: DiskLibraryModel

    /// Confie le disque affiché au simulateur, qui en planifie la passe et
    /// bascule dessus. Lève si le pont refuse le volume — ce que le bouton
    /// empêche normalement d'atteindre.
    let onHandover: (GeneratedDisk, GeneratedActivity) throws -> Void

    @State private var handoverFailure: String?
    @State private var showsFullScreenMap = false

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .idle:
                cancelled
            case let .running(fraction, day, fileCount, fill):
                progress(fraction: fraction, day: day, fileCount: fileCount, fill: fill)
            case let .ready(disk):
                map
                handover(for: disk)
                metrics(of: disk)
            case let .failed(message):
                failure(message)
            }
        }
    }

    // MARK: - États

    /// Une génération annulée ne reprend pas où elle s'était arrêtée : elle
    /// repart du premier jour de l'histoire.
    private var cancelled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Génération annulée")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("L'histoire du disque est conservée ; le volume, lui, se refabrique depuis le premier jour.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            regenerateButton("Générer depuis le début")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Génération impossible")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.read)
                .fixedSize(horizontal: false, vertical: true)
            regenerateButton("Réessayer")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func regenerateButton(_ title: String) -> some View {
        Button(title) {
            if let id = model.selectedID { model.open(id) }
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.bordered)
    }

    private func progress(fraction: Double, day: UInt32, fileCount: Int, fill: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Vieillissement du volume")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button("Annuler") { model.cancel() }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.dim)
            }
            ProgressView(value: fraction)
                .tint(Theme.read)
            HStack(spacing: 14) {
                Text("jour \(day)")
                Text("\(fileCount) fichiers")
                Text("\(Int(fill * 100)) % occupé")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Passage au simulateur

    /// Les deux ponts entre les écrans : **démarrer** ce disque, ou le
    /// **défragmenter** à voix haute.
    ///
    /// Les deux marchent sur les vingt disques : démarrer ne suppose aucune
    /// stratégie de rangement, et chaque format a désormais le défragmenteur de
    /// son époque — celui de Windows 95 sur les volumes FAT, celui de
    /// Windows XP sur les NTFS. Le second bouton reste malgré tout capable de
    /// s'éteindre, avec la raison écrite dessous : un disque décrit n'importe
    /// comment n'a pas à faire planter l'écran suivant.
    @ViewBuilder
    private func handover(for disk: GeneratedDisk) -> some View {
        let refusal = GeneratedVolumeBridge.refusal(for: disk)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                handoverButton(.boot, icon: "power", for: disk, refusal: nil)
                handoverButton(.defrag, icon: "waveform", for: disk, refusal: refusal)
            }

            if let refusal {
                Text(refusal)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let handoverFailure {
                Text(handoverFailure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func handoverButton(_ activity: GeneratedActivity,
                                icon: String,
                                for disk: GeneratedDisk,
                                refusal: String?) -> some View {
        Button {
            handoverFailure = nil
            do {
                try onHandover(disk, activity)
            } catch {
                handoverFailure = "\(error)"
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(activity.action)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(refusal == nil ? Theme.read : Color.white.opacity(0.06))
            )
            .foregroundStyle(refusal == nil ? Theme.background : Theme.dim)
        }
        .buttonStyle(.plain)
        .disabled(refusal != nil)
    }

    // MARK: - Résultat

    private var map: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if let spec = model.selected {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        if let summary = spec.summary {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                // Le plein écran vaut ici autant que pour une passe : c'est
                // même le seul endroit où l'on regarde un volume de 320 Go, et
                // donc le seul où un bloc vaut des milliers de clusters.
                FullScreenMapButton { showsFullScreenMap = true }
            }
            ClusterMapView(grid: model.grid, shades: model.shades)
                .contentShape(Rectangle())
                .onTapGesture { showsFullScreenMap = true }
            if let disk = model.state.disk {
                ClusterLegend(categories: model.presentCategories,
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: Int(disk.clusterBytes))
            }
        }
        .panel()
        .fullScreenCover(isPresented: $showsFullScreenMap) {
            LibraryFullScreenMap(model: model,
                                 title: model.selected?.displayName ?? "Volume",
                                 clusterBytes: Int(model.state.disk?.clusterBytes ?? 0))
        }
    }

    private func metrics(of disk: GeneratedDisk) -> some View {
        let m = disk.metrics
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(disk.spec.fileSystem.type.rawValue.uppercased()) · clusters de "
                 + "\(disk.clusterBytes / 1024) Ko · \(disk.spec.disk.sizeMB) Mo · "
                 + "\(disk.dayCount) jours simulés")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)

            FlowRow(spacing: 10) {
                StatTile(label: "Fichiers", value: "\(m.fileCount)", unit: "total")
                StatTile(label: "Remplissage", value: "\(Int(m.fill * 100))", unit: "%")
                StatTile(label: "Fragmentés",
                         value: String(format: "%.1f", m.fragmentedRatioAmongFragmentable * 100),
                         unit: "%")
                StatTile(label: "Extents/fichier",
                         value: String(format: "%.2f", m.meanExtentsPerFile),
                         unit: "p95 \(m.p95ExtentsPerFile)")
                StatTile(label: "Pire fichier", value: "\(m.maxExtentsPerFile)", unit: "extents")
                StatTile(label: "Trous", value: "\(m.freeRunCount)", unit: "libres")
                StatTile(label: "Slack", value: "\(Int(m.slackRatio * 100))", unit: "% perdus")
                if m.residentFileCount > 0 {
                    StatTile(label: "Résidents", value: "\(m.residentFileCount)", unit: "dans la MFT")
                }
                if disk.mftClusters > 0 {
                    StatTile(label: "MFT",
                             value: "\(disk.mftClusters * disk.clusterBytes / 1_048_576)",
                             unit: "Mo en \(disk.mftExtents) extents")
                }
            }

            Text(explanation(for: disk))
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Une phrase qui dit ce qu'on regarde. Les chiffres seuls ne disent pas
    /// pourquoi deux disques de la même année ne se ressemblent pas.
    private func explanation(for disk: GeneratedDisk) -> String {
        let m = disk.metrics
        switch disk.spec.fileSystem.type {
        case .fat16:
            return "MS-DOS sert le premier cluster libre à partir du début du volume, "
                + "à chaque écriture : les trous se rebouchent aussitôt et les fichiers "
                + "récents sont hachés. Le slack de \(Int(m.slackRatio * 100)) % vient "
                + "des clusters de \(disk.clusterBytes / 1024) Ko, que la taille du volume impose."
        case .vfat, .fat32:
            return "Le pilote reprend au dernier cluster alloué : l'écriture est propre "
                + "tant que le curseur avance, puis il revient au début du volume et "
                + "repasse par-dessus des trous laissés des mois plus tôt. "
                + "\(m.freeRunCount) trous subsistent."
        case .ntfs:
            return "NTFS choisit le trou qui convient plutôt que le premier venu, et tient "
                + "les données à l'écart de sa zone MFT. D'où des fichiers bien plus "
                + "contigus — \(String(format: "%.2f", m.meanExtentsPerFile)) extents par "
                + "fichier en moyenne — et de grands blocs libres conservés."
        }
    }
}
