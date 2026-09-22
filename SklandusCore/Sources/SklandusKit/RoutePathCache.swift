import Foundation
import CoreLocation

/// Prepared paths, kept between polls.
///
/// Building a path measures every segment of a shape — up to a couple of thousand
/// points — and every vehicle on a route shares the same one, so they are built
/// once and reused until the trips using them leave the feed.
public final class RoutePathCache {
    private var paths: [String: RoutePath] = [:]

    public init() {}

    public var count: Int { paths.count }
    public var isEmpty: Bool { paths.isEmpty }

    /// The prepared path for a trip, built on first use. `nil` for a trip whose
    /// shape has not been hydrated yet.
    public func path(for tripID: String, coordinates: () -> [CLLocationCoordinate2D]) -> RoutePath? {
        if let cached = paths[tripID] { return cached }
        let points = coordinates()
        guard points.count > 1 else { return nil }
        let path = RoutePath(coordinates: points)
        paths[tripID] = path
        return path
    }

    /// Drops paths for trips nothing is running any more.
    public func keep(only tripIDs: Set<String>) {
        guard paths.count > tripIDs.count else { return }
        paths = paths.filter { tripIDs.contains($0.key) }
    }
}
