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

    /// The city publishes a colour per route in `routes.txt`, and it encodes
    /// service class rather than individual route: one blue for the 82 regular bus
    /// routes, red for trolleybuses, black for the nine night routes, green for the
    /// express "G" routes, teal for the ferry. Using it means the map matches the
    /// printed timetables and picks up distinctions our own palette had no way to
    /// know about.
    static func color(hex: String) -> NSColor? {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value & 0xFF0000) >> 16) / 255,
            green: CGFloat((value & 0x00FF00) >> 8) / 255,
            blue: CGFloat(value & 0x0000FF) / 255,
            alpha: 1
        )
    }

    /// Used until the GTFS catalog has loaded, and for the ~1% of in-service
    /// vehicles running layover movements that never appear in the timetable.
    static func fallbackColor(for mode: TransitMode) -> NSColor {
        switch mode {
        case .bus:        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
        case .trolleybus: NSColor(srgbRed: 0.12, green: 0.72, blue: 0.35, alpha: 1)
        case .ferry:      NSColor(srgbRed: 0.28, green: 0.78, blue: 0.90, alpha: 1)
        }
    }

    static func color(for vehicle: Vehicle, routeColorHex: String?) -> NSColor {
        routeColorHex.flatMap(color(hex:)) ?? fallbackColor(for: vehicle.mode)
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

    /// Black night-bus routes need a light outline to stay visible on a dark map.
    private static func readableTextColor(on fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    // MARK: - Badge

    static let badgeSize = CGSize(width: 34, height: 22)

    func badge(route: String, fill: NSColor, punctuality: Punctuality, selected: Bool) -> NSImage {
        let key = "\(route)|\(fill.hexKey)|\(punctuality)|\(selected)" as NSString
        if let cached = badges.object(forKey: key) { return cached }

        let size = Self.badgeSize
        let textColor = Self.readableTextColor(on: fill)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let stroke = Self.color(for: punctuality)
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

            // Long route names ("N2", "3G-A") need to stay legible at 22 pt tall.
            let text = route.isEmpty ? "–" : route
            let fontSize: CGFloat = text.count >= 4 ? 9 : 11
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: textColor,
            ])
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
    func arrow(fill: NSColor) -> NSImage {
        let key = fill.hexKey as NSString
        if let cached = arrows.object(forKey: key) { return cached }

        let size = Self.arrowSize
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            func trace() {
                ctx.move(to: CGPoint(x: size.width / 2, y: size.height))
                ctx.addLine(to: CGPoint(x: 0, y: 0))
                ctx.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.28))
                ctx.addLine(to: CGPoint(x: size.width, y: 0))
                ctx.closePath()
            }
            trace()
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            trace()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            return true
        }
        arrows.setObject(image, forKey: key)
        return image
    }
}

private extension NSColor {
    /// Stable cache key. Colours here come from a small fixed palette, so this is
    /// cheap and collision-free in practice.
    var hexKey: String {
        guard let rgb = usingColorSpace(.sRGB) else { return description }
        return String(format: "%02X%02X%02X",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
