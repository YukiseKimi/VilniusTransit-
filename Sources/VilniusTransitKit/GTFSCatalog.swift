import Foundation
import CoreLocation

public extension URL {
    /// Static timetable. 4.2 MB zipped, 39 MB unpacked, rebuilt whenever schedules change.
    static let vilniusGTFS = URL(string: "https://www.stops.lt/vilnius/vilnius/gtfs.zip")!
}

public struct GTFSRoute: Sendable, Identifiable, Hashable {
    public let id: String
    /// As printed on the vehicle — "7", "3G", "N2". Matches the live feed's `Marsrutas`.
    public let shortName: String
    public let longName: String
    /// 3 = bus, 4 = ferry, 800 = trolleybus (extended GTFS).
    public let routeType: Int
    /// Six hex digits, no leading '#'. Always populated in this feed.
    public let color: String
    public let textColor: String
}

public struct GTFSTrip: Sendable, Identifiable, Hashable {
    public let id: String
    public let routeID: String
    public let headsign: String
    public let directionID: Int?
    public let shapeID: String?
}

public struct GTFSStop: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// `stop_desc` — a direction hint like "link stoties" or "iš miesto".
    public let detail: String
    public let coordinate: CLLocationCoordinate2D

    public static func == (lhs: GTFSStop, rhs: GTFSStop) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The static timetable, minus the parts a live map does not need.
///
/// `stop_times.txt` is deliberately absent. It is 27 MB of the archive's 39 MB and
/// about a million rows, and nothing here reads it — it is only required for
/// per-stop arrival predictions. Skipping it keeps the whole catalog small enough
/// to hold in plain dictionaries with no database behind them.
public struct GTFSCatalog: Sendable {
    public let routes: [String: GTFSRoute]
    public let trips: [String: GTFSTrip]
    /// Deduplicated by `shape_id`: 945 distinct paths behind 25k trips.
    public let shapes: [String: [CLLocationCoordinate2D]]
    public let stops: [String: GTFSStop]
    /// `Last-Modified` of the archive this was decoded from, when known.
    public let publishedAt: Date?

    public init(
        routes: [String: GTFSRoute],
        trips: [String: GTFSTrip],
        shapes: [String: [CLLocationCoordinate2D]],
        stops: [String: GTFSStop],
        publishedAt: Date? = nil
    ) {
        self.routes = routes
        self.trips = trips
        self.shapes = shapes
        self.stops = stops
        self.publishedAt = publishedAt
    }

    // MARK: - The join

    /// The live feed's `ReisoIdGTFS` is a `trips.trip_id`. That single join is what
    /// turns a moving dot into a vehicle with a route, a destination and a path.
    public func trip(_ tripID: String) -> GTFSTrip? { trips[tripID] }

    public func route(forTrip tripID: String) -> GTFSRoute? {
        guard let trip = trips[tripID] else { return nil }
        return routes[trip.routeID]
    }

    public func shape(forTrip tripID: String) -> [CLLocationCoordinate2D]? {
        guard let shapeID = trips[tripID]?.shapeID else { return nil }
        return shapes[shapeID]
    }

    public func route(forVehicle vehicle: Vehicle) -> GTFSRoute? {
        guard let tripID = vehicle.gtfsTripID else { return nil }
        return route(forTrip: tripID)
    }

    public var isEmpty: Bool { routes.isEmpty && trips.isEmpty }
    public static let empty = GTFSCatalog(routes: [:], trips: [:], shapes: [:], stops: [:])
}

// MARK: - Decoding

public enum GTFSDecoder {

    public struct Stats: Sendable {
        public var routes = 0
        public var trips = 0
        public var shapes = 0
        public var shapePoints = 0
        public var stops = 0
        public var duration: TimeInterval = 0
        /// Files named in the archive that we deliberately never inflated.
        public var skippedFiles: [String] = []
    }

    /// Files we actually inflate. Everything else in the archive stays compressed.
    public static let required = ["routes.txt", "trips.txt", "shapes.txt", "stops.txt"]

    public static func decode(
        archive data: Data,
        publishedAt: Date? = nil
    ) throws -> (catalog: GTFSCatalog, stats: Stats) {
        let started = Date()
        var stats = Stats()

        let archive = try ZIPArchive(data: data)
        stats.skippedFiles = archive.entries
            .map(\.name)
            .filter { !required.contains($0) }
            .sorted()

        let routes = try decodeRoutes(archive)
        let trips = try decodeTrips(archive)
        let shapes = try decodeShapes(archive)
        let stops = try decodeStops(archive)

        stats.routes = routes.count
        stats.trips = trips.count
        stats.shapes = shapes.count
        stats.shapePoints = shapes.values.reduce(0) { $0 + $1.count }
        stats.stops = stops.count
        stats.duration = Date().timeIntervalSince(started)

        return (
            GTFSCatalog(routes: routes, trips: trips, shapes: shapes, stops: stops, publishedAt: publishedAt),
            stats
        )
    }

    private static func csv(_ archive: ZIPArchive, _ name: String) throws -> GTFSCSV? {
        guard let data = try archive.contents(of: name) else { return nil }
        return try GTFSCSV(data)
    }

    static func decodeRoutes(_ archive: ZIPArchive) throws -> [String: GTFSRoute] {
        guard let csv = try csv(archive, "routes.txt") else { return [:] }
        let c = try csv.indices(of: [
            "route_id", "route_short_name", "route_long_name", "route_type",
            "route_color", "route_text_color",
        ])
        var routes: [String: GTFSRoute] = [:]
        routes.reserveCapacity(128)
        csv.forEachRow { row in
            let id = row.string(c[0])
            guard !id.isEmpty else { return }
            routes[id] = GTFSRoute(
                id: id,
                shortName: row.string(c[1]),
                longName: row.string(c[2]),
                routeType: row.int(c[3]) ?? 3,
                color: row.string(c[4]),
                textColor: row.string(c[5])
            )
        }
        return routes
    }

    static func decodeTrips(_ archive: ZIPArchive) throws -> [String: GTFSTrip] {
        guard let csv = try csv(archive, "trips.txt") else { return [:] }
        let c = try csv.indices(of: ["route_id", "trip_id", "trip_headsign", "direction_id", "shape_id"])
        var trips: [String: GTFSTrip] = [:]
        trips.reserveCapacity(32_768)
        csv.forEachRow { row in
            let id = row.string(c[1])
            guard !id.isEmpty else { return }
            let shape = row.string(c[4])
            trips[id] = GTFSTrip(
                id: id,
                routeID: row.string(c[0]),
                headsign: row.string(c[2]),
                directionID: row.int(c[3]),
                shapeID: shape.isEmpty ? nil : shape
            )
        }
        return trips
    }

    static func decodeShapes(_ archive: ZIPArchive) throws -> [String: [CLLocationCoordinate2D]] {
        guard let csv = try csv(archive, "shapes.txt") else { return [:] }
        let c = try csv.indices(of: ["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"])

        // GTFS does not promise shape points arrive in sequence order, and drawing
        // them out of order produces a polyline that zigzags across the city.
        var pending: [String: [(sequence: Int, coordinate: CLLocationCoordinate2D)]] = [:]
        pending.reserveCapacity(1024)

        csv.forEachRow { row in
            let id = row.string(c[0])
            guard !id.isEmpty,
                  let lat = row.double(c[1]),
                  let lon = row.double(c[2])
            else { return }
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            pending[id, default: []].append((row.int(c[3]) ?? 0, coordinate))
        }

        return pending.mapValues { points in
            points.sorted { $0.sequence < $1.sequence }.map(\.coordinate)
        }
    }

    static func decodeStops(_ archive: ZIPArchive) throws -> [String: GTFSStop] {
        guard let csv = try csv(archive, "stops.txt") else { return [:] }
        let c = try csv.indices(of: ["stop_id", "stop_name", "stop_desc", "stop_lat", "stop_lon"])
        var stops: [String: GTFSStop] = [:]
        stops.reserveCapacity(2048)
        csv.forEachRow { row in
            let id = row.string(c[0])
            guard !id.isEmpty,
                  let lat = row.double(c[3]),
                  let lon = row.double(c[4])
            else { return }
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            stops[id] = GTFSStop(
                id: id,
                name: row.string(c[1]),
                detail: row.string(c[2]),
                coordinate: coordinate
            )
        }
        return stops
    }
}
