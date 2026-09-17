import SwiftUI
import DiskCore

/// Le mode ambiance — maquette 16 : une passe de plusieurs heures comme bruit de
/// fond.
///
/// Presque noir, un plateau réduit à son contour et à son bras, le temps écouté
/// et la minuterie d'arrêt. L'écran ne suit pas l'horloge du moteur : il se
/// redessine deux fois par seconde, ce qui suffit à un bras qui bouge et à un
/// chronomètre à la minute, et coûte peu sur une nuit entière.
///
/// Il ne retient pas l'écran allumé : l'iPhone se verrouille comme d'habitude
/// et la passe continue de sonner en arrière-plan.
struct AmbientScreen: View {

    @ObservedObject var model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Les durées proposées, en secondes ; `nil` désarme.
    private static let timers: [(label: String, seconds: Double?)] = {
        var timers: [(label: String, seconds: Double?)] = [
            ("Sans minuterie", nil),
            ("15 min", 15 * 60),
            ("30 min", 30 * 60),
            ("1 h", 3_600),
            ("2 h", 2 * 3_600),
            ("6 h", 6 * 3_600),
        ]
        #if DEBUG
        // Pour voir le fondu et l'arrêt sans attendre un quart d'heure.
        timers.append(("10 s (débogage)", 10))
        #endif
        return timers
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(now: context.date)
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
    }

    private func content(now: Date) -> some View {
        let engine = model.engine
        let time = engine.currentTime
        return VStack(spacing: 18) {
            Spacer()
            Text(subtitle.uppercased())
                .font(.dynamic(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            MinimalPlatter(geometry: model.geometry,
                           cylinder: model.platterFrame(at: time).cylinder,
                           active: model.activityLED,
                           turns: reduceMotion ? 0 : time / 20)
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            Text(FrenchFormat.duration(time))
                .font(.dynamic(size: 44, weight: .light, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.75))
                .monospacedDigit()
            Text(statusLine(now: now))
                .font(.dynamic(size: 12, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    if engine.isFinished { model.restart() }
                    engine.toggle()
                } label: {
                    Image(systemName: engine.isPlaying || engine.isBuffering ? "pause.fill" : "play.fill")
                        .font(.dynamic(size: 18))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .accessibilityLabel(engine.isPlaying || engine.isBuffering ? "Pause" : "Lecture")

                Menu {
                    ForEach(Self.timers.indices, id: \.self) { index in
                        Button(Self.timers[index].label) {
                            model.setSleepTimer(after: Self.timers[index].seconds)
                        }
                    }
                } label: {
                    Label(timerLabel(now: now), systemImage: "moon.zzz")
                        .font(.dynamic(size: 13))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }
            .foregroundStyle(Theme.text.opacity(0.7))

            Text("Touchez l'écran pour revenir à la passe.")
                .font(.dynamic(size: 11))
                .foregroundStyle(Theme.dim.opacity(0.7))
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if let strategy = model.defrag?.strategy { return "\(model.label.title) · \(strategy.label)" }
        if let install = model.install { return "\(model.label.title) · installation de \(install.osName)" }
        return model.label.title
    }

    /// « 61 % · minuterie dans 1 h 48 ». Pas de temps restant pour la passe :
    /// il n'existe pas.
    private func statusLine(now: Date) -> String {
        var parts: [String] = []
        let engine = model.engine
        if engine.isFinished {
            parts.append("passe terminée")
        } else if let progress = model.defragProgress {
            parts.append(FrenchFormat.percent(progress))
        }
        if !engine.isPlaying && !engine.isBuffering && !engine.isFinished { parts.append("en pause") }
        if let deadline = model.sleepDeadline {
            parts.append("minuterie dans \(FrenchFormat.duration(max(deadline.timeIntervalSince(now), 0)))")
        }
        return parts.joined(separator: " · ")
    }

    private func timerLabel(now: Date) -> String {
        guard let deadline = model.sleepDeadline else { return "Minuterie d'arrêt" }
        return "Arrêt dans \(FrenchFormat.duration(max(deadline.timeIntervalSince(now), 0)))"
    }
}

/// Un plateau réduit à l'essentiel : son contour, un repère qui tourne
/// lentement, et le bras sur le cylindre en cours.
private struct MinimalPlatter: View {
    let geometry: DriveGeometry
    let cylinder: Double
    let active: Bool
    let turns: Double

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.42
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: circle), with: .color(Color.white.opacity(0.14)), lineWidth: 1)
            let hub = radius * 0.36
            context.stroke(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)),
                           with: .color(Color.white.opacity(0.10)), lineWidth: 1)

            let angle = turns * 2 * .pi
            var mark = Path()
            mark.addArc(center: center, radius: radius * 0.8,
                        startAngle: .radians(angle), endAngle: .radians(angle + 0.3), clockwise: false)
            context.stroke(mark, with: .color(Color.white.opacity(0.10)), lineWidth: 3)

            // Le bras vient du coin haut droit ; son extrémité est au rayon du
            // cylindre, le 0 au bord.
            let r = Double(radius) * 0.95 * geometry.normalizedRadius(cylinder: cylinder)
            let pivot = CGPoint(x: center.x + radius * 1.05, y: center.y - radius * 1.05)
            let direction = atan2(Double(center.y - pivot.y), Double(center.x - pivot.x))
            let reach = hypot(Double(center.x - pivot.x), Double(center.y - pivot.y)) - r
            let tip = CGPoint(x: pivot.x + CGFloat(cos(direction) * reach), y: pivot.y + CGFloat(sin(direction) * reach))
            var arm = Path()
            arm.move(to: pivot)
            arm.addLine(to: tip)
            context.stroke(arm, with: .color(Theme.arm.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let dot = CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(active ? Theme.read.opacity(0.8) : Theme.arm.opacity(0.4)))
        }
    }
}
