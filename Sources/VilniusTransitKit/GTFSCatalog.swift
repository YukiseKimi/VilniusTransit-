import Foundation
import CoreLocation

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
