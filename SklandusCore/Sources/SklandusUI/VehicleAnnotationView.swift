import CoreGraphics
import MapKit
import QuartzCore
import SklandusKit

/// Badge plus rotating direction arrow, composed from two cached images.
///
/// The arrow lives in its own sublayer so heading changes are a transform on that
/// layer alone — the route number stays upright and nothing is re-rasterised.
final class VehicleAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "VehicleAnnotationView"

    private let arrowLayer = CALayer()
    private let badgeLayer = CALayer()

    /// Everything that decides which images the marker draws. Compared as a value
    /// so the appearance path can early-out without building a string key.
    private struct Appearance: Equatable {
        let route: String
        let mode: TransitMode
        let colorHex: String?
        let punctuality: Punctuality
        let inService: Bool
        let selected: Bool
    }
    private var applied: Appearance?
    private var appliedHeading: Double = .nan

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        canShowCallout = true
        displayPriority = .required

        let host = hostLayer
        for sublayer in [arrowLayer, badgeLayer] {
            sublayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            host.addSublayer(sublayer)
        }
        badgeLayer.bounds = CGRect(origin: .zero, size: MarkerImages.badgeSize)
        badgeLayer.position = CGPoint(x: 22, y: 22)
        arrowLayer.bounds = CGRect(origin: .zero, size: MarkerImages.arrowSize)
        arrowLayer.position = CGPoint(x: 22, y: 22)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        applied = nil
        appliedHeading = .nan
    }

    /// Badge and arrow artwork. Only route, mode, punctuality, service state or
    /// selection can change this, all of which arrive with a poll — so this runs a
    /// few times a second at most, never per frame.
    func applyAppearance(_ annotation: VehicleAnnotation, selected: Bool) {
        let vehicle = annotation.vehicle
        let appearance = Appearance(
            route: vehicle.route,
            mode: vehicle.mode,
            colorHex: annotation.routeColorHex,
            punctuality: vehicle.punctuality,
            inService: vehicle.isInService,
            selected: selected
        )
        guard appearance != applied else { return }
        applied = appearance

        let fill = MarkerImages.color(for: vehicle, routeColorHex: appearance.colorHex)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeLayer.contents = MarkerImages.shared.badge(
            route: appearance.route, fill: fill,
            punctuality: appearance.punctuality, selected: appearance.selected
        )
        arrowLayer.contents = MarkerImages.shared.arrow(fill: fill)
        // Out of service: still on the map, visibly not carrying anyone.
        hostLayer.opacity = appearance.inService ? 1.0 : 0.45
        zPriority = appearance.selected ? .max : .defaultUnselected
        CATransaction.commit()
    }

    /// The per-frame path, called at 20 fps for every visible marker. It must stay
    /// free of allocation: no string keys, no image lookups, no reflection.
    func applyMotion(_ annotation: VehicleAnnotation) {
        let heading = annotation.heading
        let moving = annotation.vehicle.speed >= 1
        // Sub-degree turns are invisible; skipping them removes most frames' work
        // for a vehicle travelling in a straight line.
        if abs(heading - appliedHeading) < 0.5, arrowLayer.isHidden == !moving { return }
        appliedHeading = heading

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Park the arrow just outside the badge on the side the vehicle is heading,
        // so direction reads at a glance without a second marker.
        let radians = heading * .pi / 180
        let orbit: CGFloat = 19
        arrowLayer.position = CGPoint(
            x: 22 + orbit * CGFloat(sin(radians)),
            y: 22 + orbit * CGFloat(cos(radians))
        )
        // AppKit layers are not geometry-flipped, so a clockwise compass bearing is
        // a negative rotation here.
        arrowLayer.transform = CATransform3DMakeRotation(-radians, 0, 0, 1)
        arrowLayer.isHidden = !moving
        CATransaction.commit()
    }
}
