import SwiftUI
import CoreGraphics
import CoreText

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The whole of this target's platform divergence, in one file.
///
/// Marker artwork is rendered straight to `CGImage` rather than through `NSImage`
/// or `UIImage`. That is not a portability workaround — `CALayer.contents` wants a
/// `CGImage` on both platforms anyway, so going through a platform image type was
/// always a detour. Doing it this way removes AppKit from the drawing layer
/// entirely; what is left is a bold system font, which has no Core Graphics
/// equivalent worth hand-rolling.
enum Platform {

    /// Bold system font as a `CTFont`. `NSFont`/`UIFont` are toll-free bridged, so
    /// this is the only place either framework is needed.
    static func boldSystemFont(ofSize size: CGFloat) -> CTFont {
        #if canImport(AppKit)
        return NSFont.systemFont(ofSize: size, weight: .bold) as CTFont
        #else
        return UIFont.systemFont(ofSize: size, weight: .bold) as CTFont
        #endif
    }

    /// Backing scale for crisp markers. Read once at view construction; both
    /// platforms report 2 or 3 on every display this app will meet.
    @MainActor
    static var displayScale: CGFloat {
        #if canImport(AppKit)
        return NSScreen.main?.backingScaleFactor ?? 2
        #else
        return UIScreen.main.scale
        #endif
    }

    /// How the user actually selects something, for use in copy.
    static var selectVerb: String {
        #if os(macOS)
        return "Click"
        #else
        return "Tap"
        #endif
    }

    /// Hit-target padding around a marker.
    ///
    /// A 10 pt station dot is fine for a cursor and far too small for a fingertip,
    /// so touch platforms get a view large enough to hit without enlarging the art.
    static var minimumHitSize: CGFloat {
        #if os(macOS)
        return 24
        #else
        return 44
        #endif
    }
}

// MARK: - Colour

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
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red, green, blue, alpha]
        )!
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

enum Bitmap {
    /// Draws into an sRGB bitmap at `scale` and returns the image.
    ///
    /// The context is set up in points, so callers draw in points and get a
    /// correctly sized pixel buffer for free.
    static func image(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setAllowsAntialiasing(true)
        draw(context)
        return context.makeImage()
    }

    /// Centres one line of text. Core Text rather than `NSAttributedString.draw`,
    /// which is AppKit-only.
    static func drawCentredText(
        _ text: String,
        in context: CGContext,
        bounds: CGSize,
        font: CTFont,
        color: RGBA
    ) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (bounds.width - textBounds.width) / 2 - textBounds.origin.x,
            y: (bounds.height - textBounds.height) / 2 - textBounds.origin.y
        )
        CTLineDraw(line, context)
    }
}
