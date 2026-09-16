import SwiftUI
import DiskCore

/// Deux écrans : la simulation sonore, et la galerie de disques d'époque.
///
/// Ils ne partagent rien d'autre que le thème — le premier fait du bruit à
/// partir d'un scénario figé, le second fabrique des volumes et les montre. La
/// jonction entre les deux se fait par deux boutons : **démarrer** le disque
/// qu'on vient de générer, ou le **défragmenter**. Le premier marche sur les
/// vingt profils, le second n'a de sens que sur les volumes qu'un
/// défragmenteur de 1995 pourrait ouvrir.
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
                        DiskLibraryView(model: library) { disk, activity in
                            try model.load(generated: disk, as: activity)
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
    @State private var showsFullScreenMap = false

    private var time: Double { engine.currentTime }
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
                    if let boot = model.boot { bootPanel(boot) }
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
            let active = model.activeCell()
            let before = playback.before
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Volume C:")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(playback.partition.capacityDescription) · \(playback.partition.format.label) · clusters de \(playback.partition.clusterBytes / 1024) Ko")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    // Le plein écran est à côté du titre du volume, là où l'œil
                    // passe déjà, plutôt qu'en surimpression sur la carte où il
                    // masquerait des blocs.
                    FullScreenMapButton { showsFullScreenMap = true }
                }

                // L'outil qu'on écoute. Sans lui, deux passes aux signatures
                // sonores opposées s'annoncent de la même façon, et le seul
                // indice de ce qui a changé est un compteur.
                Text(playback.strategy.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)

                ClusterMapView(grid: model.mapGrid,
                               shades: model.clusterShades(at: time),
                               activeCell: active?.cell,
                               activeIsWrite: active?.isWrite ?? false)
                    // La carte entière ouvre le plein écran : c'est le geste
                    // qu'on essaie d'abord, et il ne coûte rien de le servir.
                    .contentShape(Rectangle())
                    .onTapGesture { showsFullScreenMap = true }

                progressBar()

                ClusterLegend(categories: presentCategories(in: playback),
                              clustersPerCell: model.clustersPerCell,
                              clusterBytes: playback.partition.clusterBytes)

                // L'arrivée n'est connue qu'une fois la passe entendue jusqu'au
                // bout : elle se calcule pendant qu'on l'écoute.
                let plan = model.end?.plan
                Text(String(format: "Au départ : %d fichiers, %d fragmentés (%.0f %%), %.2f extents par fichier, %d trous dans l'espace libre.",
                            before.fileCount, before.fragmentedFiles,
                            before.fragmentedRatio * 100, before.extentsPerFile,
                            before.freeHoles)
                     + (plan.map { String(format: " À l'arrivée : %d fragmentés, %d trous.",
                                          $0.after.fragmentedFiles, $0.after.freeHoles) } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)

                // C'est la stratégie qui commente ses propres compteurs : les
                // mêmes nombres ne disent pas la même chose d'un outil à
                // l'autre.
                if let plan {
                    Text(plan.strategy.summary(of: plan))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .fullScreenCover(isPresented: $showsFullScreenMap) {
                DefragFullScreenMap(model: model, engine: engine)
            }
        }
    }

    /// L'avancement tel que l'outil l'annonçait. Il n'y a plus de total à
    /// afficher : on ne sait ce qu'une passe déplacera qu'une fois déplacé.
    private func progressBar() -> some View {
        let progress = model.defragProgress ?? 0
        let moved = model.movedBytes / 1_000_000
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
                Text(String(format: "%.0f Mo déplacés", moved))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
    }

    /// Le fichier d'échange et les répertoires ne pèsent que quelques blocs :
    /// inutile de leur réserver une entrée de légende s'ils sont absents.
    private func presentCategories(in playback: DefragPlayback) -> [ClusterCategory] {
        var seen = Set<UInt8>(playback.initialRuns.lazy.map(\.category))
        seen.insert(ClusterCategory.free.rawValue)
        return ClusterCategory.allCases.filter { seen.contains($0.rawValue) }
    }

    private var activityLED: some View {
        let on = model.activityLED
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
                    .fill(Theme.phaseColor(model.phaseIndex))
                    .frame(width: 9, height: 9)
                Text(model.phase?.label ?? "—")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.geometry.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            Text(model.phase?.detail ?? "")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Le bilan d'un démarrage. Il n'y a pas de carte à montrer — un démarrage
    /// ne déplace rien — mais il y a une chose à dire : ce que ce volume-là
    /// coûte par rapport au même contenu jamais fragmenté.
    private func bootPanel(_ boot: BootPlayback) -> some View {
        // Ce que le disque a coûté ne se sait qu'à la fin du démarrage.
        let duration = model.end?.duration
        let disk = duration.map { String(format: "%.0f", boot.diskSeconds(duration: $0)) } ?? "…"
        let penalty = duration.map { boot.freshSeconds > 0
            ? String(format: "%+.0f %%", ($0 / boot.freshSeconds - 1) * 100)
            : "" } ?? "à venir"
        return VStack(alignment: .leading, spacing: 10) {
            Text(boot.appName.map { "\(boot.osName), puis \($0)" } ?? boot.osName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)

            FlowRow(spacing: 10) {
                StatTile(label: "Fichiers lus", value: "\(boot.filesRead)",
                         unit: boot.residentFiles > 0 ? "\(boot.residentFiles) résidents" : "ouverts")
                StatTile(label: "Calcul", value: String(format: "%.0f", boot.thinkSeconds), unit: "s")
                StatTile(label: "Disque", value: disk, unit: "s d'attente")
                StatTile(label: "Jamais fragmenté",
                         value: String(format: "%.0f", boot.freshSeconds),
                         unit: penalty)
            }

            Text("Le témoin lit exactement les mêmes fichiers, d'un seul tenant chacun et "
                 + "rangés dans l'ordre du répertoire. L'écart dit ce que ce volume-ci fait "
                 + "payer à son démarrage — ou ce qu'il lui fait gagner, quand son "
                 + "allocateur place mieux qu'un empilement.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            ActivityTimeline(
                marks: model.live.phaseMarks,
                buckets: model.live.buckets,
                now: time,
                window: LivePass.activityWindow
            )
            HStack {
                Text("−1 min")
                Spacer()
                Text(model.totals.requests > 0 ? "\(model.totals.requests) requêtes" : "")
                Spacer()
                Text(time.clockString)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    private var transport: some View {
        HStack(spacing: 22) {
            // Revenir au début, c'est relancer la passe : il n'y a plus de
            // chronologie où sauter.
            Button {
                model.restart()
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 19))
            }
            .accessibilityLabel("Relancer la passe")

            Button {
                if engine.isFinished { model.restart() }
                engine.toggle()
            } label: {
                Image(systemName: engine.isPlaying || engine.isBuffering
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .symbolRenderingMode(.hierarchical)
            }

            if engine.isBuffering {
                ProgressView()
                    .tint(Theme.dim)
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
        let requestRate = model.requestRate
        let throughput = model.throughputMBs
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Requêtes / s", value: String(format: "%.0f", requestRate), unit: "IOPS")
            StatTile(label: "Débit", value: String(format: "%.1f", throughput), unit: "Mo/s")
            StatTile(label: "Seek moyen", value: "\(model.totals.averageSeekDistance)", unit: "cyl.")
            StatTile(label: "Seeks simulés", value: "\(model.totals.seeks)", unit: "jusqu'ici")
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
