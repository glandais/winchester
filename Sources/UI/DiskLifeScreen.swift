import SwiftUI
import DiskCore

/// Revivre un disque : deux ans en accéléré, et l'on s'arrête pour écouter.
///
/// Le défilement ne joue rien — une vie entière dure des centaines d'heures à
/// l'oreille. Il montre ce que le volume devient : la carte se remplit, les
/// courbes montent, et les journées qui valent d'être entendues se nomment au
/// passage. Toucher « Écouter cette journée » rend la main à la passe, sur le
/// disque tel qu'il est ce matin-là.
struct DiskLifeScreen: View {

    @ObservedObject var model: SimulationModel
    /// Le défilement, tenu **hors** de ce plein écran.
    ///
    /// Il naissait avec la vue et mourait avec elle : on avançait jusqu'au jour
    /// 12, on écoutait le jour 13, on rouvrait Revivre, et l'écran repartait du
    /// jour 0 (`UX_REVIEW.md` §2.6). Le commentaire de `SimulationModel.load`
    /// promettait que « le défilement reprendra ensuite au lendemain » ; il le
    /// fait désormais.
    @ObservedObject var life: DiskLifeModel
    /// La journée est lancée : on ferme et on ouvre l'onglet de la passe.
    let onListen: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(life: DiskLifeModel, model: SimulationModel, onListen: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _life = ObservedObject(wrappedValue: life)
        self.onListen = onListen
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        map
                        counters
                        curves
                        landmarks
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { transport }
            .navigationTitle("life.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { life.pause(); dismiss() }
                }
            }
        }
        .tint(Theme.read)
        .preferredColorScheme(.dark)
        .onDisappear { life.pause() }
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(life.disk.spec.displayName)
                .font(.dynamic(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(alignment: .firstTextBaseline) {
                Text(life.date.uppercased())
                    .font(.dynamic(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.read)
                Spacer()
                Text(verbatim: String(localized: "life.day",
                                      defaultValue: "DAY \(Format.integer(Int(life.day))) / \(Format.integer(Int(life.dayCount)))",
                                      comment: "Compteur du défilement, en capitales"))
                    .font(.dynamic(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.read)
                        .frame(width: max(proxy.size.width * life.progress, 2))
                }
            }
            .frame(height: 5)
            if let landmark = life.currentLandmark {
                Text(landmark.uppercased())
                    .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.write)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - La carte

    private var map: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClusterMapView(grid: life.grid, shades: life.shades)
            Text("life.map.note")
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim)
        }
        .panel()
    }

    private var counters: some View {
        TileGrid(columns: 2) {
            StatTile(label: String(localized: "instruments.stat.fill", defaultValue: "Fill"), value: Format.percent(life.fill),
                     unit: String(localized: "life.stat.ofVolume", defaultValue: "of the volume"))
            StatTile(label: String(localized: "life.stat.files", defaultValue: "Files"), value: Format.integer(life.fileCount),
                     unit: String(localized: "life.stat.inCatalogue", defaultValue: "in the catalogue"))
            StatTile(label: String(localized: "instruments.stat.inPieces", defaultValue: "In pieces"),
                     value: Format.integer(life.fragmentedFiles),
                     unit: String(localized: "instruments.stat.files.unit", defaultValue: "files"), why: .fragmentedVsPieces)
            StatTile(label: String(localized: "life.stat.writtenToday", defaultValue: "Written that day"),
                     value: Format.megabytes(UInt64(life.bytesWritten)),
                     unit: life.activities.isEmpty
                         ? String(localized: "life.stat.nothingToDo", defaultValue: "nothing to do")
                         : life.activities.joined(separator: ", "))
        }
    }

    // MARK: - Les courbes

    /// Remplissage et fichiers en morceaux depuis le premier jour. Deux
    /// courbes, la même histoire : l'un précède l'autre.
    private var curves: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("life.curves.header")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Curve(values: life.fillCurve, colour: Theme.read, maximum: 1)
                .frame(height: 44)
            Curve(values: life.fragmentedCurve.map(Double.init), colour: Theme.write,
                  maximum: max(life.fragmentedCurve.map(Double.init).max() ?? 1, 1))
                .frame(height: 44)
            HStack {
                legend(Theme.read, "life.curve.fill")
                legend(Theme.write, "life.curve.fragmented")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func legend(_ colour: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 3)
            Text(label)
                .font(.dynamic(size: 11, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }

    // MARK: - Les repères

    private var landmarks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("life.days.header")
                .font(.dynamic(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
            if life.landmarks.isEmpty {
                Text("life.days.empty")
                    .font(.dynamic(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            ForEach(life.landmarks.reversed().prefix(8)) { digest in
                HStack(alignment: .firstTextBaseline) {
                    Text(digest.landmark?.label ?? "—")
                        .font(.dynamic(size: 13))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(verbatim: "\(digest.date) · \(Format.percent(digest.fill))")
                        .font(.dynamic(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Le transport

    private var transport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    life.isRunning ? life.pause() : life.resume()
                } label: {
                    Image(systemName: life.isRunning ? "pause.fill" : "play.fill")
                        .font(.dynamic(size: 20))
                        .foregroundStyle(Theme.background)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.read))
                }
                .accessibilityLabel(life.isRunning ? "life.scroll.pause" : "life.scroll.play")
                .disabled(life.isFinished)

                Button {
                    life.jumpToLandmark()
                } label: {
                    Label("life.nextLandmark", systemImage: "forward.end.fill")
                        .font(.dynamic(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06)))
                        .foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain)
                .disabled(life.isFinished)
            }

            Picker("life.speed", selection: $life.speed) {
                ForEach(DiskLifeModel.Speed.allCases, id: \.self) { speed in
                    Text(verbatim: speed.label).tag(speed)
                }
            }
            .pickerStyle(.segmented)

            Button {
                listen()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                    Text(verbatim: life.nextDay.map {
                        String(localized: "life.listenDay", defaultValue: "Listen to day \($0)")
                    } ?? String(localized: "life.over", defaultValue: "The disk's life is over"))
                        .font(.dynamic(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(life.nextDay == nil ? Color.white.opacity(0.06) : Theme.write))
                .foregroundStyle(life.nextDay == nil ? Theme.dim : Theme.background)
            }
            .buttonStyle(.plain)
            .disabled(life.nextDay == nil)

            if let failure = life.failure {
                Text(failure)
                    .font(.dynamic(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.read)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Theme.background)
    }

    private func listen() {
        life.pause()
        guard let day = life.nextDay else { return }
        do {
            try model.load(day: day, of: life.life, disk: life.disk)
            model.engine.play()
            dismiss()
            onListen()
        } catch {
            life.failure = "\(error)"
        }
    }
}

// MARK: - Le défilement, côté écran

/// Le défilement tel que l'écran le conduit : une horloge, une vitesse, et ce
/// qu'il faut pour redessiner sans tout recalculer.
@MainActor
final class DiskLifeModel: ObservableObject {

    enum Speed: Int, CaseIterable, Hashable {
        case day = 1
        case week = 7
        case month = 30

        var label: String {
            switch self {
            case .day:   return String(localized: "life.speed.day", defaultValue: "1 day/s")
            case .week:  return String(localized: "life.speed.week", defaultValue: "1 week/s")
            case .month: return String(localized: "life.speed.month", defaultValue: "1 month/s")
            }
        }
    }

    let disk: GeneratedDisk
    let life: DiskLife
    var grid: MapGrid { life.grid }

    @Published private(set) var shades: [ClusterShade] = []
    @Published private(set) var day: UInt32 = 0
    @Published private(set) var date = ""
    @Published private(set) var fill = 0.0
    @Published private(set) var fileCount = 0
    @Published private(set) var fragmentedFiles = 0
    @Published private(set) var bytesWritten = 0
    @Published private(set) var activities: [String] = []
    @Published private(set) var currentLandmark: String?
    @Published private(set) var landmarks: [DiskLife.DayDigest] = []
    @Published private(set) var isRunning = false
    @Published var failure: String?
    @Published var speed: Speed = .week

    private var timer: Timer?

    init(disk: GeneratedDisk) {
        self.disk = disk
        self.life = DiskLife(spec: disk.spec)
        // Le premier jour est celui de l'installation : on le passe pour que
        // l'écran s'ouvre sur un disque qui existe.
        absorb(life.advance().last)
    }

    var dayCount: UInt32 { life.dayCount }
    var isFinished: Bool { life.isFinished }
    var nextDay: UInt32? { life.nextDay }
    var progress: Double { dayCount > 0 ? Double(day) / Double(dayCount) : 0 }
    var fillCurve: [Double] { life.curves.fill }
    var fragmentedCurve: [Int] { life.curves.fragmented }

    func resume() {
        guard !isFinished else { return }
        isRunning = true
        timer?.invalidate()
        // Dix images par seconde : la carte n'a pas besoin de plus, et un
        // volume de 2007 demande quelques millisecondes par journée.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    /// Fait défiler jusqu'à la prochaine journée qui vaut d'être écoutée.
    func jumpToLandmark() {
        pause()
        if let digest = life.advanceToLandmark() {
            absorb(digest)
        } else {
            absorb(life.digests.last)
        }
    }

    private func tick() {
        guard !isFinished else { pause(); return }
        let produced = life.advance(days: max(speed.rawValue / 10, 1))
        absorb(produced.last(where: { $0.landmark != nil }) ?? produced.last)
    }

    private func absorb(_ digest: DiskLife.DayDigest?) {
        guard let digest else { return }
        day = digest.day
        date = digest.date
        fill = digest.fill
        fileCount = digest.fileCount
        fragmentedFiles = digest.fragmentedFiles
        bytesWritten = digest.bytesWritten
        activities = digest.activities.map(\.label)
        currentLandmark = digest.landmark?.label
        landmarks = life.landmarks
        shades = life.shades()
        if life.isFinished { pause() }
    }
}

// MARK: - Une courbe

/// Une courbe sans axes : ce qui compte est la forme, et le moment où elle
/// décolle.
private struct Curve: View {
    let values: [Double]
    let colour: Color
    let maximum: Double

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1, maximum > 0 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let y = proxy.size.height * (1 - CGFloat(min(value / maximum, 1)))
                    let point = CGPoint(x: CGFloat(index) * step, y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .accessibilityHidden(true)
    }
}
