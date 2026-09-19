import CoreGraphics
import MapKit
import QuartzCore
import VilniusTransitKit

extension MKAnnotationView {
    /// `NSView.layer` is optional and needs `wantsLayer`; `UIView.layer` never is.
    /// The only structural difference between the two platforms in this target.
    var hostLayer: CALayer {
        #if os(macOS)
        if layer == nil { wantsLayer = true }
        if let layer { return layer }
        // wantsLayer guarantees a backing layer; this only satisfies the type.
        let backing = CALayer()
        layer = backing
        return backing
        #else
        return layer
        #endif
    }
}
