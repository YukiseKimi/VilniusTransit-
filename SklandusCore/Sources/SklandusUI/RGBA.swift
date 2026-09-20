import SwiftUI
import CoreGraphics
import CoreText

/// sRGB colour as plain components, so no platform colour type is needed.
struct RGBA: Equatable, Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Six hex digits, with or without a leading '#'. Nil for anything else, so a
    /// malformed `route_color` falls back rather than rendering black.
    init?(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            CGFloat((value & 0xFF0000) >> 16) / 255,
            CGFloat((value & 0x00FF00) >> 8) / 255,
            CGFloat(value & 0x0000FF) / 255
        )
    }

    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)

    func withAlpha(_ alpha: CGFloat) -> RGBA {
        RGBA(red, green, blue, alpha)
    }

    /// Perceived brightness, for choosing legible text over a fill. The black the
    /// city publishes for night routes needs white text; nothing else does.
    var luminance: CGFloat { 0.299 * red + 0.587 * green + 0.114 * blue }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Stable, allocation-light cache key.
    var key: Int {
        var hasher = Hasher()
        hasher.combine(red); hasher.combine(green); hasher.combine(blue); hasher.combine(alpha)
        return hasher.finalize()
    }

    var swiftUI: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }
}

// MARK: - Bitmap
