import SwiftUI

/// Vue de dessus du plateau.
///
/// L'angle de chaque accès affiché est le vrai angle du plateau à l'instant où
/// la tête a atteint le secteur — il tombe directement du temps de simulation
/// et de la durée d'un tour. Le rayon vient de la position du cylindre : le
/// cylindre 0 est au bord.
struct PlatterView: View {

    let geometry: DriveGeometry
    let cylinder: Int
    let recent: [HeadSample]
    let time: Double
    let spinning: Bool

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + side * 0.03)
            let radius = side * 0.40

            drawPlatter(context: context, center: center, radius: radius)
            drawZones(context: context, center: center, radius: radius)
            if spinning { drawRotationMarks(context: context, center: center, radius: radius) }
            drawTrail(context: context, center: center, radius: radius)
            drawHub(context: context, center: center, radius: radius)
            drawActuator(context: context, center: center, radius: radius)
        }
        .aspectRatio(1.05, contentMode: .fit)
    }

    // MARK: - Éléments

    private func drawPlatter(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [
                Color(white: 0.20),
                Color(white: 0.28),
                Color(white: 0.15),
            ]),
            center: center, startRadius: radius * 0.35, endRadius: radius))
        context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.16)), lineWidth: 1)
    }

    private func drawZones(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for zone in geometry.zones.dropFirst() {
            let r = radius * geometry.normalizedRadius(cylinder: zone.firstCylinder)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(Color.white.opacity(0.045)), lineWidth: 1)
        }
    }

    private func drawRotationMarks(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        // Rotation ralentie d'un facteur ~150 : à 120 tours/s le plateau serait
        // un aplat uniforme à l'écran.
        let angle = time * 0.85 * 2 * .pi
        for k in 0..<3 {
            let a = angle + Double(k) * 2 * .pi / 3
            var path = Path()
            path.addArc(center: center, radius: radius * 0.80,
                        startAngle: .radians(a), endAngle: .radians(a + 0.22), clockwise: false)
            context.stroke(path, with: .color(Color.white.opacity(0.10)), lineWidth: radius * 0.10)
        }
    }

    private func drawTrail(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard !recent.isEmpty else { return }
        let revolution = geometry.revolutionDuration
        for (index, sample) in recent.enumerated() {
            let age = Double(index) / Double(max(recent.count, 1))
            let opacity = (1 - age) * 0.85
            guard opacity > 0.02 else { continue }

            let r = radius * geometry.normalizedRadius(cylinder: sample.cylinder)
            let angle = (sample.time / revolution).truncatingRemainder(dividingBy: 1) * 2 * .pi
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r,
                                y: center.y + CGFloat(sin(angle)) * r)
            let dot = CGRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)
            context.fill(Path(ellipseIn: dot),
                         with: .color((sample.isWrite ? Theme.write : Theme.read).opacity(opacity)))
        }
    }

    private func drawHub(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let hubRadius = radius * 0.40
        let rect = CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                          width: hubRadius * 2, height: hubRadius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.13)))
        context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.10)), lineWidth: 1)

        let hole = radius * 0.10
        let holeRect = CGRect(x: center.x - hole, y: center.y - hole,
                              width: hole * 2, height: hole * 2)
        context.fill(Path(ellipseIn: holeRect), with: .color(Theme.background))
    }

    /// Bras pivotant : le pivot est hors du plateau, la position angulaire de
    /// la tête découle du rayon visé par simple loi des cosinus.
    private func drawActuator(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let pivotDistance = radius * 1.35
        let armLength = radius * 0.95
        let pivotAngle = -0.95

        let pivot = CGPoint(x: center.x + CGFloat(cos(pivotAngle)) * pivotDistance,
                            y: center.y + CGFloat(sin(pivotAngle)) * pivotDistance)

        let r = Double(radius) * geometry.normalizedRadius(cylinder: cylinder)
        let d = Double(pivotDistance)
        let l = Double(armLength)
        let cosPhi = min(max((d * d + r * r - l * l) / (2 * d * r), -1), 1)
        let headAngle = pivotAngle + acos(cosPhi)

        let head = CGPoint(x: center.x + CGFloat(cos(headAngle)) * CGFloat(r),
                           y: center.y + CGFloat(sin(headAngle)) * CGFloat(r))

        var arm = Path()
        arm.move(to: pivot)
        arm.addLine(to: head)
        context.stroke(arm, with: .color(Theme.arm.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
        context.stroke(arm, with: .color(Color.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        let coil = CGRect(x: pivot.x - 11, y: pivot.y - 11, width: 22, height: 22)
        context.fill(Path(ellipseIn: coil), with: .color(Color(white: 0.30)))
        context.stroke(Path(ellipseIn: coil), with: .color(Color.white.opacity(0.22)), lineWidth: 1)

        let tip = CGRect(x: head.x - 4, y: head.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: tip), with: .color(Theme.read))
        context.stroke(Path(ellipseIn: tip), with: .color(.white.opacity(0.5)), lineWidth: 1)
    }
}
