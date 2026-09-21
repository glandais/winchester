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

    init(model: SimulationModel, engine: WinchesterEngine, isVisible: Bool) {
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
                    ScreenTitle("instruments.title", verbatimSubtitle: model.label.title)

                    sectionTitle("instruments.section.live",
                                 note: String(localized: "instruments.section.live.note", defaultValue: "last minute"))
                    liveTiles(window, totals)

                    sectionTitle("instruments.section.total", note: Format.duration(clock.engine.currentTime))
                    timeBreakdown(totals.detail)
                    seekDistances(totals.detail)
                    cylinderHeat(totals.detail)
                    cumulative(totals)

                    if let playback = model.defrag {
                        sectionTitle("instruments.section.volume",
                                     note: model.end == nil
                                        ? String(localized: "instruments.note.beforeToReport", defaultValue: "before → at the report")
                                        : String(localized: "instruments.note.beforeAfter", defaultValue: "before → after"))
                        volumeState(playback)
                    } else if let install = model.install {
                        sectionTitle("instruments.section.install",
                                     note: model.end == nil
                                        ? String(localized: "instruments.note.arrivalAtReport", defaultValue: "arrival at the report")
                                        : String(localized: "instruments.note.report", defaultValue: "report"))
                        installState(install)
                    } else if let day = model.dayPlayback {
                        sectionTitle("instruments.section.day", note: day.date)
                        dayState(day)
                    } else if let boot = model.boot {
                        sectionTitle("instruments.section.boot",
                                     note: model.end == nil
                                        ? String(localized: "instruments.note.reportAtEnd", defaultValue: "report at the end")
                                        : String(localized: "instruments.note.report", defaultValue: "report"))
                        bootState(boot)
                    }
                }
                .padding(16)
            }
        }
        .onAppear { clock.isRelaying = isVisible }
        .onChange(of: isVisible) { _, visible in clock.isRelaying = visible }
    }

    /// Le titre porte déjà ses capitales dans le catalogue : `uppercased()`
    /// suit la locale de l'appareil, pas celle du texte.
    private func sectionTitle(_ title: LocalizedStringKey, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(note)
                .font(.dynamic(size: 11, design: .monospaced))
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
                           value: Format.integer(window.requestsLastSecond),
                           detail: readShare.map {
                               String(localized: "instruments.iops.share",
                                      defaultValue: "\(Format.percent($0)) read · \(Format.percent(1 - $0)) write")
                           } ?? String(localized: "instruments.iops.idle", defaultValue: "idle"),
                           series: window.requestsPerSecond,
                           color: Theme.read)
            InstrumentTile(label: String(localized: "instruments.tile.throughput", defaultValue: "Throughput"),
                           value: String(localized: "instruments.unit.megabytesPerSecond",
                                         defaultValue: "\(Format.decimal(window.megabytesLastSecond, digits: 1)) MB/s"),
                           // « max 1,8 → 1,2 Mo/s » ne se lisait pas seul : la
                           // flèche est celle du bord vers le centre du plateau,
                           // où les pistes sont plus courtes (`UX_REVIEW.md` §4).
                           detail: String(localized: "instruments.throughput.ceiling",
                                          defaultValue: "ceiling \(Format.decimal(geometry.outerSustainedMBs, digits: 1)) MB/s at the edge, \(Format.decimal(geometry.innerSustainedMBs, digits: 1)) at the centre"),
                           series: window.megabytesPerSecond,
                           color: Theme.write)
            InstrumentTile(label: String(localized: "instruments.tile.averageSeek", defaultValue: "Average seek"),
                           value: String(localized: "instruments.unit.cylinders",
                                         defaultValue: "\(Format.integer(average)) cyl."),
                           detail: average > 0
                               ? String(localized: "instruments.averageSeek.detail",
                                        defaultValue: "that is ≈ \(Format.decimal(averageMs, digits: 1)) ms")
                               : String(localized: "instruments.averageSeek.none", defaultValue: "no seek"),
                           series: window.averageSeekPerSecond,
                           color: Theme.arm,
                           why: .seekLaw)
            InstrumentTile(label: String(localized: "instruments.tile.seeks", defaultValue: "Seeks"),
                           value: Format.integer(totals.seeks),
                           detail: String(localized: "instruments.seeks.detail",
                                          defaultValue: "since the pass started"),
                           series: window.seeksPerSecond,
                           color: Theme.arm)
        }
    }

    // MARK: - Depuis le début

    /// Où passe le temps : c'est le graphique qui dit pourquoi une passe est
    /// lente — un bras qui court, ou un disque qui attend la machine.
    private func timeBreakdown(_ detail: ActivityDetail) -> some View {
        let parts: [(String, Double, Color)] = [
            (String(localized: "instruments.time.seek", defaultValue: "seek"), detail.seekSeconds, Theme.read),
            (String(localized: "instruments.time.rotation", defaultValue: "rotation"), detail.rotationSeconds, Theme.arm),
            (String(localized: "instruments.time.transfer", defaultValue: "transfer"), detail.transferSeconds, Theme.write),
            (String(localized: "instruments.time.buffer", defaultValue: "buffer"), detail.bufferSeconds, Theme.write.opacity(0.45)),
            (String(localized: "instruments.time.compute", defaultValue: "compute"), detail.thinkSeconds, Color(red: 0.62, green: 0.48, blue: 0.86)),
            (String(localized: "instruments.time.wait", defaultValue: "wait"), detail.waitSeconds, Color.white.opacity(0.18)),
        ]
        let total = parts.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 10) {
            Text("instruments.time.title")
                .font(.dynamic(size: 14, weight: .semibold))
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
                        Text(verbatim: "\(parts[index].0) \(Format.percent(total > 0 ? parts[index].1 / total : 0))")
                            .font(.dynamic(size: 11, design: .monospaced))
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
                Text("instruments.seekDistance.title")
                    .font(.dynamic(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("instruments.seekDistance.note")
                    .font(.dynamic(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(SeekClass.allCases, id: \.rawValue) { seekClass in
                let count = counts[seekClass.rawValue]
                HStack(spacing: 8) {
                    Text(seekClass.label)
                        .font(.dynamic(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 104, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.read.opacity(0.85))
                            .frame(width: max(proxy.size.width * CGFloat(count) / CGFloat(largest), count > 0 ? 2 : 0))
                    }
                    .frame(height: 10)
                    Text(Format.integer(count))
                        .font(.dynamic(size: 11, design: .monospaced))
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
                Text("instruments.cylinders.title")
                    .font(.dynamic(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(verbatim: String(localized: "instruments.cylinders.count",
                                      defaultValue: "\(Format.integer(model.geometry.cylinders)) cylinders"))
                    .font(.dynamic(size: 10, design: .monospaced))
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
                Text("instruments.cylinders.edge")
                Spacer()
                Text("instruments.cylinders.hub")
            }
            .font(.dynamic(size: 10, design: .monospaced))
            .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("instruments.cylinders.accessibility")
    }

    private func cumulative(_ totals: ActivityTotals) -> some View {
        let moves = model.live.moves
        let isDefrag = model.defrag != nil
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: String(localized: "instruments.stat.requests", defaultValue: "Requests"),
                     value: Format.integer(totals.requests), unit: "")
            StatTile(label: String(localized: "instruments.stat.read", defaultValue: "Read"),
                     value: Format.megabytes(UInt64(totals.detail.readBytes)), unit: "")
            StatTile(label: String(localized: "instruments.stat.written", defaultValue: "Written"),
                     value: Format.megabytes(UInt64(totals.detail.writeBytes)), unit: "")
            if isDefrag {
                StatTile(label: String(localized: "instruments.stat.moved", defaultValue: "Moved"),
                         value: Format.megabytes(UInt64(totals.movedBytes)),
                         unit: movedShare(totals.movedBytes).map {
                             String(localized: "instruments.stat.moved.share",
                                    defaultValue: "\($0) of the contents")
                         } ?? "")
                StatTile(label: String(localized: "instruments.stat.filesMoved", defaultValue: "Files moved"),
                         value: moves.map { Format.integer($0.filesMoved) } ?? "0", unit: "")
                StatTile(label: String(localized: "instruments.stat.evacuations", defaultValue: "Evacuations"),
                         value: moves.map { Format.integer($0.evacuations) } ?? "0", unit: "")
            } else if let install = model.install {
                StatTile(label: String(localized: "instruments.stat.filesLaid", defaultValue: "Files laid down"),
                         value: moves.map { Format.integer($0.filesMoved) } ?? "0",
                         unit: String(localized: "instruments.stat.outOf",
                                      defaultValue: "of \(Format.integer(install.files))"))
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
        return Format.percent(Double(moved) / content)
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
                    .font(.dynamic(size: 13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(before)
                    .font(.dynamic(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text(verbatim: "→")
                    .font(.dynamic(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Text(after ?? "…")
                    .font(.dynamic(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(after == nil ? Theme.dim : Theme.read)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .monospacedDigit()
        }
        return VStack(alignment: .leading, spacing: 10) {
            // Le taux entre parenthèses est celui de tout le catalogue,
            // répertoires compris ; la fiche du disque affiche celui des
            // fragmentables, plus élevé.
            row(String(localized: "instruments.row.fragmentedItems", defaultValue: "Fragmented items"),
                "\(Format.integer(before.fragmentedFiles)) (\(Format.percent(before.fragmentedRatio)))",
                after.map { "\(Format.integer($0.fragmentedFiles)) (\(Format.percent($0.fragmentedRatio)))" })
            row(String(localized: "instruments.row.piecesToMerge", defaultValue: "Pieces to merge"),
                Format.integer(before.fragments),
                after.map { Format.integer($0.fragments) })
            row(String(localized: "instruments.row.freeHoles", defaultValue: "Free holes"),
                Format.integer(before.freeHoles),
                after.map { Format.integer($0.freeHoles) })
            row(String(localized: "instruments.row.piecesPerFile", defaultValue: "Pieces per file"),
                Format.decimal(before.extentsPerFile, digits: 2),
                after.map { Format.decimal($0.extentsPerFile, digits: 2) })
            HStack(alignment: .top, spacing: 4) {
                Text("instruments.fragmented.note")
                    .font(.dynamic(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                WhyButton(topic: .fragmentedVsPieces)
                    .padding(.vertical, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Ce que l'installation laisse : le disque au soir du jour 0, que l'usage
    /// va vieillir.
    private func installState(_ install: InstallPlayback) -> some View {
        let arrival = install.installed.metrics
        let done = model.end != nil
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            let when = done ? String(localized: "instruments.unit.onArrival", defaultValue: "on arrival")
                            : String(localized: "instruments.unit.atReport", defaultValue: "at the report")
            StatTile(label: String(localized: "instruments.stat.archives", defaultValue: "Archives"),
                     value: Format.integer(install.temporaryFiles),
                     unit: String(localized: "instruments.stat.archives.unit", defaultValue: "extracted then deleted"))
            StatTile(label: String(localized: "instruments.stat.reboots", defaultValue: "Restarts"),
                     value: Format.integer(install.reboots), unit: "", why: .installation)
            StatTile(label: String(localized: "instruments.stat.fragmented", defaultValue: "Fragmented"),
                     value: done ? Format.integer(arrival.fragmentedFileCount) : "…", unit: when)
            StatTile(label: String(localized: "instruments.row.freeHoles", defaultValue: "Free holes"),
                     value: done ? Format.integer(arrival.freeRunCount) : "…", unit: when)
        }
    }

    /// Le disque au matin de cette journée-là : c'est lui qu'on entend.
    private func dayState(_ day: DayPlayback) -> some View {
        let metrics = day.disk.metrics
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: String(localized: "instruments.stat.day", defaultValue: "Day"),
                     value: Format.integer(Int(day.day)), unit: day.date)
            StatTile(label: String(localized: "instruments.stat.fill", defaultValue: "Fill"),
                     value: Format.percent(metrics.fill),
                     unit: String(localized: "instruments.stat.fill.unit", defaultValue: "this morning"))
            StatTile(label: String(localized: "instruments.stat.inPieces", defaultValue: "In pieces"),
                     value: Format.integer(metrics.fragmentedFileCount),
                     unit: String(localized: "instruments.stat.files.unit", defaultValue: "files"), why: .fragmentedVsPieces)
            StatTile(label: String(localized: "instruments.stat.toWrite", defaultValue: "To write"),
                     value: Format.megabytes(UInt64(day.bytes)),
                     unit: String(localized: "instruments.stat.today.unit", defaultValue: "today"))
        }
    }

    private func bootState(_ boot: BootPlayback) -> some View {
        let duration = model.end?.duration
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            StatTile(label: String(localized: "instruments.stat.filesRead", defaultValue: "Files read"),
                     value: Format.integer(boot.filesRead), unit: "")
            StatTile(label: String(localized: "instruments.stat.compute", defaultValue: "Compute"),
                     value: Format.decimal(boot.thinkSeconds, digits: 1),
                     unit: String(localized: "instruments.unit.seconds", defaultValue: "s"))
            StatTile(label: String(localized: "instruments.stat.diskWait", defaultValue: "Disk wait"),
                     value: duration.map { Format.decimal(boot.diskSeconds(duration: $0), digits: 1) } ?? "…",
                     unit: String(localized: "instruments.unit.seconds", defaultValue: "s"))
            StatTile(label: String(localized: "instruments.stat.witness", defaultValue: "Witness"),
                     value: Format.decimal(boot.freshSeconds, digits: 1),
                     unit: duration.map { boot.freshSeconds > 0
                         ? Format.signedPercent(($0 / boot.freshSeconds - 1) * 100)
                         : "" } ?? String(localized: "instruments.stat.witness.unit", defaultValue: "s, never fragmented"),
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
                megabytesLastSecond += FrenchUnits.megabytesPerSecond(Double(bucket.bytes))
            }
            let slot = seconds - 1 - (current - Int(bucket.start))
            guard slot >= 0 && slot < seconds else { continue }
            requests[slot] += bucket.requests
            bytes[slot] += bucket.bytes
            seeks[slot] += bucket.seeks
            distance[slot] += bucket.seekDistance
        }
        requestsPerSecond = requests.map(Double.init)
        megabytesPerSecond = bytes.map { FrenchUnits.megabytesPerSecond(Double($0)) }
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
                    .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                if let why {
                    Spacer(minLength: 0)
                    WhyButton(topic: why, context: "\(label) · \(value)")
                        .padding(-6)
                }
            }
            Text(value)
                .font(.dynamic(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
            Text(detail)
                .font(.dynamic(size: 10))
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
        .accessibilityLabel(String(localized: "instruments.tile.accessibility",
                                   defaultValue: "\(label), \(value), \(detail)",
                                   comment: "Étiquette d'une tuile : son nom, sa valeur, son détail"))
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
