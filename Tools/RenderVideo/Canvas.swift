import Foundation
import AppKit
import CoreGraphics
import CoreText

/// Une image de la vidéo : un contexte RGBA dont l'origine est en haut à
/// gauche, comme dans les vues de l'application.
///
/// Les octets sont rangés R, G, B, A dans l'ordre de la mémoire — ce que
/// `ffmpeg` lit sous le nom `rgba` — et l'image est opaque : le fond est peint
/// à chaque image, l'alpha prémultiplié ne change donc rien aux couleurs.
final class Canvas {

    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // Le texte se dessine dans un repère retourné : sans cela, chaque
        // glyphe sortirait la tête en bas.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    /// Les octets de l'image courante.
    var bytes: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: context.data, count: width * height * 4)
    }

    // MARK: - Formes

    func fill(_ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(rect)
    }

    func fill(roundedRect rect: CGRect, radius: CGFloat, _ color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func stroke(roundedRect rect: CGRect, radius: CGFloat, _ color: CGColor, width: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    /// Une image agrandie sans interpolation, à l'endroit.
    func draw(pixelImage image: CGImage, in rect: CGRect) {
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - Texte

    enum Alignment { case left, center, right }

    /// Écrit une ligne dont le haut est à `origin.y`, tronquée à `maxWidth`.
    /// Rend la taille occupée.
    @discardableResult
    func text(_ string: String, at origin: CGPoint, font: NSFont, color: CGColor,
              alignment: Alignment = .left, maxWidth: CGFloat? = nil) -> CGSize {
        var line = Self.line(string, font: font, color: color)
        if let maxWidth, Self.width(of: line) > maxWidth {
            let ellipsis = Self.line("…", font: font, color: color)
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
        }
        let lineWidth = Self.width(of: line)
        let x: CGFloat
        switch alignment {
        case .left: x = origin.x
        case .center: x = origin.x - lineWidth / 2
        case .right: x = origin.x - lineWidth
        }
        context.textPosition = CGPoint(x: x, y: origin.y + font.ascender)
        CTLineDraw(line, context)
        return CGSize(width: lineWidth, height: Self.lineHeight(font))
    }

    /// Écrit un paragraphe coupé aux mots, sur au plus `maxLines` lignes.
    /// Rend la hauteur occupée.
    @discardableResult
    func paragraph(_ string: String, at origin: CGPoint, width: CGFloat, font: NSFont,
                   color: CGColor, maxLines: Int = 3) -> CGFloat {
        let lines = Self.wrap(string, width: width, font: font)
        var y = origin.y
        for (index, line) in lines.prefix(maxLines).enumerated() {
            let isLast = index == maxLines - 1 && lines.count > maxLines
            text(isLast ? line + " …" : line, at: CGPoint(x: origin.x, y: y), font: font,
                 color: color, maxWidth: width)
            y += Self.lineHeight(font)
        }
        return y - origin.y
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) * 1.08
    }

    static func width(_ string: String, font: NSFont) -> CGFloat {
        width(of: line(string, font: font, color: CGColor(gray: 1, alpha: 1)))
    }

    static func wrap(_ string: String, width: CGFloat, font: NSFont) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in string.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if Self.width(candidate, font: font) <= width || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func line(_ string: String, font: NSFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// Les couleurs de `Theme`, en `CGColor` : l'outil ne compile pas SwiftUI.
enum Palette {
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static let background = rgb(0.055, 0.058, 0.070)
    static let panel = rgb(0.098, 0.104, 0.125)
    static let stroke = CGColor(gray: 1, alpha: 0.08)
    static let text = CGColor(gray: 0.92, alpha: 1)
    static let dim = CGColor(gray: 0.52, alpha: 1)
    static let read = rgb(1.0, 0.70, 0.28)
    static let write = rgb(0.36, 0.82, 0.82)
    static let arm = rgb(0.78, 0.80, 0.86)

    static func category(_ category: ClusterCategory, contiguous: Bool = false) -> CGColor {
        let c = ClusterPalette.color(category, contiguous: contiguous)
        return rgb(c.red, c.green, c.blue)
    }

    static func withAlpha(_ color: CGColor, _ alpha: Double) -> CGColor {
        color.copy(alpha: color.alpha * alpha) ?? color
    }
}

/// Les nombres tels qu'on les écrit en français, comme `FrenchFormat` dans
/// l'application.
enum French {
    private static let thin = "\u{202F}"

    static func integer(_ value: Int) -> String {
        let digits = String(abs(value))
        var groups: [Substring] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -3, limitedBy: digits.startIndex) ?? digits.startIndex
            groups.insert(digits[start..<end], at: 0)
            end = start
        }
        return (value < 0 ? "−" : "") + groups.joined(separator: thin)
    }

    static func decimal(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))\(thin)%"
    }

    /// Une durée de passe : « 3:25 », ou « 1:02:07 » au-delà de l'heure.
    static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3_600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
