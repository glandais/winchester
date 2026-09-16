import SwiftUI
import DiskCore

/// Vue de dessus du plateau.
///
/// Le rayon vient du cylindre : le cylindre 0 est au bord, et le bras est
/// parqué au moyeu tant que rien n'a été lu.
///
/// L'angle, lui, est **ralenti d'un facteur cent** (voir
/// `PlatterTrack.rotationSlowdown`) : un plateau qui tourne cent vingt fois par
/// seconde n'a pas d'angle affichable sur un écran à soixante images. Une seule
/// horloge angulaire sert au dessin — les repères de rotation et les accès de la
/// traînée tournent ensemble, parce que les données sont gravées sur le plateau
/// et tournent avec lui. Un accès naît donc sous la tête, puis dérive ; une
/// lecture séquentielle, qui descend piste après piste, y dessine une spirale.
struct PlatterView: View {

    let track: PlatterTrack
    let frame: PlatterFrame

    private var geometry: DriveGeometry { track.geometry }

    // MARK: - Proportions

    /// Garde entre la dernière piste et le bord physique : aucun disque n'écrit
    /// jusqu'au bord du plateau.
    private static let dataBandOuter = 0.95
    private static let hubOuter = 0.38
    private static let spindleHole = 0.10

    /// Pivot hors du plateau, bras un peu plus court que le rayon : les
    /// proportions d'un 3,5 pouces, où la tête balaie une trentaine de degrés
    /// pour couvrir toute la bande de données.
    private static let pivotDistance = 1.35
    private static let armLength = 0.95
    private static let pivotAngle = -0.95

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + side * 0.03)
            let radius = side * 0.40

            drawPlatter(context: context, center: center, radius: radius)
            drawZones(context: context, center: center, radius: radius)
            if frame.spin > 0.02 {
                drawRotationMarks(context: context, center: center, radius: radius)
            }
            drawTrail(context: context, center: center, radius: radius)
            drawHub(context: context, center: center, radius: radius)
            drawActuator(context: context, center: center, radius: radius)
            drawHeadStack(context: context, center: center, radius: radius)
        }
        .aspectRatio(1.05, contentMode: .fit)
    }

    // MARK: - Repères géométriques

    /// Rayon à l'écran d'une position continue du bras.
    private func screenRadius(cylinder: Double, radius: CGFloat) -> Double {
        Double(radius) * Self.dataBandOuter * geometry.normalizedRadius(cylinder: cylinder)
    }

    /// Angle de la tête pour un rayon donné : le bras pivote, donc sa position
    /// angulaire découle du rayon visé par simple loi des cosinus.
    private func headAngle(atRadius r: Double, radius: CGFloat) -> Double {
        let d = Double(radius) * Self.pivotDistance
        let l = Double(radius) * Self.armLength
        guard r > 0 else { return Self.pivotAngle }
        let cosPhi = min(max((d * d + r * r - l * l) / (2 * d * r), -1), 1)
        return Self.pivotAngle + acos(cosPhi)
    }

    private func point(center: CGPoint, radius r: Double, angle: Double) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
    }

    /// Tours apparents accomplis entre un instant et l'image courante — ce dont
    /// le plateau a tourné depuis, et donc ce dont un accès a dérivé.
    private func drift(since time: Double) -> Double {
        (frame.turns - track.turns(at: time)) * 2 * .pi
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
            let r = screenRadius(cylinder: Double(zone.firstCylinder), radius: radius)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(Color.white.opacity(0.045)), lineWidth: 1)
        }
    }

    /// Trois repères à 120°, qui donnent la vitesse du plateau. Ils
    /// apparaissent et s'accélèrent pendant la montée en régime.
    private func drawRotationMarks(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let angle = frame.turns * 2 * .pi
        for k in 0..<3 {
            let a = angle + Double(k) * 2 * .pi / 3
            var path = Path()
            path.addArc(center: center, radius: radius * 0.80,
                        startAngle: .radians(a), endAngle: .radians(a + 0.22), clockwise: false)
            context.stroke(path, with: .color(Color.white.opacity(0.10 * frame.spin)),
                           lineWidth: radius * 0.10)
        }
    }

    private func drawTrail(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        guard !frame.trail.isEmpty else { return }
        let window = track.trailWindow

        for index in frame.trail {
            let sample = track.samples[index]
            let age = (frame.time - sample.time) / window
            let opacity = (1 - min(max(age, 0), 1)) * 0.85
            guard opacity > 0.02 else { continue }

            let color = (sample.isWrite ? Theme.write : Theme.read).opacity(opacity)

            guard sample.endCylinder != sample.cylinder else {
                let r = screenRadius(cylinder: Double(sample.cylinder), radius: radius)
                let a = headAngle(atRadius: r, radius: radius) + drift(since: sample.time)
                dot(context: context, at: point(center: center, radius: r, angle: a), color: color)
                continue
            }

            // Un transfert qui change de cylindre est une spirale : la tête
            // descend d'une piste tous les `heads × spt` secteurs pendant que
            // le plateau tourne sous elle.
            let steps = min(abs(Int(sample.endCylinder - sample.cylinder)), 8)
            var path = Path()
            for step in 0...steps {
                let u = Double(step) / Double(steps)
                let cylinder = Double(sample.cylinder)
                    + (Double(sample.endCylinder) - Double(sample.cylinder)) * u
                let r = screenRadius(cylinder: cylinder, radius: radius)
                let a = headAngle(atRadius: r, radius: radius)
                    + drift(since: sample.time + Double(sample.duration) * u)
                let p = point(center: center, radius: r, angle: a)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }
    }

    private func dot(context: GraphicsContext, at p: CGPoint, color: Color) {
        let rect = CGRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func drawHub(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let hubRadius = radius * Self.hubOuter
        let rect = CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                          width: hubRadius * 2, height: hubRadius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.13)))
        context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.10)), lineWidth: 1)

        let hole = radius * Self.spindleHole
        let holeRect = CGRect(x: center.x - hole, y: center.y - hole,
                              width: hole * 2, height: hole * 2)
        context.fill(Path(ellipseIn: holeRect), with: .color(Theme.background))
    }

    private func drawActuator(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let pivot = point(center: center, radius: Double(radius) * Self.pivotDistance,
                          angle: Self.pivotAngle)

        let r = screenRadius(cylinder: frame.cylinder, radius: radius)
        let head = point(center: center, radius: r,
                         angle: headAngle(atRadius: r, radius: radius))

        // Sur un train dense le bras traverse plusieurs cylindres par image :
        // un voile entre les deux bornes du balayage vaut mieux qu'un bras qui
        // grésille en montrant l'un des accès tiré au sort.
        let low = screenRadius(cylinder: frame.sweep.lowerBound, radius: radius)
        let high = screenRadius(cylinder: frame.sweep.upperBound, radius: radius)
        if abs(high - low) > 2 {
            var blur = Path()
            blur.move(to: point(center: center, radius: low,
                                angle: headAngle(atRadius: low, radius: radius)))
            blur.addLine(to: pivot)
            blur.addLine(to: point(center: center, radius: high,
                                   angle: headAngle(atRadius: high, radius: radius)))
            context.stroke(blur, with: .color(Theme.arm.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }

        var arm = Path()
        arm.move(to: pivot)
        arm.addLine(to: head)
        context.stroke(arm, with: .color(Theme.arm.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round))
        context.stroke(arm, with: .color(Color.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

        let coilRadius = max(radius * 0.09, 6)
        let coil = CGRect(x: pivot.x - coilRadius, y: pivot.y - coilRadius,
                          width: coilRadius * 2, height: coilRadius * 2)
        context.fill(Path(ellipseIn: coil), with: .color(Color(white: 0.30)))
        context.stroke(Path(ellipseIn: coil), with: .color(Color.white.opacity(0.22)), lineWidth: 1)

        let tipRadius = max(radius * 0.033, 3)
        let tip = CGRect(x: head.x - tipRadius, y: head.y - tipRadius,
                         width: tipRadius * 2, height: tipRadius * 2)
        context.fill(Path(ellipseIn: tip), with: .color(tipColor))
        context.stroke(Path(ellipseIn: tip), with: .color(.white.opacity(0.5)), lineWidth: 1)
    }

    private var tipColor: Color {
        switch frame.activity {
        case .writing: return Theme.write
        case .reading: return Theme.read
        case .seeking: return Theme.arm
        case .idle, .parked: return Theme.arm.opacity(0.45)
        }
    }

    /// Pile de plateaux vue par la tranche, avec la face en cours allumée.
    ///
    /// Les commutations de tête s'entendent — un tic bien plus discret qu'un
    /// seek, mais présent dans toute lecture séquentielle — et rien ne les
    /// montrait. Un nombre impair de faces se lit au passage : le dernier
    /// plateau n'a qu'une surface utilisée, ce qui a existé et qui est le cas
    /// du disque de démarrage.
    private func drawHeadStack(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let faces = geometry.heads
        guard faces > 1 else { return }

        let width = radius * 0.26
        let thickness: CGFloat = 2
        let faceGap: CGFloat = 3
        let platterGap: CGFloat = 5
        let x = center.x - radius * 1.32

        var y = center.y - radius * 0.55
        for face in 0..<faces {
            let rect = CGRect(x: x, y: y, width: width, height: thickness)
            context.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(Color.white.opacity(0.18)))
            if face < frame.faces.count, let light = frame.faces[face], light.intensity > 0.02 {
                let color = light.isWrite ? Theme.write : Theme.read
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(color.opacity(light.intensity)))
            }
            y += thickness + (face % 2 == 0 ? faceGap : platterGap)
        }
    }
}
