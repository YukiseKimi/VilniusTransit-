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
