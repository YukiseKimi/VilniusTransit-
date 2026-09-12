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

/// Several physical stops that are one place to a passenger.
///
/// Vilnius lists every direction as its own stop: 1,424 of the 1,553 stops share a
/// name with at least one other, typically a pair ~26 m apart across a road.
/// Drawing them raw produces twin dots for every stop in the city. Grouping by name
/// and proximity collapses 1,553 stops into 779 stations.
public struct GTFSStation: Sendable, Identifiable, Hashable {
    /// The lowest-sorting platform id in the group, so it is stable across rebuilds.
    public let id: String
    public let name: String
    /// Centroid of the platforms.
    public let coordinate: CLLocationCoordinate2D
    public let platformIDs: [String]

    public var platformCount: Int { platformIDs.count }

    public static func == (lhs: GTFSStation, rhs: GTFSStation) -> Bool { lhs.id == rhs.id }
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
    /// Direction-pairs merged into single places.
    public let stations: [GTFSStation]
    /// Ordered station ids served by each `shape_id`.
    ///
    /// This is all that survives of `stop_times.txt`. The file is 26 MB and 504k
    /// rows; keeping it would dwarf everything else in memory, and nothing needs
    /// per-trip timings. Collapsing it to one ordered stop list per shape — 945
    /// shapes rather than 25k trips — costs a few thousand strings and is what lets
    /// the map show only the selected route's stops.
    public let stationsByShape: [String: [String]]
    private let stationIndex: [String: Int]
    /// `Last-Modified` of the archive this was decoded from, when known.
    public let publishedAt: Date?

    public init(
        routes: [String: GTFSRoute],
        trips: [String: GTFSTrip],
        shapes: [String: [CLLocationCoordinate2D]],
        stops: [String: GTFSStop],
        stations: [GTFSStation] = [],
        stationsByShape: [String: [String]] = [:],
        publishedAt: Date? = nil
    ) {
        self.routes = routes
        self.trips = trips
        self.shapes = shapes
        self.stops = stops
        self.stations = stations
        self.stationsByShape = stationsByShape
        self.publishedAt = publishedAt
        var index: [String: Int] = [:]
        index.reserveCapacity(stations.count)
        for (offset, station) in stations.enumerated() { index[station.id] = offset }
        self.stationIndex = index
    }

    public func station(_ id: String) -> GTFSStation? {
        stationIndex[id].map { stations[$0] }
    }

    /// The stations a vehicle on this trip will call at, in order.
    public func stations(forTrip tripID: String) -> [GTFSStation] {
        guard let shapeID = trips[tripID]?.shapeID,
              let ids = stationsByShape[shapeID]
        else { return [] }
        return ids.compactMap(station)
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
        public var stations = 0
        public var shapesWithStops = 0
        public var duration: TimeInterval = 0
        /// Files named in the archive that we deliberately never inflated.
        public var skippedFiles: [String] = []
    }

    /// Files we actually inflate. Everything else in the archive stays compressed.
    public static let required = ["routes.txt", "trips.txt", "shapes.txt", "stops.txt", "stop_times.txt"]

    /// Two stops with the same name this close together are one place.
    ///
    /// 150 m comfortably covers a pair either side of a road (median spread 78 m)
    /// without merging same-named stops that are genuinely a walk apart.
    static let stationRadius: CLLocationDistance = 150

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
        let stations = buildStations(from: stops)
        let stationsByShape = try decodeStationsByShape(archive, trips: trips, stops: stops, stations: stations)

        stats.routes = routes.count
        stats.trips = trips.count
        stats.shapes = shapes.count
        stats.shapePoints = shapes.values.reduce(0) { $0 + $1.count }
        stats.stops = stops.count
        stats.stations = stations.count
        stats.shapesWithStops = stationsByShape.count
        stats.duration = Date().timeIntervalSince(started)

        return (
            GTFSCatalog(
                routes: routes, trips: trips, shapes: shapes, stops: stops,
                stations: stations, stationsByShape: stationsByShape,
                publishedAt: publishedAt
            ),
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

    /// Groups same-named stops that sit within `stationRadius` of each other.
    ///
    /// Single-link clustering within each name group. Groups are tiny (a pair, or a
    /// handful at an interchange), so the quadratic inner loop never matters.
    static func buildStations(from stops: [String: GTFSStop]) -> [GTFSStation] {
        var byName: [String: [GTFSStop]] = [:]
        for stop in stops.values {
            byName[stop.name, default: []].append(stop)
        }

        var stations: [GTFSStation] = []
        stations.reserveCapacity(byName.count)

        for (name, group) in byName {
            var remaining = group.sorted { $0.id < $1.id }
            while !remaining.isEmpty {
                var cluster = [remaining.removeFirst()]
                var grew = true
                while grew {
                    grew = false
                    for candidate in remaining {
                        guard cluster.contains(where: { distance($0.coordinate, candidate.coordinate) < stationRadius })
                        else { continue }
                        cluster.append(candidate)
                        remaining.removeAll { $0.id == candidate.id }
                        grew = true
                    }
                }
                let ids = cluster.map(\.id).sorted()
                let latitude = cluster.reduce(0.0) { $0 + $1.coordinate.latitude } / Double(cluster.count)
                let longitude = cluster.reduce(0.0) { $0 + $1.coordinate.longitude } / Double(cluster.count)
                stations.append(GTFSStation(
                    id: ids[0],
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    platformIDs: ids
                ))
            }
        }
        return stations.sorted { $0.id < $1.id }
    }

    /// Reduces `stop_times.txt` to one ordered station list per shape.
    ///
    /// Every trip sharing a shape calls at the same stops, so only one
    /// representative trip per shape is read — 945 of 25,278 — and every other row
    /// in the 504k-row file is discarded as it streams past.
    static func decodeStationsByShape(
        _ archive: ZIPArchive,
        trips: [String: GTFSTrip],
        stops: [String: GTFSStop],
        stations: [GTFSStation]
    ) throws -> [String: [String]] {
        guard let csv = try csv(archive, "stop_times.txt") else { return [:] }
        let c = try csv.indices(of: ["trip_id", "stop_id", "stop_sequence"])

        // One representative trip per shape, chosen as the lowest-sorting trip id.
        // Picking whichever came first out of an unordered dictionary made the
        // decoded stop lists differ between runs of the same archive.
        var lowestTrip: [String: String] = [:]       // shapeID -> tripID
        for trip in trips.values {
            guard let shapeID = trip.shapeID else { continue }
            if let current = lowestTrip[shapeID], current <= trip.id { continue }
            lowestTrip[shapeID] = trip.id
        }
        // Keyed by a hash of the trip id's bytes so the 95% of rows belonging to
        // non-representative trips are rejected without allocating a String.
        var byTripHash: [UInt64: (tripID: String, shapeID: String)] = [:]
        byTripHash.reserveCapacity(lowestTrip.count)
        for (shapeID, tripID) in lowestTrip {
            byTripHash[GTFSCSV.fieldHash(tripID)] = (tripID, shapeID)
        }

        var stationOfStop: [String: String] = [:]
        for station in stations {
            for platform in station.platformIDs { stationOfStop[platform] = station.id }
        }

        var pending: [String: [(sequence: Int, stationID: String)]] = [:]
        csv.forEachRow { row in
            guard let candidate = byTripHash[row.fieldHash(c[0])] else { return }
            // Verify the hash hit, so a collision cannot silently attach one
            // route's stops to another. Runs only on the ~5% that match.
            guard row.string(c[0]) == candidate.tripID else { return }
            guard let stationID = stationOfStop[row.string(c[1])] else { return }
            pending[candidate.shapeID, default: []].append((row.int(c[2]) ?? 0, stationID))
        }

        return pending.mapValues { entries in
            var seen = Set<String>()
            // A loop route can call at the same station twice; keep the first.
            return entries.sorted { $0.sequence < $1.sequence }
                .compactMap { seen.insert($0.stationID).inserted ? $0.stationID : nil }
        }
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let dLat = (b.latitude - a.latitude) * 111_320
        let dLon = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
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
