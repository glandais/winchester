import SwiftUI
import DiskCore

/// Les instruments de la passe — maquette 11.
///
/// Trois étages : ce qui se passe maintenant, sur la dernière minute ; ce qui
/// s'est accumulé depuis le début ; et ce que la passe fait du volume. Rien ne
/// se projette : pas de durée restante, pas d'état futur.
///
/// Tout se lit sur `LivePass` à l'instant écouté, à travers le relais d'horloge,
/// coupé quand l'onglet est caché.
struct InstrumentsScreen: View {

    @ObservedObject var model: SimulationModel
    @StateObject private var clock: ClockRelay
    let isVisible: Bool

    init(model: SimulationModel, engine: DiskNoiseEngine, isVisible: Bool) {
        _model = ObservedObject(wrappedValue: model)
        _clock = StateObject(wrappedValue: ClockRelay(engine: engine))
        self.isVisible = isVisible
    }

    var body: some View {
        // Une lecture de la dernière minute par image, partagée par les tuiles.
        let window = RecentActivity(buckets: model.live.buckets, now: clock.engine.currentTime)
        let totals = model.totals
        return ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScreenTitle("Instruments", subtitle: model.label.title)

                    sectionTitle("En direct", note: "dernière minute")
                    liveTiles(window, totals)

                    sectionTitle("Depuis le début", note: FrenchFormat.duration(clock.engine.currentTime))
                    timeBreakdown(totals.detail)
                    seekDistances(totals.detail)
                    cylinderHeat(totals.detail)
                    cumulative(totals)

                    if let playback = model.defrag {
                        sectionTitle("Le volume", note: model.end == nil ? "avant → au bilan" : "avant → après")
                        volumeState(playback)
                    } else if let boot = model.boot {
                        sectionTitle("Le démarrage", note: model.end == nil ? "bilan à la fin" : "bilan")
                        bootState(boot)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { clock.isRelaying = isVisible }
        .onChange(of: isVisible) { _, visible in clock.isRelaying = visible }
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(note)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
        .padding(.top, 4)
    }

    // MARK: - En direct

    private func liveTiles(_ window: RecentActivity, _ totals: ActivityTotals) -> some View {
        let geometry = model.geometry
        let average = totals.averageSeekDistance
        let averageMs = average > 0 ? model.live.seekModel.duration(distance: average) * 1_000 : 0
        let readShare = window.requestsLastSecond > 0
            ? Double(window.readsLastSecond) / Double(window.requestsLastSecond) : nil
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            InstrumentTile(label: "IOPS",
                           value: FrenchFormat.integer(window.requestsLastSecond),
                           detail: readShare.map { "\(FrenchFormat.percent($0)) lecture · \(FrenchFormat.percent(1 - $0)) écriture" }
                               ?? "au repos",
                           series: window.requestsPerSecond,
                           color: Theme.read)
            InstrumentTile(label: "Débit",
                           value: FrenchFormat.decimal(window.megabytesLastSecond, digits: 1) + "\u{00A0}Mo/s",
                           detail: "max \(FrenchFormat.decimal(geometry.outerSustainedMBs, digits: 1)) → "
                               + "\(FrenchFormat.decimal(geometry.innerSustainedMBs, digits: 1)) Mo/s",
                           series: window.megabytesPerSecond,
                           color: Theme.write)
            InstrumentTile(label: "Seek moyen",
                           value: FrenchFormat.integer(average) + "\u{00A0}cyl.",
                           detail: average > 0 ? "soit ≈ \(FrenchFormat.decimal(averageMs, digits: 1)) ms" : "aucun seek",
                           series: window.averageSeekPerSecond,
                           color: Theme.arm,
                           why: .seekLaw)
            InstrumentTile(label: "Seeks",
                           value: FrenchFormat.integer(totals.seeks),
                           detail: "depuis le début de la passe",
                           series: window.seeksPerSecond,
                           color: Theme.arm)
        }
    }

    // MARK: - Depuis le début

    /// Où passe le temps : c'est le graphique qui dit pourquoi une passe est
    /// lente — un bras qui court, ou un disque qui attend la machine.
    private func timeBreakdown(_ detail: ActivityDetail) -> some View {
        let parts: [(String, Double, Color)] = [
            ("seek", detail.seekSeconds, Theme.read),
            ("rotation", detail.rotationSeconds, Theme.arm),
            ("transfert", detail.transferSeconds, Theme.write),
            ("calcul", detail.thinkSeconds, Color(red: 0.62, green: 0.48, blue: 0.86)),
            ("attente", detail.waitSeconds, Color.white.opacity(0.18)),
        ]
        let total = parts.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Où passe le temps")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(parts.indices, id: \.self) { index in
                        let share = total > 0 ? parts[index].1 / total : 0
                        Rectangle()
                            .fill(parts[index].2)
                            .frame(width: max(proxy.size.width * share - 1, 0))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            FlowRow(spacing: 12) {
                ForEach(parts.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(parts[index].2).frame(width: 9, height: 9)
                        Text("\(parts[index].0) \(FrenchFormat.percent(total > 0 ? parts[index].1 / total : 0))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func seekDistances(_ detail: ActivityDetail) -> some View {
        let counts = detail.seekClasses
        let largest = max(counts.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Distance des seeks")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("rapportée à la course")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(SeekClass.allCases, id: \.rawValue) { seekClass in
                let count = counts[seekClass.rawValue]
                HStack(spacing: 8) {
                    Text(seekClass.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 104, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.read.opacity(0.85))
                            .frame(width: max(proxy.size.width * CGFloat(count) / CGFloat(largest), count > 0 ? 2 : 0))
                    }
                    .frame(height: 10)
                    Text(FrenchFormat.integer(count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .frame(width: 70, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func cylinderHeat(_ detail: ActivityDetail) -> some View {
        let bands = detail.cylinderBands
        let largest = max(bands.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cylindres visités")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(FrenchFormat.integer(model.geometry.cylinders)) cylindres")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            HStack(spacing: 2) {
                ForEach(bands.indices, id: \.self) { index in
                    let share = Double(bands[index]) / Double(largest)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bands[index] == 0 ? Color.white.opacity(0.05) : Theme.read.opacity(0.15 + 0.85 * share))
                        .frame(height: 26)
                }
            }
            HStack {
                Text("bord")
                Spacer()
                Text("moyeu")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cylindres visités, du bord vers le moyeu")
    }

    private func cumulative(_ totals: ActivityTotals) -> some View {
        let moves = model.live.moves
        let isDefrag = model.defrag != nil
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Requêtes", value: FrenchFormat.integer(totals.requests), unit: "")
            StatTile(label: "Lu", value: FrenchFormat.megabytes(UInt64(totals.detail.readBytes)), unit: "")
            StatTile(label: "Écrit", value: FrenchFormat.megabytes(UInt64(totals.detail.writeBytes)), unit: "")
            if isDefrag {
                StatTile(label: "Déplacé", value: FrenchFormat.megabytes(UInt64(totals.movedBytes)),
                         unit: movedShare(totals.movedBytes).map { "\($0) du contenu" } ?? "")
                StatTile(label: "Fichiers déplacés",
                         value: moves.map { FrenchFormat.integer($0.filesMoved) } ?? "0", unit: "")
                StatTile(label: "Évacuations",
                         value: moves.map { FrenchFormat.integer($0.evacuations) } ?? "0", unit: "")
            }
        }
    }

    /// Octets déplacés rapportés au contenu du volume au départ : au-delà de
    /// 100 %, la passe a déplacé plus que ce que le disque contient.
    private func movedShare(_ moved: Int) -> String? {
        guard let playback = model.defrag else { return nil }
        let content = playback.before.fill * Double(playback.partition.clusterCount)
            * Double(playback.partition.clusterBytes)
        guard content > 0 else { return nil }
        return FrenchFormat.percent(Double(moved) / content)
    }

    // MARK: - Le volume

    /// Avant, et après une fois la passe entendue jusqu'au bout. Les deux
    /// mesures de fragmentation côte à côte : elles ne racontent pas la même
    /// chose.
    private func volumeState(_ playback: DefragPlayback) -> some View {
        let before = playback.before
        let after = model.end?.plan?.after
        func row(_ label: String, _ before: String, _ after: String?) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(before)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text("→")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text(after ?? "…")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(after == nil ? Theme.dim : Theme.read)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .monospacedDigit()
        }
        return VStack(alignment: .leading, spacing: 10) {
            row("Fichiers fragmentés",
                "\(FrenchFormat.integer(before.fragmentedFiles)) (\(FrenchFormat.percent(before.fragmentedRatio)))",
                after.map { "\(FrenchFormat.integer($0.fragmentedFiles)) (\(FrenchFormat.percent($0.fragmentedRatio)))" })
            row("Morceaux à recoller",
                FrenchFormat.integer(before.fragments),
                after.map { FrenchFormat.integer($0.fragments) })
            row("Trous libres",
                FrenchFormat.integer(before.freeHoles),
                after.map { FrenchFormat.integer($0.freeHoles) })
            row("Morceaux par fichier",
                FrenchFormat.decimal(before.extentsPerFile, digits: 2),
                after.map { FrenchFormat.decimal($0.extentsPerFile, digits: 2) })
            HStack(alignment: .top, spacing: 4) {
                Text("Un fichier ramené de quarante morceaux à deux reste compté comme fragmenté : "
                     + "les fichiers fragmentés et les morceaux ne racontent pas la même chose.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                WhyButton(topic: .fragmentedVsPieces)
                    .padding(.vertical, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func bootState(_ boot: BootPlayback) -> some View {
        let duration = model.end?.duration
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: "Fichiers lus", value: FrenchFormat.integer(boot.filesRead), unit: "")
            StatTile(label: "Calcul", value: FrenchFormat.decimal(boot.thinkSeconds, digits: 1), unit: "s")
            StatTile(label: "Attente disque",
                     value: duration.map { FrenchFormat.decimal(boot.diskSeconds(duration: $0), digits: 1) } ?? "…",
                     unit: "s")
            StatTile(label: "Témoin",
                     value: FrenchFormat.decimal(boot.freshSeconds, digits: 1),
                     unit: duration.map { boot.freshSeconds > 0
                         ? String(format: "%+.1f %%", ($0 / boot.freshSeconds - 1) * 100)
                             .replacingOccurrences(of: ".", with: ",")
                         : "" } ?? "s, jamais fragmenté",
                     why: .witness)
        }
    }
}

/// La dernière minute d'activité, seconde par seconde.
///
/// Les tranches de `LivePass` durent un dixième de seconde : une courbe de six
/// cents points ne dirait rien de plus que soixante, et la valeur d'une tuile
/// lue sur une seule tranche sauterait à chaque image.
private struct RecentActivity {

    var requestsPerSecond: [Double] = []
    var megabytesPerSecond: [Double] = []
    var seeksPerSecond: [Double] = []
    var averageSeekPerSecond: [Double] = []
    var requestsLastSecond = 0
    var readsLastSecond = 0
    var megabytesLastSecond = 0.0

    init(buckets: [ActivityBucket], now: Double) {
        let seconds = Int(LivePass.activityWindow)
        let current = Int(now)
        var requests = [Int](repeating: 0, count: seconds)
        var bytes = [Int](repeating: 0, count: seconds)
        var seeks = [Int](repeating: 0, count: seconds)
        var distance = [Int](repeating: 0, count: seconds)
        let lastSecond = ActivityBucket.index(at: max(now - 1, 0))..<ActivityBucket.index(at: now)
        for bucket in buckets where bucket.start <= now {
            if lastSecond.contains(bucket.index) {
                requestsLastSecond += bucket.requests
                readsLastSecond += bucket.detail.readRequests
                megabytesLastSecond += Double(bucket.bytes) / 1_000_000
            }
            let slot = seconds - 1 - (current - Int(bucket.start))
            guard slot >= 0 && slot < seconds else { continue }
            requests[slot] += bucket.requests
            bytes[slot] += bucket.bytes
            seeks[slot] += bucket.seeks
            distance[slot] += bucket.seekDistance
        }
        requestsPerSecond = requests.map(Double.init)
        megabytesPerSecond = bytes.map { Double($0) / 1_000_000 }
        seeksPerSecond = seeks.map(Double.init)
        averageSeekPerSecond = zip(distance, seeks).map { $1 > 0 ? Double($0) / Double($1) : 0 }
    }
}

/// Une tuile d'instrument : valeur, précision, et la dernière minute en courbe.
private struct InstrumentTile: View {
    let label: String
    let value: String
    let detail: String
    let series: [Double]
    let color: Color
    var why: Explanation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if let why {
                    Spacer(minLength: 0)
                    WhyButton(topic: why, context: "\(label) · \(value)")
                        .padding(-6)
                }
            }
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Sparkline(values: series, color: color)
                .frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value), \(detail)")
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(values.max() ?? 0, 1e-9)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step,
                                    y: size.height - CGFloat(value / top) * (size.height - 1))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.15)))
            context.stroke(line, with: .color(color), lineWidth: 1.2)
        }
    }
}
