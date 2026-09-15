import SwiftUI
import DiskCore

/// La galerie de disques d'époque : on choisit une année et un profil, le
/// disque se fabrique, et on regarde ce que vingt ans d'usage donnent.
///
/// L'intérêt de l'écran est la comparaison : passer de `gamer-2003` à
/// `secretaire-1993` change la carte du tout au tout, et c'est le seul endroit
/// où l'on voit d'un coup d'œil que la fragmentation n'est pas une valeur mais
/// une texture.
struct DiskLibraryView: View {

    @ObservedObject var model: DiskLibraryModel

    /// Confie le disque affiché au simulateur, qui en planifie la passe et
    /// bascule dessus. Lève si le pont refuse le volume — ce que le bouton
    /// empêche normalement d'atteindre.
    let onDefragment: (GeneratedDisk) throws -> Void

    @State private var handoverFailure: String?

    var body: some View {
        VStack(spacing: 14) {
            picker
            switch model.state {
            case .idle:
                placeholder
            case let .running(fraction, day, fileCount, fill):
                progress(fraction: fraction, day: day, fileCount: fileCount, fill: fill)
            case let .ready(disk):
                map
                defragmentButton(for: disk)
                metrics(of: disk)
            case let .failed(message):
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .panel()
            }
        }
        .onAppear { model.selectFirstIfNeeded() }
    }

    // MARK: - Choix du scénario

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.byEpoch, id: \.year) { epoch in
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(epoch.year))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    FlowRow(spacing: 6) {
                        ForEach(epoch.scenarios) { spec in
                            scenarioChip(spec)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func scenarioChip(_ spec: ProfileSpec) -> some View {
        let isSelected = model.selectedID == spec.id
        return Button {
            model.selectedID = spec.id
        } label: {
            Text(profileName(of: spec))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.background : Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Theme.read : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    /// « Développeur, 1996 » devient « Développeur » : l'année est déjà le titre
    /// de la ligne.
    private func profileName(of spec: ProfileSpec) -> String {
        spec.displayName.split(separator: ",").first.map(String.init) ?? spec.displayName
    }

    // MARK: - États

    private var placeholder: some View {
        Text("Choisissez une époque et un profil.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, minHeight: 120)
            .panel()
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

    /// Le seul pont entre les deux écrans : défragmenter à voix haute le disque
    /// qu'on vient de fabriquer.
    ///
    /// Il n'a de sens que sur les volumes qu'un défragmenteur de 1995 saurait
    /// ouvrir. Plutôt que de masquer le bouton sur les autres, on le laisse
    /// visible et éteint avec la raison écrite dessous : c'est l'occasion de
    /// dire pourquoi un NTFS de 320 Go ne se défragmente pas ici.
    @ViewBuilder
    private func defragmentButton(for disk: GeneratedDisk) -> some View {
        let refusal = GeneratedVolumeBridge.refusal(for: disk)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                handoverFailure = nil
                do {
                    try onDefragment(disk)
                } catch {
                    handoverFailure = "\(error)"
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text("Défragmenter ce disque")
                        .font(.system(size: 13, weight: .semibold))
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

    // MARK: - Résultat

    private var map: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            ClusterMapView(cells: model.displayCells,
                           clustersPerCell: model.clustersPerCell,
                           activeCell: nil,
                           activeIsWrite: false)
            if let disk = model.state.disk {
                ClusterLegend(categories: model.presentCategories,
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: Int(disk.clusterBytes))
            }
        }
        .panel()
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
