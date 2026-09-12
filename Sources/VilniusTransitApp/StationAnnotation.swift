import AppKit
import MapKit
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
        wantsLayer = true
        frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        canShowCallout = true
        // Vehicles are the subject of this map; a stop must never hide one.
        zPriority = .min
        displayPriority = .defaultLow
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dot.position = CGPoint(x: 10, y: 10)
        dot.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ annotation: StationAnnotation) {
        let fill = annotation.colorHex.flatMap(MarkerImages.color(hex:)) ?? .systemBlue
        let image = MarkerImages.shared.stationDot(fill: fill, terminus: annotation.isTerminus)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(origin: .zero, size: image.size)
        dot.contents = image
        CATransaction.commit()
    }
}
