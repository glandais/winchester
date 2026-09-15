import SwiftUI
import DiskCore

/// Deux écrans : la simulation sonore, et la galerie de disques d'époque.
///
/// Ils ne partagent rien d'autre que le thème — le premier fait du bruit à
/// partir d'un scénario figé, le second fabrique des volumes et les montre. La
/// jonction entre les deux (défragmenter à voix haute un disque qu'on vient de
/// générer) passe par `GeneratedVolumeBridge`, et n'a de sens que sur les
/// volumes qu'un défragmenteur de 1995 pourrait ouvrir.
enum Workspace: String, CaseIterable, Identifiable {
    case simulator
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulator: return "Simulation"
        case .library:   return "Disques d'époque"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SimulationModel()
    @StateObject private var library = DiskLibraryModel()
    @State private var workspace: Workspace = .simulator

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Picker("Espace", selection: $workspace) {
                    ForEach(Workspace.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                switch workspace {
                case .simulator:
                    SimulatorScreen(model: model, engine: model.engine)
                case .library:
                    ScrollView {
                        DiskLibraryView(model: library) { disk in
                            try model.load(generated: disk)
                            workspace = .simulator
                        }
                        .padding(16)
                    }
                }
            }
        }
        .tint(Theme.read)
    }
}

/// Le moteur publie sa propre horloge : il doit être observé directement,
/// sinon l'écran ne se rafraîchit pas pendant la lecture.
struct SimulatorScreen: View {

    @ObservedObject var model: SimulationModel
    @ObservedObject var engine: DiskNoiseEngine
    @State private var showsModelNotes = false

    private var time: Double { engine.currentTime }
    private var span: PhaseSpan? { model.span(at: time) }
    /// Une seule interrogation de la trace par image, partagée par le plateau et
    /// par l'afficheur de cylindre.
    private var platter: PlatterFrame { model.platterFrame(at: time) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    scenarioPicker
                    if model.defrag != nil { defragPanel }
                    PlatterView(track: model.platter, frame: platter)
                        .frame(maxHeight: 300)
                        .panel()

                    phaseBanner
                    timeline
                    transport
                    stats
                    mixer
                    notes
                }
                .padding(16)
            }
        }
        .tint(Theme.read)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DiskNoise")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text(model.label.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            activityLED
        }
    }

    private var scenarioPicker: some View {
        Picker("Scénario", selection: Binding(get: { model.selection },
                                              set: { model.select($0) })) {
            ForEach(model.selections) { selection in
                Text(model.title(of: selection)).tag(selection)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Carte du volume, rejouée sur l'horloge du moteur audio : ce sont les
    /// mêmes dates que celles des repères sonores, donc l'écriture d'un bloc se
    /// voit exactement quand elle s'entend.
    @ViewBuilder
    private var defragPanel: some View {
        if let playback = model.defrag {
            let active = model.activeCell(at: time)
            let plan = playback.plan
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Volume C:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(playback.partition.capacityDescription) · \(playback.partition.format.label) · clusters de \(playback.partition.clusterBytes / 1024) Ko")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }

                // L'outil qu'on écoute. Sans lui, deux passes aux signatures
                // sonores opposées s'annoncent de la même façon, et le seul
                // indice de ce qui a changé est un compteur.
                Text(plan.strategy.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)

                ClusterMapView(cells: model.clusterCells(at: time),
                               clustersPerCell: model.clustersPerCell,
                               activeCell: active?.cell,
                               activeIsWrite: active?.isWrite ?? false)

                progressBar(playback: playback)

                ClusterLegend(categories: presentCategories(in: plan),
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: playback.partition.clusterBytes)

                Text(String(format: "Au départ : %d fichiers, %d fragmentés (%.0f %%), %.2f extents par fichier, %d trous dans l'espace libre. À l'arrivée : %d fragmentés, %d trous.",
                            plan.before.fileCount, plan.before.fragmentedFiles,
                            plan.before.fragmentedRatio * 100, plan.before.extentsPerFile,
                            plan.before.freeHoles, plan.after.fragmentedFiles, plan.after.freeHoles))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                // C'est la stratégie qui commente ses propres compteurs : les
                // mêmes nombres ne disent pas la même chose d'un outil à
                // l'autre.
                Text(plan.strategy.summary(of: plan))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    private func progressBar(playback: DefragPlayback) -> some View {
        let progress = model.defragProgress(at: time)
        let moved = model.movedBytes(at: time) / 1_000_000
        let total = Double(playback.plan.movedBytes) / 1_000_000
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.read)
                        .frame(width: max(proxy.size.width * CGFloat(progress), 2))
                }
            }
            .frame(height: 5)
            HStack {
                Text(String(format: "%.0f %%", progress * 100))
                Spacer()
                Text(String(format: "%.0f Mo déplacés sur %.0f", moved, total))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
    }

    /// Le fichier d'échange et les répertoires ne pèsent que quelques blocs :
    /// inutile de leur réserver une entrée de légende s'ils sont absents.
    private func presentCategories(in plan: DefragPlan) -> [ClusterCategory] {
        var seen = Set<UInt8>(plan.initialMap)
        seen.insert(ClusterCategory.free.rawValue)
        return ClusterCategory.allCases.filter { seen.contains($0.rawValue) }
    }

    private var activityLED: some View {
        let on = model.activityLED(at: time)
        return VStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.read : Color.white.opacity(0.10))
                .frame(width: 13, height: 13)
                .shadow(color: on ? Theme.read.opacity(0.9) : .clear, radius: 7)
            Text("HDD")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }

    private var phaseBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.phaseColor(span?.index ?? 0))
                    .frame(width: 9, height: 9)
                Text(span?.label ?? "—")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.geometry.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Text(span?.detail ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            ActivityTimeline(
                spans: model.spans,
                iops: model.iops,
                peak: model.peakIOPS,
                duration: model.duration,
                currentTime: time,
                onSeek: { engine.seekTo($0) }
            )
            HStack {
                Text(time.clockString)
                Spacer()
                Text("crête \(Int(model.peakIOPS)) req/s")
                Spacer()
                Text(model.duration.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    private var transport: some View {
        HStack(spacing: 22) {
            Button {
                engine.seekTo(0)
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 19))
            }

            Button {
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.hierarchical)
            }

            Button {
                engine.seekTo(min(time + 5, model.duration))
            } label: {
                Image(systemName: "goforward.5").font(.system(size: 19))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("cylindre")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("\(Int(platter.cylinder.rounded()))")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.text)
        .panel()
    }

    private var stats: some View {
        let requestRate = model.bucketValue(model.iops, at: time)
        let throughput = model.bucketValue(model.throughputMBs, at: time)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Requêtes / s", value: String(format: "%.0f", requestRate), unit: "IOPS")
            StatTile(label: "Débit", value: String(format: "%.1f", throughput), unit: "Mo/s")
            StatTile(label: "Seek moyen", value: "\(model.stats.averageSeekDistance)", unit: "cyl.")
            StatTile(label: "Seeks simulés", value: "\(model.stats.seekCount)", unit: "total")
        }
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mixage des couches")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)

            LevelSlider(label: "Rotation (procédurale)", value: $engine.spindleLevel)
            LevelSlider(label: "Tête (banc de résonateurs)", value: $engine.transientLevel)
            LevelSlider(label: "Général", value: $engine.masterLevel)

            Divider().overlay(Theme.stroke).padding(.vertical, 4)

            if engine.supportsHaptics {
                Toggle(isOn: $engine.hapticsEnabled) {
                    Text("Retour haptique")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                if engine.hapticsEnabled {
                    LevelSlider(label: "Intensité des transitoires", value: $engine.hapticIntensity)
                    Toggle(isOn: $engine.spindleHaptics) {
                        Text("Grondement de rotation")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                    if engine.spindleHaptics {
                        LevelSlider(label: "Niveau du grondement", value: $engine.spindleHapticLevel)
                    }
                    Text(engine.hapticReport)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Retour haptique indisponible sur cet appareil")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// La géométrie change d'un scénario à l'autre — et d'un disque généré à
    /// l'autre : la note la lit plutôt que de la réciter.
    private var geometryNote: String {
        let g = model.geometry
        let rpm = String(format: "%d\u{202F}%03d", Int(g.rpm) / 1_000, Int(g.rpm) % 1_000)
        return "\(g.cylinders) cylindres, \(g.heads) têtes, \(g.zones.count) "
            + "zone\(g.zones.count > 1 ? "s" : "") ZBR, \(rpm) tr/min. La latence "
            + "rotationnelle et les pas de piste sont simulés secteur par secteur."
    }

    private var notes: some View {
        DisclosureGroup(isExpanded: $showsModelNotes) {
            VStack(alignment: .leading, spacing: 9) {
                if model.defrag != nil {
                    NoteRow("Volume", model.label.volumeNote)
                    NoteRow("Passe", "« Défragmentation complète » de Windows 95 : chaque fichier rendu contigu et tassé contre le début du volume, dans l'ordre du parcours de l'arborescence — le seul ordre dont l'outil disposait.")
                    NoteRow("Évacuations", "La destination d'un fichier est presque toujours occupée : l'occupant part d'abord vers la fin du volume, et sera redéplacé quand viendra son tour. C'est ce va-et-vient, pas le volume de données, qui fait durer une passe.")
                    NoteRow("Retours FAT", "Chaque déplacement validé réécrit les deux copies de la FAT et l'entrée de répertoire, au tout début de la partition. D'où le retour du bras vers le bord, environ une fois par fichier.")
                    NoteRow("Fichier d'échange", "Windows l'a ouvert : le défragmenteur ne peut pas le déplacer et tasse tout autour. C'est le bloc rouge qui ne bouge jamais.")
                }
                NoteRow("Seek", "Durée en deux régimes, a + b·√d puis c + e·d (Ruemmler & Wilkes 1994), découpée en speedup / coast / slowdown / settle.")
                NoteRow("Timbre", "Banc de résonateurs à fréquences fixes (modes ~4,5 et ~5,5 kHz). Seule l'excitation varie avec la distance : les résonances de l'actionneur ne se transposent pas avec la vitesse de seek.")
                NoteRow("Trains", "Deux seeks rapprochés ne relancent jamais deux one-shots : un seul rendu continu, transitoire terminal en fin de train (règle issue de l'émulation de disquette de MAME).")
                NoteRow("Rotation", "Procédurale faute d'échantillon. C'est le maillon faible : la littérature et tous les projets qui fonctionnent bouclent un enregistrement plutôt que de synthétiser le ronronnement à partir du régime.")
                NoteRow("Haptique", "Le Taptic Engine reçoit les mêmes repères que l'audio : choc à la mise en mouvement, grondement pendant le coast, choc à la décélération, tic d'asservissement. Les trains rapprochés passent en texture continue modulée plutôt qu'en salve de transitoires.")
                NoteRow("Géométrie", geometryNote)
            }
            .padding(.top, 10)
        } label: {
            Text("Ce que modélise le spike")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .panel()
    }
}

// MARK: - Petits composants

struct StatTile: View {
    let label: String
    let value: String
    let unit: String

    init(label: String, value: String, unit: String) {
        self.label = label
        self.value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
    }
}

private struct LevelSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.0f %%", value * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1)
        }
    }
}

private struct NoteRow: View {
    let title: String
    let body_: String

    init(_ title: String, _ body: String) {
        self.title = title
        self.body_ = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.read)
            Text(body_)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
