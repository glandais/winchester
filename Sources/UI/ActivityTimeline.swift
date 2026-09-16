import SwiftUI

/// Bandeau d'activité : la dernière minute de la passe, phases en haut, débit
/// de requêtes en dessous, l'instant présent au bord droit.
///
/// Il montrait toute la passe, avec une tête de lecture qu'on pouvait traîner.
/// Une passe qui se calcule à mesure qu'on l'écoute n'a ni durée connue ni
/// passé gardé : le bandeau défile, comme l'aiguille d'un enregistreur.
struct ActivityTimeline: View {

    let marks: [PhaseMark]
    let buckets: [ActivityBucket]
    let now: Double
    let window: Double

    private let bandHeight: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let start = now - window
            drawPhases(context: context, size: size, start: start)
            drawActivity(context: context, size: size, start: start)
        }
        .frame(height: 78)
    }

    private func x(_ time: Double, start: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(min(max((time - start) / window, 0), 1)) * width
    }

    private func drawPhases(context: GraphicsContext, size: CGSize, start: Double) {
        let visible = marks.filter { $0.time <= now }
        for (position, mark) in visible.enumerated() {
            let from = x(mark.time, start: start, size.width)
            let until = position + 1 < visible.count ? visible[position + 1].time : now
            let to = x(until, start: start, size.width)
            guard to > from else { continue }
            let rect = CGRect(x: from, y: 0, width: max(to - from - 1, 1), height: bandHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 2),
                         with: .color(Theme.phaseColor(mark.index).opacity(0.78)))
        }
    }

    private func drawActivity(context: GraphicsContext, size: CGSize, start: Double) {
        let top = bandHeight + 6
        let plotHeight = size.height - top
        guard plotHeight > 0 else { return }

        let visible = buckets.filter { $0.start >= start && $0.start <= now }
        // L'échelle est la crête de la fenêtre : sur une passe de cinq heures,
        // la crête globale n'est de toute façon pas connue.
        let peak = max(visible.map(\.requests).max() ?? 1, 1)
        let barWidth = size.width * CGFloat(ActivityBucket.duration / window)

        for bucket in visible where bucket.requests > 0 {
            let normalized = CGFloat(bucket.requests) / CGFloat(peak)
            let barHeight = max(normalized * plotHeight, 1)
            let rect = CGRect(x: x(bucket.start, start: start, size.width),
                              y: top + plotHeight - barHeight,
                              width: max(barWidth - 0.4, 0.6),
                              height: barHeight)
            let phase = marks.last { $0.time <= bucket.start }?.index
            let color = phase.map { Theme.phaseColor($0) } ?? Theme.read
            context.fill(Path(rect), with: .color(color.opacity(0.75)))
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
    }
}
