import Foundation
import CoreLocation

/// Reads the city's timetable archive, answering targeted questions rather than
/// decoding the whole thing.
///
/// There is no per-trip API: each file inside the archive is one compressed stream,
/// so reading a single row means inflating and scanning that whole file. Reading
/// one trip therefore costs the same as reading four hundred, which is why every
/// query here takes a *set* of identifiers. Callers batch their misses and ask once.
public struct GTFSArchive: Sendable {

    /// Files this reader ever inflates. Everything else in the archive — calendars,
    /// agency, areas — stays compressed and untouched.
    public static let usedFiles = ["routes.txt", "trips.txt", "shapes.txt", "stops.txt", "stop_times.txt"]

    private let archive: ZIPArchive

    public init(data: Data) throws {
        self.archive = try ZIPArchive(data: data)
    }

    private func csv(_ name: String) throws -> GTFSCSV? {
        guard let data = try archive.contents(of: name) else { return nil }
        return try GTFSCSV(data)
    }

    // MARK: - Always loaded in full

    /// 115 rows. Small, and every vehicle needs one.
    public func routes() throws -> [GTFSRoute] {
        guard let csv = try csv("routes.txt") else { return [] }
        let columns = try csv.indices(of: [
            "route_id", "route_short_name", "route_long_name", "route_type",
            "route_color", "route_text_color"
        ])
        var routes: [GTFSRoute] = []
        routes.reserveCapacity(128)
        csv.forEachRow { row in
            let id = row.string(columns[0])
            guard !id.isEmpty else { return }
            routes.append(GTFSRoute(
                id: id,
                shortName: row.string(columns[1]),
                longName: row.string(columns[2]),
                routeType: row.int(columns[3]) ?? 3,
                color: row.string(columns[4]),
                textColor: row.string(columns[5])
            ))
        }
        return routes
    }

    /// 1,553 stops, grouped into 845 stations.
    public func stations() throws -> [GTFSStation] {
        StationGrouping.stations(from: try stops())
    }

    public func stops() throws -> [GTFSStop] {
        guard let csv = try csv("stops.txt") else { return [] }
        let columns = try csv.indices(of: ["stop_id", "stop_name", "stop_desc", "stop_lat", "stop_lon"])
        var stops: [GTFSStop] = []
        stops.reserveCapacity(2048)
        csv.forEachRow { row in
            let id = row.string(columns[0])
            guard !id.isEmpty,
                  let latitude = row.double(columns[3]),
                  let longitude = row.double(columns[4])
            else { return }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            stops.append(GTFSStop(
                id: id,
                name: row.string(columns[1]),
                detail: row.string(columns[2]),
                coordinate: coordinate
            ))
        }
        return stops
    }

    // MARK: - Loaded on demand

    /// The trips with these ids. Unknown ids are simply absent from the result:
    /// about 1–3% of in-service vehicles run layover movements whose trip ids never
    /// appear in the published timetable.
    public func trips(ids wanted: Set<String>) throws -> [GTFSTrip] {
        guard !wanted.isEmpty, let csv = try csv("trips.txt") else { return [] }
        let columns = try csv.indices(of: [
            "route_id", "trip_id", "trip_headsign", "direction_id", "shape_id"
        ])
        let wantedHashes = Set(wanted.map(GTFSCSV.fieldHash))

        var trips: [GTFSTrip] = []
        trips.reserveCapacity(wanted.count)
        csv.forEachRow { row in
            // Reject on a byte hash first so the ~99% of rows we do not want never
            // allocate a String.
            guard wantedHashes.contains(row.fieldHash(columns[1])) else { return }
            let id = row.string(columns[1])
            guard wanted.contains(id) else { return }   // guards against a hash collision
            let shape = row.string(columns[4])
            trips.append(GTFSTrip(
                id: id,
                routeID: row.string(columns[0]),
                headsign: row.string(columns[2]),
                directionID: row.int(columns[3]),
                shapeID: shape.isEmpty ? nil : shape
            ))
        }
        return trips
    }

    /// The paths for these shapes, each ordered by `shape_pt_sequence`.
    ///
    /// GTFS does not promise the rows arrive in order, and drawing them as they come
    /// makes the line zigzag across the city.
    public func shapes(ids wanted: Set<String>) throws -> [String: [CLLocationCoordinate2D]] {
        guard !wanted.isEmpty, let csv = try csv("shapes.txt") else { return [:] }
        let columns = try csv.indices(of: ["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"])
        let wantedHashes = Set(wanted.map(GTFSCSV.fieldHash))

        var pending: [String: [(sequence: Int, coordinate: CLLocationCoordinate2D)]] = [:]
        csv.forEachRow { row in
            guard wantedHashes.contains(row.fieldHash(columns[0])) else { return }
            let id = row.string(columns[0])
            guard wanted.contains(id),
                  let latitude = row.double(columns[1]),
                  let longitude = row.double(columns[2])
            else { return }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            pending[id, default: []].append((row.int(columns[3]) ?? 0, coordinate))
        }
        return pending.mapValues { points in
            points.sorted { $0.sequence < $1.sequence }.map(\.coordinate)
        }
    }

    /// The stations each shape calls at, in order.
    ///
    /// Every trip sharing a shape calls at the same stops, so only one
    /// representative trip per shape is read out of the 504k-row `stop_times.txt`,
    /// and every other row is discarded as it streams past.
    public func stopLists(
        forShapes wanted: Set<String>,
        stations: [GTFSStation]
    ) throws -> [String: [String]] {
        guard !wanted.isEmpty, let csv = try csv("stop_times.txt") else { return [:] }
        let representatives = try representativeTrips(forShapes: wanted)
        guard !representatives.isEmpty else { return [:] }

        let columns = try csv.indices(of: ["trip_id", "stop_id", "stop_sequence"])
        var stationOfStop: [String: String] = [:]
        for station in stations {
            for platform in station.platformIDs { stationOfStop[platform] = station.id }
        }

        var byTripHash: [UInt64: (tripID: String, shapeID: String)] = [:]
        for (shapeID, tripID) in representatives {
            byTripHash[GTFSCSV.fieldHash(tripID)] = (tripID, shapeID)
        }

        var pending: [String: [(sequence: Int, stationID: String)]] = [:]
        csv.forEachRow { row in
            guard let candidate = byTripHash[row.fieldHash(columns[0])],
                  row.string(columns[0]) == candidate.tripID,
                  let stationID = stationOfStop[row.string(columns[1])]
            else { return }
            pending[candidate.shapeID, default: []].append((row.int(columns[2]) ?? 0, stationID))
        }

        return pending.mapValues { entries in
            var seen = Set<String>()
            // A loop route can call at the same station twice; keep the first.
            return entries.sorted { $0.sequence < $1.sequence }
                .compactMap { seen.insert($0.stationID).inserted ? $0.stationID : nil }
        }
    }

    /// One trip per shape, chosen as the lowest-sorting trip id so the same archive
    /// always decodes to the same stop lists.
    func representativeTrips(forShapes wanted: Set<String>) throws -> [String: String] {
        guard let csv = try csv("trips.txt") else { return [:] }
        let columns = try csv.indices(of: ["trip_id", "shape_id"])
        let wantedHashes = Set(wanted.map(GTFSCSV.fieldHash))

        var lowest: [String: String] = [:]
        csv.forEachRow { row in
            guard wantedHashes.contains(row.fieldHash(columns[1])) else { return }
            let shapeID = row.string(columns[1])
            guard wanted.contains(shapeID) else { return }
            let tripID = row.string(columns[0])
            if let current = lowest[shapeID], current <= tripID { return }
            lowest[shapeID] = tripID
        }
        return lowest
    }
}
