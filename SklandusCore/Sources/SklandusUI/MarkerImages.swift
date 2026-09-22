import CoreGraphics
import Foundation
import SklandusKit

/// Pre-rendered marker art, cached by appearance.
///
/// With ~385 vehicles redrawing at 20 fps, rendering a marker per frame is the one
/// thing guaranteed to melt the app. Every distinct marker is drawn once and reused;
/// the only per-frame work left is a layer transform.
///
/// Output is `CGImage`, which is what `CALayer.contents` takes on both platforms.
@MainActor
final class MarkerImages {
    static let shared = MarkerImages()

    private var badges: [Int: CGImage] = [:]
    private var arrows: [Int: CGImage] = [:]
    private var dots: [Int: CGImage] = [:]
    private var scale: CGFloat = 2

    private init() {}

    /// Markers are raster art, so a scale change invalidates the whole cache.
    func setScale(_ newScale: CGFloat) {
        guard newScale != scale, newScale > 0 else { return }
        scale = newScale
        badges.removeAll(keepingCapacity: true)
        arrows.removeAll(keepingCapacity: true)
        dots.removeAll(keepingCapacity: true)
    }

    // MARK: - Palette

    /// The city publishes a colour per route in `routes.txt`, and it encodes
    /// service class rather than individual route: one blue for the 82 regular bus
    /// routes, red for trolleybuses, black for the nine night routes, green for the
    /// express "G" routes, teal for the ferry. Useless for telling routes apart,
    /// genuinely useful for telling service types apart.
    static func color(hex: String) -> RGBA? { RGBA(hex: hex) }

    /// Used until the timetable loads, and for the ~1% of in-service vehicles
    /// running layover movements that never appear in it.
    static func fallbackColor(for mode: TransitMode) -> RGBA {
        switch mode {
        case .bus:        RGBA(0.04, 0.52, 1.00)
        case .trolleybus: RGBA(0.12, 0.72, 0.35)
        case .ferry:      RGBA(0.28, 0.78, 0.90)
        }
    }

    static func color(for vehicle: Vehicle, routeColorHex: String?) -> RGBA {
        routeColorHex.flatMap(RGBA.init(hex:)) ?? fallbackColor(for: vehicle.mode)
    }

    /// Outline identifies *how it is doing* — the payoff from `NuokrypisSekundemis`.
    static func color(for punctuality: Punctuality) -> RGBA {
        switch punctuality {
        case .early:    RGBA(0.40, 0.78, 1.00)
        case .onTime:   RGBA(0.20, 0.85, 0.45)
        case .late:     RGBA(1.00, 0.72, 0.15)
        case .veryLate: RGBA(1.00, 0.30, 0.28)
        case .unknown:  RGBA(0.62, 0.62, 0.62)
        }
    }

    /// Black night-bus routes need light text; everything else takes dark.
    static func readableText(on fill: RGBA) -> RGBA {
        fill.luminance > 0.6 ? RGBA(0.1, 0.1, 0.1) : .white
    }

    // MARK: - Badge

    static let badgeSize = CGSize(width: 34, height: 22)

    func badge(route: String, fill: RGBA, punctuality: Punctuality, selected: Bool) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(route); hasher.combine(fill.key)
        hasher.combine(punctuality); hasher.combine(selected)
        let key = hasher.finalize()
        if let cached = badges[key] { return cached }

        let size = Self.badgeSize
        let image = Bitmap.image(size: size, scale: scale) { ctx in
            let stroke = Self.color(for: punctuality)
            let lineWidth: CGFloat = selected ? 3 : 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                transform: nil
            )

            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3,
                          color: RGBA.black.withAlpha(0.35).cgColor)
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
            Bitmap.drawCentredText(
                text, in: ctx, bounds: size,
                font: Platform.boldSystemFont(ofSize: text.count >= 4 ? 9 : 11),
                color: Self.readableText(on: fill)
            )
        }
        badges[key] = image
        return image
    }

    // MARK: - Direction arrow

    static let arrowSize = CGSize(width: 12, height: 12)

    /// Drawn pointing up (north). The annotation view rotates it by heading.
    func arrow(fill: RGBA) -> CGImage? {
        if let cached = arrows[fill.key] { return cached }
        let size = Self.arrowSize
        let image = Bitmap.image(size: size, scale: scale) { ctx in
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
            ctx.setStrokeColor(RGBA.white.withAlpha(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        arrows[fill.key] = image
        return image
    }

    // MARK: - Station dot

    static func stationDotSize(terminus: Bool) -> CGSize {
        let diameter: CGFloat = terminus ? 14 : 10
        return CGSize(width: diameter, height: diameter)
    }

    /// Termini draw hollow, so the ends of a route read at a glance.
    func stationDot(fill: RGBA, terminus: Bool) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(fill.key)
        hasher.combine(terminus)
        let key = hasher.finalize()
        if let cached = dots[key] { return cached }

        let size = Self.stationDotSize(terminus: terminus)
        let image = Bitmap.image(size: size, scale: scale) { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            ctx.setShadow(offset: .zero, blur: 2, color: RGBA.black.withAlpha(0.4).cgColor)
            ctx.setFillColor(RGBA.white.cgColor)
            ctx.fillEllipse(in: CGRect(origin: .zero, size: size))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(terminus ? RGBA.white.cgColor : fill.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(fill.cgColor)
            ctx.setLineWidth(terminus ? 3 : 1.5)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
        }
        dots[key] = image
        return image
    }
}
