import Foundation
import CoreGraphics
import DiskCore

/// Le plateau vu de dessus, tel que le dessine `PlatterView` dans l'application,
/// transcrit en Core Graphics.
///
/// Mêmes proportions, même bras, même traînée qui tourne avec le plateau. Les
/// épaisseurs, fixées en points dans l'application, sont ici rapportées au
/// rayon : la vidéo dessine le plateau bien plus grand qu'un téléphone.
///
/// `still` fait ce que « Réduire les animations » fait dans l'application : le
/// plateau ne tourne plus et les accès restent sous la tête. C'est ce que veut
/// une vidéo accélérée, où une image couvre des dizaines de tours et où la
/// rotation affichée ne serait qu'un repliement.
struct PlatterDrawing {

    let track: PlatterTrack
    let frame: PlatterFrame
    let still: Bool

    private var geometry: DriveGeometry { track.geometry }

    private static let dataBandOuter = 0.95
    private static let hubOuter = 0.38
    private static let spindleHole = 0.10
    private static let pivotDistance = 1.35
    private static let armLength = 0.95
    private static let pivotAngle = -0.95

    /// Dessine dans `rect`, un carré de préférence.
    func draw(on canvas: Canvas, in rect: CGRect) {
        let context = canvas.context
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY + side * 0.03)
        let radius = side * 0.40
        // L'application dessine un plateau d'environ cent cinquante points de
        // rayon : c'est l'échelle de toutes ses épaisseurs.
        let scale = radius / 150

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawPlatter(context, center, radius)
        drawZones(context, center, radius, scale)
        if frame.spin > 0.02 && !still {
            drawRotationMarks(context, center, radius)
        }
        drawTrail(context, center, radius, scale)
        drawHub(context, center, radius)
        drawActuator(context, center, radius, scale)
        drawHeadStack(context, center, radius, scale)
        context.restoreGState()
    }

    // MARK: - Repères géométriques

    private func screenRadius(cylinder: Double, radius: CGFloat) -> Double {
        Double(radius) * Self.dataBandOuter * geometry.normalizedRadius(cylinder: cylinder)
    }

    private func headAngle(atRadius r: Double, radius: CGFloat) -> Double {
        let d = Double(radius) * Self.pivotDistance
        let l = Double(radius) * Self.armLength
        guard r > 0 else { return Self.pivotAngle }
        let cosPhi = min(max((d * d + r * r - l * l) / (2 * d * r), -1), 1)
        return Self.pivotAngle + acos(cosPhi)
    }

    private func point(_ center: CGPoint, _ r: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle) * r), y: center.y + CGFloat(sin(angle) * r))
    }

    private func drift(since time: Double) -> Double {
        guard !still else { return 0 }
        return (frame.turns - track.turns(at: time)) * 2 * .pi
    }

    // MARK: - Éléments

    private func drawPlatter(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(gray: 0.20, alpha: 1),
                                           CGColor(gray: 0.28, alpha: 1),
                                           CGColor(gray: 0.15, alpha: 1)] as CFArray,
                                  locations: [0, 0.5, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.35,
                                   endCenter: center, endRadius: radius,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect)
    }

    private func drawZones(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat, _ scale: CGFloat) {
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.045))
        context.setLineWidth(max(scale, 1))
        for zone in geometry.zones.dropFirst() {
            let r = screenRadius(cylinder: Double(zone.firstCylinder), radius: radius)
            context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
    }

    private func drawRotationMarks(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat) {
        let angle = frame.turns * 2 * .pi
        context.saveGState()
        context.setLineCap(.butt)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.10 * frame.spin))
        context.setLineWidth(radius * 0.10)
        for k in 0..<3 {
            let a = angle + Double(k) * 2 * .pi / 3
            context.addArc(center: center, radius: radius * 0.80,
                           startAngle: a, endAngle: a + 0.22, clockwise: false)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawTrail(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat, _ scale: CGFloat) {
        guard !frame.trail.isEmpty else { return }
        let window = track.trailWindow

        for index in frame.trail {
            let sample = track.samples[index]
            let age = (frame.time - sample.time) / window
            let opacity = (1 - min(max(age, 0), 1)) * 0.85
            guard opacity > 0.02 else { continue }
            let color = Palette.withAlpha(sample.isWrite ? Palette.write : Palette.read, opacity)

            guard sample.endCylinder != sample.cylinder else {
                let r = screenRadius(cylinder: Double(sample.cylinder), radius: radius)
                let a = headAngle(atRadius: r, radius: radius) + drift(since: sample.time)
                let p = point(center, r, a)
                let dot = 1.8 * scale
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
                continue
            }

            let steps = min(abs(Int(sample.endCylinder - sample.cylinder)), 8)
            for step in 0...steps {
                let u = Double(step) / Double(steps)
                let cylinder = Double(sample.cylinder) + (Double(sample.endCylinder) - Double(sample.cylinder)) * u
                let r = screenRadius(cylinder: cylinder, radius: radius)
                let a = headAngle(atRadius: r, radius: radius) + drift(since: sample.time + Double(sample.duration) * u)
                let p = point(center, r, a)
                if step == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.setStrokeColor(color)
            context.setLineWidth(2.4 * scale)
            context.strokePath()
        }
    }

    private func drawHub(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat) {
        let hub = radius * Self.hubOuter
        let rect = CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: rect)

        let hole = radius * Self.spindleHole
        context.setFillColor(Palette.background)
        context.fillEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    }

    private func drawActuator(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat, _ scale: CGFloat) {
        let pivot = point(center, Double(radius) * Self.pivotDistance, Self.pivotAngle)
        let r = screenRadius(cylinder: frame.cylinder, radius: radius)
        let head = point(center, r, headAngle(atRadius: r, radius: radius))

        let low = screenRadius(cylinder: frame.sweep.lowerBound, radius: radius)
        let high = screenRadius(cylinder: frame.sweep.upperBound, radius: radius)
        if abs(high - low) > 2 * Double(scale) {
            context.move(to: point(center, low, headAngle(atRadius: low, radius: radius)))
            context.addLine(to: pivot)
            context.addLine(to: point(center, high, headAngle(atRadius: high, radius: radius)))
            context.setStrokeColor(Palette.withAlpha(Palette.arm, 0.18))
            context.setLineWidth(6 * scale)
            context.strokePath()
        }

        for (width, color) in [(6 * scale, Palette.withAlpha(Palette.arm, 0.85)),
                               (2 * scale, CGColor(gray: 1, alpha: 0.35))] {
            context.move(to: pivot)
            context.addLine(to: head)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokePath()
        }

        let coil = max(radius * 0.09, 6)
        let coilRect = CGRect(x: pivot.x - coil, y: pivot.y - coil, width: coil * 2, height: coil * 2)
        context.setFillColor(CGColor(gray: 0.30, alpha: 1))
        context.fillEllipse(in: coilRect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
        context.setLineWidth(scale)
        context.strokeEllipse(in: coilRect)

        let tip = max(radius * 0.033, 3)
        let tipRect = CGRect(x: head.x - tip, y: head.y - tip, width: tip * 2, height: tip * 2)
        context.setFillColor(tipColor)
        context.fillEllipse(in: tipRect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
        context.strokeEllipse(in: tipRect)
    }

    private var tipColor: CGColor {
        switch frame.activity {
        case .writing: return Palette.write
        case .reading: return Palette.read
        case .seeking: return Palette.arm
        case .idle, .parked: return Palette.withAlpha(Palette.arm, 0.45)
        }
    }

    private func drawHeadStack(_ context: CGContext, _ center: CGPoint, _ radius: CGFloat, _ scale: CGFloat) {
        let faces = geometry.heads
        guard faces > 1 else { return }

        let width = radius * 0.26
        let thickness = 2 * scale
        let faceGap = 3 * scale
        let platterGap = 5 * scale
        let x = center.x - radius * 1.32

        var y = center.y - radius * 0.55
        for face in 0..<faces {
            let rect = CGRect(x: x, y: y, width: width, height: thickness)
            context.setFillColor(CGColor(gray: 1, alpha: 0.18))
            context.fill(rect)
            if face < frame.faces.count, let light = frame.faces[face], light.intensity > 0.02 {
                context.setFillColor(Palette.withAlpha(light.isWrite ? Palette.write : Palette.read, light.intensity))
                context.fill(rect)
            }
            y += thickness + (face % 2 == 0 ? faceGap : platterGap)
        }
    }
}
