import CoreGraphics
import MapKit
import QuartzCore
import VilniusTransitKit

/// One annotation per fleet number, kept alive across polls.
///
/// Identity is what makes smooth motion possible: MapKit moves the existing view
/// when `coordinate` changes, so the marker glides instead of being destroyed and
/// rebuilt every five seconds.
final class VehicleAnnotation: NSObject, MKAnnotation {
    let fleetNumber: String

    /// `@objc dynamic` so MapKit observes the change and repositions the view.
    @objc dynamic var coordinate: CLLocationCoordinate2D

    var vehicle: Vehicle
    var heading: Double

    /// Resolved from the static timetable via `ReisoIdGTFS` -> `trips.trip_id`.
    /// Nil until the catalog loads, and for layover movements absent from it.
    var routeColorHex: String?
    var routeLongName: String?

    var title: String? { "\(vehicle.route) → \(vehicle.headsign)" }
    var subtitle: String? {
        var parts: [String] = []
        if let routeLongName, !routeLongName.isEmpty { parts.append(routeLongName) }
        parts += ["\(vehicle.mode.displayName) \(vehicle.id)", "\(Int(vehicle.speed)) km/h"]
        if let deviation = vehicle.deviationSeconds {
            let minutes = abs(deviation) / 60, seconds = abs(deviation) % 60
            let sign = deviation > 0 ? "late" : "early"
            parts.append(abs(deviation) < 60 ? "on time" : "\(minutes)m \(seconds)s \(sign)")
        } else {
            parts.append("not in service")
        }
        return parts.joined(separator: " · ")
    }

    init(
        vehicle: Vehicle,
        coordinate: CLLocationCoordinate2D,
        heading: Double,
        routeColorHex: String? = nil,
        routeLongName: String? = nil
    ) {
        self.fleetNumber = vehicle.id
        self.vehicle = vehicle
        self.coordinate = coordinate
        self.heading = heading
        self.routeColorHex = routeColorHex
        self.routeLongName = routeLongName
    }
}
