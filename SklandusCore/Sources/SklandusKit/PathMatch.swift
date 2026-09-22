import CoreLocation

/// Where a reported position lands on a route's own path.
public struct PathMatch: Sendable, Equatable {
    /// Metres travelled along the path to reach this point.
    public let distanceAlong: CLLocationDistance
    /// How far the reported position was from the path. The measure of how much
    /// the match should be trusted.
    public let offset: CLLocationDistance
    public let coordinate: CLLocationCoordinate2D

    public static func == (lhs: PathMatch, rhs: PathMatch) -> Bool {
        lhs.distanceAlong == rhs.distanceAlong
            && lhs.offset == rhs.offset
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}
