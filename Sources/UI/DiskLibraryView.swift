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
    let onHandover: DiskHandover

    /// Ce qu'on a déjà fait à ce disque, gardé d'un lancement à l'autre.
    var state = DiskState()
    /// La carte du disque **rangé**, quand une passe de cette session-ci l'a
    /// produite. Elle ne survit pas à la fermeture — un bilan garde le volume
    /// entier —, et c'est pourquoi la bascule disparaît au relancement là où
    /// la ligne d'état, elle, reste.
    var tidyMap: (grid: MapGrid, shades: [ClusterShade])?
    /// Le disque tel que l'outil l'a laissé : ses tuiles, sous la carte rangée.
    ///
    /// Sans lui, la bascule montrerait la carte d'après au-dessus des chiffres
    /// d'avant — la moitié de l'écart que cette fiche est censée combler.
    var tidyDisk: GeneratedDisk?

    @State private var handoverFailure: String?
    @State private var showsTools = false
    @State private var showsFullScreenMap = false
    @State private var showsDetails = false
    /// La carte montrée : celle du volume vieilli, ou celle qu'un outil a
    /// laissée. Revient d'elle-même à l'origine quand la seconde n'existe pas.
    @State private var showsTidied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.state {
            case .idle:
                cancelled
            case let .running(fraction, day, fileCount, fill):
                progress(fraction: fraction, day: day, fileCount: fileCount, fill: fill)
            case let .ready(disk):
                // Ce qu'on lui a fait, avant ce qu'il est : c'est la première
                // chose qu'on vient chercher en revenant sur un disque.
                if let digest = state.tidied ?? state.last {
                    DiskStateBadge(digest: digest, compact: false)
                }
                map
                metrics(of: shownDisk(or: disk))
                explanationCard(for: disk)
                handover(for: disk)
                details(of: disk)
            case let .failed(message):
                failure(message)
            }
        }
        .navigationDestination(isPresented: $showsTools) {
            if let disk = model.state.disk {
                DefragToolChoiceScreen(disk: disk) { disk, activity, strategy in
                    try onHandover(disk, activity, strategy)
                    // De retour sur l'onglet Disques, on retrouve la fiche.
                    showsTools = false
                }
            }
        }
    }

    // MARK: - En-tête

    /// Le titre du disque et sa fiche matérielle. La taille de cluster n'est
    /// sûre qu'une fois le volume fabriqué : un profil peut la laisser au
    /// format, qui la choisit d'après la capacité.
    @ViewBuilder
    private var header: some View {
        if let spec = model.selected {
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.displayName)
                    .font(.dynamic(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(specLine(spec, clusterBytes: model.state.disk?.clusterBytes))
                    .font(.dynamic(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = spec.summary {
                    Text(summary)
                        .font(.dynamic(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// « 1996 · 850 Mo · 5 400 tr/min · VFAT 16 Ko · Windows 95 »
    private func specLine(_ spec: ProfileSpec, clusterBytes: UInt32?) -> String {
        let cluster = clusterBytes.map { " \($0 / 1024) Ko" }
            ?? spec.fileSystem.clusterKB.map { " \($0) Ko" }
            ?? ""
        return "\(spec.year) · \(spec.capacityLabel) · \(spec.rpmLabel) · "
            + "\(spec.fileSystemLabel)\(cluster) · \(spec.osName)"
    }

    // MARK: - Fabrication

    private func progress(fraction: Double, day: UInt32, fileCount: Int, fill: Double) -> some View {
        let date = model.selected.map { FrenchFormat.date($0.timeline.start.adding(days: Int(day))) }
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fabrication du volume")
                    .font(.dynamic(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("On rejoue l'histoire du disque, jour après jour. L'allocateur fait le reste.")
                    .font(.dynamic(size: 13))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("JOUR SIMULÉ")
                        .font(.dynamic(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Text(date ?? "jour \(day)")
                        .font(.dynamic(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                }
                ProgressView(value: fraction)
                    .tint(Theme.read)
                HStack {
                    Text("\(FrenchFormat.integer(fileCount)) fichiers")
                    Spacer()
                    Text("\(Int((fill * 100).rounded())) % occupé")
                }
                .font(.dynamic(size: 12, design: .monospaced))
                .foregroundStyle(Theme.dim)
            }
            Button {
                model.cancel()
            } label: {
                Text("Annuler")
                    .font(.dynamic(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Une génération annulée ne reprend pas où elle s'était arrêtée : elle
    /// repart du premier jour de l'histoire.
    private var cancelled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Génération annulée")
                .font(.dynamic(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("L'histoire du disque est conservée ; le volume, lui, se refabrique depuis le premier jour.")
                .font(.dynamic(size: 12))
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
                .font(.dynamic(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.dynamic(size: 12, design: .monospaced))
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
        .font(.dynamic(size: 13, weight: .semibold))
        .buttonStyle(.bordered)
    }

    // MARK: - Résultat

    /// La carte affichée : celle du volume tel que son histoire l'a laissé, ou
    /// celle qu'un outil vient d'en faire.
    private var shownMap: (grid: MapGrid, shades: [ClusterShade]) {
        guard showsTidied, let tidyMap else { return (model.grid, model.shades) }
        return tidyMap
    }

    /// Le disque dont on lit les chiffres : celui d'origine, ou le rangé quand
    /// la bascule est dessus. Les deux vont ensemble — carte et tuiles.
    private func shownDisk(or original: GeneratedDisk) -> GeneratedDisk {
        showsTidied ? (tidyDisk ?? original) : original
    }

    private var map: some View {
        VStack(alignment: .leading, spacing: 8) {
            // La bascule n'apparaît que si un outil a rangé ce disque pendant
            // cette session : la carte du disque rangé ne survit pas à la
            // fermeture, seule sa ligne d'état reste.
            if tidyMap != nil {
                Picker("Carte du volume", selection: $showsTidied) {
                    Text("D'origine").tag(false)
                    Text("Rangé").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Carte du volume, d'origine ou rangé")
            }
            ZStack(alignment: .topTrailing) {
                ClusterMapView(grid: shownMap.grid, shades: shownMap.shades)
                    .contentShape(Rectangle())
                    .onTapGesture { showsFullScreenMap = true }
                // Le plein écran vaut ici autant que pour une passe : c'est
                // même le seul endroit où l'on regarde un volume de 320 Go, et
                // donc le seul où un bloc vaut des milliers de clusters.
                FullScreenMapButton { showsFullScreenMap = true }
                    .padding(6)
            }
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

    /// Les six chiffres qui disent ce qu'est devenu le volume.
    private func metrics(of disk: GeneratedDisk) -> some View {
        let m = disk.metrics
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                         spacing: 9) {
            MetricTile(label: "Fichiers", value: FrenchFormat.integer(m.fileCount))
            // Rapporté aux seuls fichiers fragmentables, quand la Passe et les
            // Instruments le rapportent à tous les éléments : les deux taux
            // sont justes et diffèrent, alors la tuile dit sur quoi elle porte
            // (`UX_REVIEW.md` §3).
            MetricTile(label: "Fragmentés",
                       value: FrenchFormat.percent(m.fragmentedRatioAmongFragmentable),
                       note: "des fragmentables",
                       accent: true)
            MetricTile(label: "Morceaux/f.", value: FrenchFormat.decimal(m.meanExtentsPerFile, digits: 2))
            MetricTile(label: "Trous", value: FrenchFormat.integer(m.freeRunCount))
            MetricTile(label: "Slack", value: FrenchFormat.percent(m.slackRatio))
            MetricTile(label: "Rempli", value: FrenchFormat.percent(m.fill))
        }
    }

    private func explanationCard(for disk: GeneratedDisk) -> some View {
        HStack(alignment: .top, spacing: 6) {
            WhyButton(topic: disk.spec.fileSystem.type == .ntfs ? .mftZone : .nextFit)
                .padding(.vertical, -6)
            Text(explanation(for: disk))
                .font(.dynamic(size: 12))
                .foregroundStyle(Theme.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Ce qui ne tient pas dans les six tuiles, pour qui veut regarder de près.
    private func details(of disk: GeneratedDisk) -> some View {
        let m = disk.metrics
        return DisclosureGroup(isExpanded: $showsDetails) {
            FlowRow(spacing: 10) {
                StatTile(label: "Pire fichier", value: FrenchFormat.integer(m.maxExtentsPerFile), unit: "morceaux")
                StatTile(label: "95ᵉ centile", value: FrenchFormat.integer(m.p95ExtentsPerFile), unit: "morceaux")
                StatTile(label: "Plus grand trou",
                         value: FrenchFormat.megabytes(UInt64(m.largestFreeRunClusters) * UInt64(disk.clusterBytes)),
                         unit: "libres")
                StatTile(label: "Histoire", value: FrenchFormat.integer(Int(disk.dayCount)), unit: "jours simulés")
                if m.residentFileCount > 0 {
                    StatTile(label: "Résidents", value: FrenchFormat.integer(m.residentFileCount), unit: "dans la MFT")
                }
                if disk.mftClusters > 0 {
                    StatTile(label: "MFT",
                             value: FrenchFormat.megabytes(UInt64(disk.mftClusters) * UInt64(disk.clusterBytes)),
                             unit: "en \(disk.mftExtents) morceaux")
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Plus de détails")
                .font(.dynamic(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
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
                + "récents sont hachés. Le slack de \(FrenchFormat.percent(m.slackRatio)) vient "
                + "des clusters de \(disk.clusterBytes / 1024) Ko, que la taille du volume impose."
        case .vfat, .fat32:
            return "Le pilote reprend au dernier cluster alloué : l'écriture est propre "
                + "tant que le curseur avance, puis il revient au début du volume et "
                + "repasse par-dessus des trous laissés des mois plus tôt. "
                + "\(FrenchFormat.integer(m.freeRunCount)) trous subsistent."
        case .ntfs:
            // La moyenne de morceaux se lit sur tous les fichiers : quelques
            // gros fichiers hachés suffisent à la tirer loin au-dessus de ce
            // que vit un fichier ordinaire. Le dire, sinon la tuile ment.
            guard m.fragmentedFileCount > 0 else {
                return "NTFS choisit le trou qui convient plutôt que le premier venu, et tient "
                    + "les données à l'écart de sa zone MFT : aucun fichier de ce volume n'est "
                    + "en morceaux."
            }
            return "NTFS choisit le trou qui convient plutôt que le premier venu, et tient "
                + "les données à l'écart de sa zone MFT : seuls "
                + "\(FrenchFormat.percent(m.fragmentedRatioAmongFragmentable)) des fichiers fragmentables sont en "
                + "morceaux. Ceux-là le sont beaucoup — le pire en compte "
                + "\(FrenchFormat.integer(m.maxExtentsPerFile)) —, et ce sont eux qui portent la "
                + "moyenne à \(FrenchFormat.decimal(m.meanExtentsPerFile, digits: 2)) morceaux par fichier."
        }
    }

    // MARK: - Passage au simulateur

    /// Les quatre ponts entre les écrans : **défragmenter** ce disque, en
    /// choisissant l'outil sur l'écran suivant, le **démarrer**, rejouer son
    /// **installation**, ou **revivre** toute son histoire.
    ///
    /// Les deux marchent sur les vingt disques : démarrer ne suppose aucune
    /// stratégie de rangement, et chaque format a le défragmenteur de son
    /// époque — celui de Windows 95 sur les volumes FAT, celui de Windows XP
    /// sur les NTFS. Le bouton de défragmentation reste malgré tout capable de
    /// s'éteindre, avec la raison écrite dessous : un disque décrit n'importe
    /// comment n'a pas à faire planter l'écran suivant.
    @ViewBuilder
    private func handover(for disk: GeneratedDisk) -> some View {
        let refusal = GeneratedVolumeBridge.refusal(for: disk)
        VStack(alignment: .leading, spacing: 8) {
            handoverButton(.defrag, icon: "waveform", for: disk, refusal: refusal, primary: true)
            handoverButton(.boot, icon: "power", for: disk, refusal: nil, primary: false)
            handoverButton(.install, icon: "opticaldisc", for: disk, refusal: nil, primary: false)
            handoverButton(.life, icon: "clock.arrow.circlepath", for: disk, refusal: nil, primary: false)

            if let refusal {
                Text(refusal)
                    .font(.dynamic(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let handoverFailure {
                Text(handoverFailure)
                    .font(.dynamic(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handoverButton(_ activity: GeneratedActivity,
                                icon: String,
                                for disk: GeneratedDisk,
                                refusal: String?,
                                primary: Bool) -> some View {
        let enabled = refusal == nil
        return Button {
            handoverFailure = nil
            // Défragmenter demande d'abord avec quel outil ; démarrer et
            // installer, non.
            guard activity != .defrag else {
                showsTools = true
                return
            }
            do {
                try onHandover(disk, activity, nil)
            } catch {
                handoverFailure = "\(error)"
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(activity.action)
                    .font(.dynamic(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(primary && enabled ? Theme.read : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(primary ? Color.clear : Color.white.opacity(0.16), lineWidth: 1)
            )
            .foregroundStyle(!enabled ? Theme.dim : (primary ? Theme.background : Theme.text))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Une métrique de la fiche : libellé en capitales, valeur en chiffres fixes.
private struct MetricTile: View {
    let label: String
    let value: String
    /// Ce sur quoi la valeur porte, quand un autre écran compte autrement.
    var note: String?
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.dynamic(size: 19, weight: .medium, design: .monospaced))
                .foregroundStyle(accent ? Theme.read : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note)
                    .font(.dynamic(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }
}
