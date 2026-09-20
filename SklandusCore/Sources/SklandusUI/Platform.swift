import SwiftUI
import CoreGraphics
import CoreText

/// The whole of this target's platform divergence, in one file.
///
/// Marker artwork is rendered straight to `CGImage` rather than through `NSImage`
/// or `UIImage`. That is not a portability workaround — `CALayer.contents` wants a
/// `CGImage` on both platforms anyway, so going through a platform image type was
/// always a detour. The system font comes from Core Text and the display scale
/// from SwiftUI's environment, so neither AppKit nor UIKit is imported here.
enum Platform {

    /// Bold system font. Core Text's emphasized UI font is the system bold face on
    /// both platforms, so no `NSFont`/`UIFont` is needed.
    static func boldSystemFont(ofSize size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
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
