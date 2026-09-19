import Foundation
import CoreLocation

public struct GTFSTrip: Sendable, Identifiable, Hashable {
    public let id: String
    public let routeID: String
    public let headsign: String
    public let directionID: Int?
    public let shapeID: String?
}
