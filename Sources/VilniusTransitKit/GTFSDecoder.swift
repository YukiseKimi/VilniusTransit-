import Foundation
import CoreLocation

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
