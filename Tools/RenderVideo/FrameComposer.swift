import Foundation
import AppKit
import CoreGraphics
import DiskCore

/// Le format de la vidéo.
enum VideoLayout: String {
    /// 1920 × 1080, pour une vidéo YouTube classique.
    case landscape
    /// 1080 × 1920, pour un Short.
    case short

    var size: (width: Int, height: Int) {
        switch self {
        case .landscape: return (1920, 1080)
        case .short: return (1080, 1920)
        }
    }
}

/// Compose chaque image de la vidéo à partir de la passe à l'instant voulu.
///
/// Tout ce qui est montré sort de `LivePass`, exactement comme dans
/// l'application : la carte rejouée, le plateau, la phase, l'avancement. Rien
/// n'est recalculé ici — la vidéo est une autre façon de regarder la même
/// passe, pas une autre simulation.
final class FrameComposer {

    let layout: VideoLayout
    let canvas: Canvas
    let scenario: Scenario
    let speed: Double
    let fps: Double

    private let frames: Frames
    /// Grille de la carte, choisie pour la surface qui lui est offerte.
    let mapGrid: MapGrid?
    /// Côté d'un bloc, en pixels entiers : un bloc est un carré net.
    private let cellSide: Int
    private let legend: [ClusterCategory]

    private var mapImage: CGImage?
    private var mapRevision = -1

    private struct Frames {
        let header: CGRect
        let map: CGRect
        let legend: CGRect
        let platter: CGRect
        let info: CGRect
        let activity: CGRect
        let progress: CGRect
    }

    init(layout: VideoLayout, scenario: Scenario, speed: Double, fps: Double) {
        self.layout = layout
        self.scenario = scenario
        self.speed = speed
        self.fps = fps
        let size = layout.size
        canvas = Canvas(width: size.width, height: size.height)

        let hasMap = scenario.map != nil
        frames = Self.frames(layout: layout, hasMap: hasMap)

        if hasMap {
            let side = layout == .landscape ? 8.0 : 7.0
            let grid = MapGrid.fitting(width: Double(frames.map.width), height: Double(frames.map.height),
                                       side: side)
            mapGrid = grid
            cellSide = max(min(Int(frames.map.width) / grid.columns, Int(frames.map.height) / grid.rows), 1)
        } else {
            mapGrid = nil
            cellSide = 1
        }

        // Une installation part d'un volume vierge : sa légende ne se lit pas
        // dans l'état de départ, mais dans ce que la passe va poser.
        var present = Set<UInt8>()
        for run in scenario.map?.initialRuns ?? [] { present.insert(run.category) }
        legend = present.count > 1
            ? ClusterCategory.allCases.filter { $0 == .free || present.contains($0.rawValue) }
            : ClusterCategory.allCases
    }

    // MARK: - Mise en page

    private static func frames(layout: VideoLayout, hasMap: Bool) -> Frames {
        switch (layout, hasMap) {
        case (.landscape, true):
            return Frames(header: CGRect(x: 64, y: 44, width: 1792, height: 130),
                          map: CGRect(x: 64, y: 200, width: 1232, height: 700),
                          legend: CGRect(x: 64, y: 918, width: 1232, height: 40),
                          platter: CGRect(x: 1360, y: 190, width: 496, height: 420),
                          info: CGRect(x: 1360, y: 630, width: 496, height: 330),
                          activity: .null,
                          progress: CGRect(x: 64, y: 994, width: 1792, height: 40))
        case (.landscape, false):
            return Frames(header: CGRect(x: 64, y: 44, width: 1792, height: 130),
                          map: .null, legend: .null,
                          platter: CGRect(x: 64, y: 200, width: 960, height: 820),
                          info: CGRect(x: 1080, y: 230, width: 776, height: 330),
                          activity: CGRect(x: 1080, y: 600, width: 776, height: 400),
                          progress: .null)
        case (.short, true):
            return Frames(header: CGRect(x: 48, y: 90, width: 984, height: 250),
                          map: CGRect(x: 48, y: 360, width: 984, height: 840),
                          legend: CGRect(x: 48, y: 1214, width: 984, height: 90),
                          platter: CGRect(x: 30, y: 1330, width: 520, height: 440),
                          info: CGRect(x: 580, y: 1350, width: 452, height: 420),
                          activity: .null,
                          progress: CGRect(x: 48, y: 1800, width: 984, height: 40))
        case (.short, false):
            return Frames(header: CGRect(x: 48, y: 90, width: 984, height: 250),
                          map: .null, legend: .null,
                          platter: CGRect(x: 60, y: 360, width: 960, height: 820),
                          info: CGRect(x: 48, y: 1220, width: 984, height: 380),
                          activity: CGRect(x: 48, y: 1620, width: 984, height: 220),
                          progress: .null)
        }
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Une image de la passe

    func draw(_ live: LivePass, at time: Double) {
        canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height), Palette.background)
        drawHeader(time: time)
        if mapGrid != nil { drawMap(live) }
        drawPlatter(live, at: time)
        drawInfo(live, at: time)
        if !frames.activity.isNull { drawActivity(live, at: time) }
        if !frames.progress.isNull { drawProgress(live) }
    }

    private func drawHeader(time: Double) {
        let rect = frames.header
        let label = scenario.label
        switch layout {
        case .landscape:
            let clockWidth: CGFloat = 300
            canvas.text(label.title, at: rect.origin, font: font(54, .semibold), color: Palette.text,
                        maxWidth: rect.width - clockWidth)
            canvas.paragraph(label.summary, at: CGPoint(x: rect.minX, y: rect.minY + 76),
                             width: rect.width - clockWidth, font: font(26), color: Palette.dim, maxLines: 2)
            canvas.text(French.clock(time), at: CGPoint(x: rect.maxX, y: rect.minY),
                        font: mono(54, .medium), color: Palette.text, alignment: .right)
            if speed > 1 {
                canvas.text("accéléré ×\(Self.speedLabel(speed))", at: CGPoint(x: rect.maxX, y: rect.minY + 76),
                            font: mono(26, .semibold), color: Palette.read, alignment: .right)
            }
        case .short:
            canvas.text(label.title, at: rect.origin, font: font(64, .semibold), color: Palette.text,
                        maxWidth: rect.width)
            canvas.paragraph(label.summary, at: CGPoint(x: rect.minX, y: rect.minY + 88),
                             width: rect.width, font: font(32), color: Palette.dim, maxLines: 2)
            let y = rect.minY + 190
            canvas.text(French.clock(time), at: CGPoint(x: rect.minX, y: y), font: mono(48, .medium),
                        color: Palette.text)
            if speed > 1 {
                canvas.text("accéléré ×\(Self.speedLabel(speed))", at: CGPoint(x: rect.maxX, y: y + 8),
                            font: mono(34, .semibold), color: Palette.read, alignment: .right)
            }
        }
    }

    static func speedLabel(_ speed: Double) -> String {
        speed >= 10 ? French.integer(Int(speed.rounded())) : French.decimal(speed)
    }

    private func drawMap(_ live: LivePass) {
        guard let player = live.map, let grid = mapGrid else { return }
        let shades = player.shades(at: live.now)
        if player.revision != mapRevision || mapImage == nil {
            mapImage = Self.mapImage(grid: grid, shades: shades)
            mapRevision = player.revision
        }
        let width = CGFloat(grid.columns * cellSide)
        let height = CGFloat(grid.rows * cellSide)
        let origin = CGPoint(x: frames.map.minX + floor((frames.map.width - width) / 2),
                             y: frames.map.minY + floor((frames.map.height - height) / 2))
        if let mapImage {
            canvas.draw(pixelImage: mapImage, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        }

        // La rémanence des accès, par-dessus : c'est elle qui fait voir où
        // travaille la tête sur une carte de quinze mille blocs.
        let side = CGFloat(cellSide)
        for point in live.mapTrail() where point.cell < grid.cellCount {
            let rect = CGRect(x: origin.x + CGFloat(point.cell % grid.columns) * side,
                              y: origin.y + CGFloat(point.cell / grid.columns) * side,
                              width: side, height: side)
            canvas.fill(rect, Palette.withAlpha(point.isWrite ? Palette.write : Palette.read, point.intensity))
        }

        drawLegend(clustersPerCell: player.clustersPerCell)
    }

    private func drawLegend(clustersPerCell: Double) {
        let rect = frames.legend
        let size: CGFloat = layout == .landscape ? 22 : 26
        let swatch = size * 0.8
        let lineHeight = Canvas.lineHeight(font(size))
        var x = rect.minX
        var y = rect.minY
        for category in legend {
            let width = swatch + 10 + Canvas.width(category.label, font: font(size)) + 28
            if x + width > rect.maxX && x > rect.minX {
                x = rect.minX
                y += lineHeight + 6
            }
            canvas.fill(roundedRect: CGRect(x: x, y: y + (lineHeight - swatch) / 2 - 2, width: swatch, height: swatch),
                        radius: 3, Palette.category(category))
            canvas.text(category.label, at: CGPoint(x: x + swatch + 10, y: y), font: font(size), color: Palette.dim)
            x += width
        }
    }

    /// Un pixel par bloc, comme `ClusterMapImage` dans l'application.
    private static func mapImage(grid: MapGrid, shades: [ClusterShade]) -> CGImage? {
        guard !shades.isEmpty else { return nil }
        var pixels = ClusterPalette.pixelBuffer(shades)
        if pixels.count > grid.cellCount {
            pixels.removeLast(pixels.count - grid.cellCount)
        } else if pixels.count < grid.cellCount {
            pixels.append(contentsOf: repeatElement(ClusterPalette.color(.free).pixel,
                                                    count: grid.cellCount - pixels.count))
        }
        for index in pixels.indices { pixels[index] = pixels[index].bigEndian }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: grid.columns, height: grid.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: grid.columns * 4, space: space, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func drawPlatter(_ live: LivePass, at time: Double) {
        let track = live.platter
        let frame = track.frame(at: time, frameDuration: speed / fps)
        let rect = frames.platter
        // Le dessin déborde un peu de son carré à gauche (la pile de têtes) et
        // en haut (le pivot du bras) : on lui laisse cette marge.
        let side = min(rect.width / 1.12, rect.height / 1.02)
        let square = CGRect(x: rect.midX - side / 2 + side * 0.06,
                            y: rect.minY + (rect.height - side) / 2 + side * 0.02,
                            width: side, height: side)
        PlatterDrawing(track: track, frame: frame, still: speed > 1).draw(on: canvas, in: square)
    }

    /// Le débit, moyenné sur ce que l'image couvre réellement.
    ///
    /// La tranche de cent millisecondes sous l'instant de l'image convient à
    /// soixante images par seconde en temps réel ; à ×17 une image couvre plus
    /// d'une demi-seconde de passe, et lire une tranche sur six affiche
    /// « 0,0 Mo/s » pendant qu'une écriture est en cours. On moyenne donc sur
    /// l'intervalle de l'image, jamais moins d'une seconde — au-dessous, le
    /// chiffre danserait plus vite qu'on ne le lit.
    private func throughputMBs(_ live: LivePass, at time: Double) -> Double {
        let window = max(speed / fps, 1)
        let start = time - window
        var bytes = 0
        for bucket in live.buckets where bucket.start > start && bucket.start <= time {
            bytes += bucket.bytes
        }
        return Double(bytes) / window / 1_000_000
    }

    private func drawInfo(_ live: LivePass, at time: Double) {
        let rect = frames.info
        let large = layout == .short && mapGrid == nil
        var y = rect.minY

        if let phase = live.phase {
            let size: CGFloat = large ? 44 : 34
            y += canvas.paragraph(phase.label, at: CGPoint(x: rect.minX, y: y), width: rect.width,
                                  font: font(size, .semibold), color: Palette.text, maxLines: 2) + 4
            let detailSize: CGFloat = large ? 28 : 24
            y += canvas.paragraph(phase.detail, at: CGPoint(x: rect.minX, y: y), width: rect.width,
                                  font: font(detailSize), color: Palette.dim, maxLines: large ? 2 : 3)
            y += 22
        }

        var rows: [(String, String)] = []
        if let moves = live.moves {
            rows.append(("Fichiers déplacés", French.integer(moves.filesMoved)))
            rows.append(("Évacuations", French.integer(moves.evacuations)))
        }
        rows.append(("Débit", "\(French.decimal(throughputMBs(live, at: time))) Mo/s"))
        if scenario.map == nil || layout == .landscape {
            rows.append(("Seeks", French.integer(live.totals.seeks)))
            rows.append(("Course moyenne", "\(French.integer(live.totals.averageSeekDistance)) cyl."))
        }

        let size: CGFloat = large ? 30 : 26
        let lineHeight = Canvas.lineHeight(mono(size)) + 4
        for (name, value) in rows where y + lineHeight <= rect.maxY {
            canvas.text(name, at: CGPoint(x: rect.minX, y: y), font: font(size), color: Palette.dim)
            canvas.text(value, at: CGPoint(x: rect.maxX, y: y), font: mono(size, .medium),
                        color: Palette.text, alignment: .right)
            y += lineHeight
        }
    }

    /// Le débit de la dernière minute, tranche par tranche, comme le bandeau
    /// d'activité de l'application.
    private func drawActivity(_ live: LivePass, at time: Double) {
        let rect = frames.activity
        let title = "Activité, dernière minute"
        let titleFont = font(layout == .short ? 28 : 24)
        canvas.text(title, at: rect.origin, font: titleFont, color: Palette.dim)
        let top = rect.minY + Canvas.lineHeight(titleFont) + 10
        let plot = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.maxY - top)
        canvas.fill(roundedRect: plot, radius: 12, Palette.panel)

        let window = LivePass.activityWindow
        let count = Int(window / ActivityBucket.duration)
        let current = ActivityBucket.index(at: time)
        let barWidth = plot.width / CGFloat(count)
        let peak = max(live.buckets.map(\.bytes).max() ?? 0, 1)
        let inner = plot.insetBy(dx: 0, dy: 12)
        for bucket in live.buckets where bucket.index <= current && bucket.index > current - count {
            let x = plot.maxX - CGFloat(current - bucket.index + 1) * barWidth
            let height = max(inner.height * CGFloat(bucket.bytes) / CGFloat(peak), bucket.requests > 0 ? 2 : 0)
            let isWrite = bucket.detail.writeBytes > bucket.detail.readBytes
            canvas.fill(CGRect(x: x, y: inner.maxY - height, width: max(barWidth - 1, 1), height: height),
                        isWrite ? Palette.write : Palette.read)
        }
    }

    private func drawProgress(_ live: LivePass) {
        let rect = frames.progress
        let value = live.progress ?? 0
        let textFont = mono(layout == .short ? 32 : 28, .medium)
        let label = French.percent(value)
        let labelWidth: CGFloat = 110
        let bar = CGRect(x: rect.minX, y: rect.midY - 6, width: rect.width - labelWidth, height: 12)
        canvas.fill(roundedRect: bar, radius: 6, CGColor(gray: 1, alpha: 0.08))
        canvas.fill(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(bar.width * value, 12), height: bar.height),
                    radius: 6, Palette.read)
        canvas.text(label, at: CGPoint(x: rect.maxX, y: rect.midY - Canvas.lineHeight(textFont) / 2),
                    font: textFont, color: Palette.dim, alignment: .right)
    }

    // MARK: - Bilan

    /// Le bilan par-dessus la dernière image de la passe, qui s'assombrit.
    ///
    /// - Parameter fade: 0 à 1, l'apparition du bilan.
    func drawSummary(over background: UnsafeRawBufferPointer, title: String, lines: [String], fade: Double) {
        if let data = canvas.context.data {
            data.copyMemory(from: background.baseAddress!, byteCount: background.count)
        }
        let t = min(max(fade, 0), 1)
        canvas.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height),
                    CGColor(gray: 0, alpha: 0.72 * t))
        guard t > 0 else { return }

        let margin: CGFloat = layout == .landscape ? 160 : 48
        let width = CGFloat(canvas.width) - margin * 2
        // Le bilan est aligné en colonnes : il se lit en chasse fixe, et la
        // taille se règle sur la plus longue ligne.
        var size: CGFloat = layout == .landscape ? 34 : 30
        let longest = lines.max { $0.count < $1.count } ?? ""
        while size > 14 && Canvas.width(longest, font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)) > width - 80 {
            size -= 1
        }
        let body = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let heading = font(layout == .landscape ? 56 : 60, .semibold)
        let lineHeight = Canvas.lineHeight(body)
        let height = Canvas.lineHeight(heading) + 30 + lineHeight * CGFloat(lines.count) + 80
        let panel = CGRect(x: margin, y: (CGFloat(canvas.height) - height) / 2, width: width, height: height)

        canvas.context.setAlpha(t)
        canvas.fill(roundedRect: panel, radius: 24, Palette.panel)
        canvas.stroke(roundedRect: panel, radius: 24, Palette.stroke, width: 2)
        var y = panel.minY + 40
        canvas.text(title, at: CGPoint(x: panel.minX + 40, y: y), font: heading, color: Palette.text,
                    maxWidth: panel.width - 80)
        y += Canvas.lineHeight(heading) + 30
        for line in lines {
            canvas.text(line, at: CGPoint(x: panel.minX + 40, y: y), font: body, color: Palette.text,
                        maxWidth: panel.width - 80)
            y += lineHeight
        }
        canvas.context.setAlpha(1)
    }
}
