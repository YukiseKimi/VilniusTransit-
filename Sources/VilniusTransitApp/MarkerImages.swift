import AppKit
import VilniusTransitKit

/// Pre-rendered marker art, cached by appearance.
///
/// With ~385 vehicles redrawing at 20 fps, rendering a marker per frame is the one
/// thing guaranteed to melt the app. Every distinct marker is drawn once with Core
/// Graphics and reused; the only per-frame work left is a layer transform.
@MainActor
final class MarkerImages {
    static let shared = MarkerImages()

    private let badges = NSCache<NSString, NSImage>()
    private let arrows = NSCache<NSString, NSImage>()

    private init() {
        badges.countLimit = 512
        arrows.countLimit = 64
    }

    // MARK: - Palette

    /// Fill identifies *what* the vehicle is.
    static func color(for mode: TransitMode) -> NSColor {
        switch mode {
        case .bus:        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
        case .trolleybus: NSColor(srgbRed: 0.12, green: 0.72, blue: 0.35, alpha: 1)
        case .ferry:      NSColor(srgbRed: 0.28, green: 0.78, blue: 0.90, alpha: 1)
        }
    }

    /// Outline identifies *how it is doing* — the payoff from `NuokrypisSekundemis`.
    static func color(for punctuality: Punctuality) -> NSColor {
        switch punctuality {
        case .early:    NSColor(srgbRed: 0.40, green: 0.78, blue: 1.00, alpha: 1)
        case .onTime:   NSColor(srgbRed: 0.20, green: 0.85, blue: 0.45, alpha: 1)
        case .late:     NSColor(srgbRed: 1.00, green: 0.72, blue: 0.15, alpha: 1)
        case .veryLate: NSColor(srgbRed: 1.00, green: 0.30, blue: 0.28, alpha: 1)
        case .unknown:  NSColor(white: 0.62, alpha: 1)
        }
    }

    // MARK: - Badge

    static let badgeSize = CGSize(width: 34, height: 22)

    func badge(route: String, mode: TransitMode, punctuality: Punctuality, selected: Bool) -> NSImage {
        let key = "\(route)|\(mode.rawValue)|\(punctuality)|\(selected)" as NSString
        if let cached = badges.object(forKey: key) { return cached }

        let size = Self.badgeSize
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let stroke = Self.color(for: punctuality)
            let fill = Self.color(for: mode)
            let lineWidth: CGFloat = selected ? 3 : 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
            let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)

            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()

            // Long route names ("N2", "3G") need to stay legible at 22 pt tall.
            let text = route.isEmpty ? "–" : route
            let fontSize: CGFloat = text.count >= 4 ? 9 : 11
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let textSize = attributed.size()
            attributed.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                        y: (size.height - textSize.height) / 2))
            return true
        }
        badges.setObject(image, forKey: key)
        return image
    }

    // MARK: - Direction arrow

    static let arrowSize = CGSize(width: 12, height: 12)

    /// Drawn pointing up (north). The annotation view rotates it by heading.
    func arrow(mode: TransitMode) -> NSImage {
        let key = mode.rawValue as NSString
        if let cached = arrows.object(forKey: key) { return cached }

        let size = Self.arrowSize
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.move(to: CGPoint(x: size.width / 2, y: size.height))
            ctx.addLine(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.28))
            ctx.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.closePath()
            ctx.setFillColor(Self.color(for: mode).cgColor)
            ctx.fillPath()
            ctx.move(to: CGPoint(x: size.width / 2, y: size.height))
            ctx.addLine(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.28))
            ctx.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.closePath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            return true
        }
        arrows.setObject(image, forKey: key)
        return image
    }
}
