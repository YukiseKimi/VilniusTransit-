import Foundation
import CoreLocation

/// Vehicle class as published in the `Transportas` column of the live feed.
public enum TransitMode: String, Sendable, Hashable, CaseIterable {
    case bus
    case trolleybus
    case ferry

    /// The feed uses Lithuanian plurals. Unknown values are rejected rather than guessed.
    init?(feedValue: some StringProtocol) {
        switch feedValue {
        case "Autobusai":   self = .bus
        case "Troleibusai": self = .trolleybus
        case "Laivai":      self = .ferry
        default:            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .bus:        "Bus"
        case .trolleybus: "Trolleybus"
        case .ferry:      "Ferry"
        }
    }

    /// GTFS `route_type`. 800 is the extended-GTFS trolleybus code, which is what
    /// `routes.txt` actually uses for the 16 trolleybus routes.
    public var gtfsRouteType: Int {
        switch self {
        case .bus:        3
        case .trolleybus: 800
        case .ferry:      4
        }
    }
}

/// How far a vehicle is from its timetable, bucketed for display.
public enum Punctuality: Sendable, Hashable {
    case early       // more than 60s ahead
    case onTime      // within +/- 60s
    case late        // 60s..300s behind
    case veryLate    // more than 300s behind
    case unknown     // vehicle is not on a scheduled trip

    init(deviationSeconds: Int?) {
        guard let d = deviationSeconds else { self = .unknown; return }
        switch d {
        case ..<(-60):   self = .early
        case -60...60:   self = .onTime
        case 61...300:   self = .late
        default:         self = .veryLate
        }
    }
}

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

/// The feed's timebase is Europe/Vilnius, never the user's zone.
public enum VilniusTime {
    public static let zone = TimeZone(identifier: "Europe/Vilnius")!

    /// Renders `MatavimoLaikas` back into a wall-clock string.
    /// Values can exceed 86400 because GTFS service days run past midnight.
    public static func clockString(secondsSinceMidnight s: Int) -> String {
        let wrapped = ((s % 86400) + 86400) % 86400
        return String(format: "%02d:%02d:%02d", wrapped / 3600, (wrapped / 60) % 60, wrapped % 60)
    }
}
