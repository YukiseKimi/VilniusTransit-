import Foundation
import CoreLocation

/// One row of `gps_full.txt`, decoded into sane units.
public struct Vehicle: Sendable, Identifiable, Hashable {
    /// Fleet number (`MasinosNumeris`). Unique across the live fleet, and stable
    /// across polls, which is what lets us animate a marker rather than recreate it.
    public let id: String

    public let mode: TransitMode
    /// Route short name as printed on the vehicle, e.g. "1G", "13", "N2".
    public let route: String
    public let coordinate: CLLocationCoordinate2D
    /// km/h.
    public let speed: Double
    /// Degrees clockwise from north.
    public let heading: Double
    /// Positive = behind schedule, negative = ahead. `nil` when not on a trip.
    public let deviationSeconds: Int?
    /// Seconds since local midnight in Europe/Vilnius, as reported by the vehicle.
    public let measuredAtSecondsSinceMidnight: Int
    /// `KryptiesPavadinimas` — the destination shown to passengers.
    public let headsign: String
    /// `ReisoIdGTFS`. Joins to `trips.trip_id` in the static GTFS feed.
    /// Empty on the wire for vehicles that are deadheading between runs.
    public let gtfsTripID: String?
    /// Raw `MasinosTipas` code (KWZ, KWNZD, ...). Undocumented; kept opaque.
    public let vehicleTypeCode: String

    public var punctuality: Punctuality { Punctuality(deviationSeconds: deviationSeconds) }
    /// A vehicle with no GTFS trip is between scheduled runs.
    public var isInService: Bool { gtfsTripID != nil }

    public init(
        id: String,
        mode: TransitMode,
        route: String,
        coordinate: CLLocationCoordinate2D,
        speed: Double,
        heading: Double,
        deviationSeconds: Int?,
        measuredAtSecondsSinceMidnight: Int,
        headsign: String,
        gtfsTripID: String?,
        vehicleTypeCode: String
    ) {
        self.id = id
        self.mode = mode
        self.route = route
        self.coordinate = coordinate
        self.speed = speed
        self.heading = heading
        self.deviationSeconds = deviationSeconds
        self.measuredAtSecondsSinceMidnight = measuredAtSecondsSinceMidnight
        self.headsign = headsign
        self.gtfsTripID = gtfsTripID
        self.vehicleTypeCode = vehicleTypeCode
    }

    public static func == (lhs: Vehicle, rhs: Vehicle) -> Bool {
        lhs.id == rhs.id
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.heading == rhs.heading
            && lhs.speed == rhs.speed
            && lhs.deviationSeconds == rhs.deviationSeconds
            && lhs.gtfsTripID == rhs.gtfsTripID
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
