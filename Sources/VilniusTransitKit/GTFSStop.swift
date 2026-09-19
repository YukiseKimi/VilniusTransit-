import Foundation
import CoreLocation

public struct GTFSStop: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// `stop_desc` — a direction hint like "link stoties" or "iš miesto".
    public let detail: String
    public let coordinate: CLLocationCoordinate2D

    public static func == (lhs: GTFSStop, rhs: GTFSStop) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
