import Foundation
import CoreLocation

/// What the app knows about the trip a vehicle is running.
///
/// A value type rather than a stored model so it can cross to the UI without
/// carrying SwiftData objects between actors.
public struct ResolvedTrip: Sendable, Hashable {
    public let tripID: String
    public let headsign: String
    public let routeShortName: String
    public let routeLongName: String
    /// Six hex digits from the city's own data, or nil if the route is unknown.
    public let routeColor: String?
    public let routeType: Int?
    /// The path the vehicle follows. Empty until the shape is hydrated.
    public let path: [CLLocationCoordinate2D]
    /// Stations in call order. Empty until hydrated.
    public let stationIDs: [String]

    public var hasPath: Bool { !path.isEmpty }

    public init(
        tripID: String,
        headsign: String,
        routeShortName: String,
        routeLongName: String,
        routeColor: String?,
        routeType: Int?,
        path: [CLLocationCoordinate2D],
        stationIDs: [String]
    ) {
        self.tripID = tripID
        self.headsign = headsign
        self.routeShortName = routeShortName
        self.routeLongName = routeLongName
        self.routeColor = routeColor
        self.routeType = routeType
        self.path = path
        self.stationIDs = stationIDs
    }

    /// CLLocationCoordinate2D is not Equatable, and comparing hundreds of points
    /// would be wasteful anyway: a trip's identity plus how much of it has been
    /// hydrated is what callers actually care about.
    public static func == (lhs: ResolvedTrip, rhs: ResolvedTrip) -> Bool {
        lhs.tripID == rhs.tripID
            && lhs.headsign == rhs.headsign
            && lhs.routeShortName == rhs.routeShortName
            && lhs.routeColor == rhs.routeColor
            && lhs.path.count == rhs.path.count
            && lhs.stationIDs == rhs.stationIDs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(tripID)
        hasher.combine(path.count)
    }
}
