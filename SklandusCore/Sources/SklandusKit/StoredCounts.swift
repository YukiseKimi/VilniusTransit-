import Foundation

/// How much of the timetable is stored: routes and stations in full, trips and
/// shapes only as vehicles have needed them.
public struct StoredCounts: Sendable, Equatable {
    public let routes: Int
    public let stations: Int
    public let trips: Int
    public let shapes: Int

    public init(routes: Int, stations: Int, trips: Int, shapes: Int) {
        self.routes = routes
        self.stations = stations
        self.trips = trips
        self.shapes = shapes
    }
}
