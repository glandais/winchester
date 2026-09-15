import SwiftUI

/// Bandeau chronologique : phases du scénario en haut, débit de requêtes en
/// dessous, tête de lecture déplaçable pour sauter dans la simulation.
struct ActivityTimeline: View {

    let spans: [PhaseSpan]
    let iops: [Double]
    let peak: Double
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void

    private let bandHeight: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            Canvas { context, size in
                drawPhases(context: context, size: size)
                drawActivity(context: context, size: size)
                drawPlayhead(context: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        onSeek(Double(fraction) * duration)
                    }
            )
            .frame(height: height)
        }
        .frame(height: 78)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max(time / max(duration, 1e-6), 0), 1)) * width
    }

    private func drawPhases(context: GraphicsContext, size: CGSize) {
        for span in spans {
            let start = x(span.start, size.width)
            let end = x(span.end, size.width)
            let rect = CGRect(x: start, y: 0, width: max(end - start - 1, 1), height: bandHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(Theme.phaseColor(span.index).opacity(0.78)))
        }
    }

    private func drawActivity(context: GraphicsContext, size: CGSize) {
        let top = bandHeight + 6
        let plotHeight = size.height - top
        guard plotHeight > 0, !iops.isEmpty else { return }

        let barWidth = size.width / CGFloat(iops.count)
        for (index, value) in iops.enumerated() {
            guard value > 0 else { continue }
            let normalized = CGFloat(min(value / peak, 1))
            let barHeight = max(normalized * plotHeight, 1)
            let rect = CGRect(x: CGFloat(index) * barWidth,
                              y: top + plotHeight - barHeight,
                              width: max(barWidth - 0.4, 0.6),
                              height: barHeight)
            let t = Double(index) * SimulationModel.bucketDuration
            let color = spans.last { $0.start <= t }.map { Theme.phaseColor($0.index) } ?? Theme.read
            context.fill(Path(rect), with: .color(color.opacity(0.75)))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        let px = x(currentTime, size.width)
        var line = Path()
        line.move(to: CGPoint(x: px, y: 0))
        line.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1.5)

        let knob = CGRect(x: px - 4, y: -1, width: 8, height: 8)
        context.fill(Path(ellipseIn: knob), with: .color(.white))
    }
}
