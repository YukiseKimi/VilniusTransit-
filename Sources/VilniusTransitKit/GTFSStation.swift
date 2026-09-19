import Foundation
import CoreLocation

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
