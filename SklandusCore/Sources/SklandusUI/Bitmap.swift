import SwiftUI
import CoreGraphics
import CoreText

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
            .foregroundColor: color.cgColor
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
