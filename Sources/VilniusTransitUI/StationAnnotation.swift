import CoreGraphics
import MapKit
import QuartzCore
import VilniusTransitKit

/// A station on the selected vehicle's route.
///
/// Stops are shown only for the selection. Drawing all of them was measured at 990
/// stations inside the default viewport — outnumbering vehicles 2.6 to 1, with ~900
/// of them overlapping a neighbour at that zoom. Scoping them to one route gives
/// around 20 to 40 instead, and every dot on screen means something: this vehicle
/// will call there.
final class StationAnnotation: NSObject, MKAnnotation {
    let station: GTFSStation
    /// 1-based position along the route.
    let sequence: Int
    let total: Int
    let colorHex: String?
    let isTerminus: Bool

    var coordinate: CLLocationCoordinate2D { station.coordinate }
    var title: String? { station.name }
    var subtitle: String? {
        var parts = ["Stop \(sequence) of \(total)"]
        if station.platformCount > 1 { parts.append("\(station.platformCount) platforms") }
        return parts.joined(separator: " · ")
    }

    init(station: GTFSStation, sequence: Int, total: Int, colorHex: String?) {
        self.station = station
        self.sequence = sequence
        self.total = total
        self.colorHex = colorHex
        self.isTerminus = sequence == 1 || sequence == total
    }
}

/// A small dot that sits under the vehicles rather than competing with them.
final class StationAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "StationAnnotationView"

    private let dot = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // Sized for the input device, not the art: a 10 pt dot is fine under a
        // cursor and impossible under a fingertip.
        let side = Platform.minimumHitSize
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        canShowCallout = true
        // Vehicles are the subject of this map; a stop must never hide one.
        zPriority = .min
        displayPriority = .defaultLow
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dot.position = CGPoint(x: side / 2, y: side / 2)
        hostLayer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ annotation: StationAnnotation) {
        let fill = annotation.colorHex.flatMap(RGBA.init(hex:)) ?? RGBA(0.04, 0.52, 1.00)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(origin: .zero, size: MarkerImages.stationDotSize(terminus: annotation.isTerminus))
        dot.contents = MarkerImages.shared.stationDot(fill: fill, terminus: annotation.isTerminus)
        CATransaction.commit()
    }
}
