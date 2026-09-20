import Foundation
import SwiftData

/// One journey along a route, as stored.
///
/// Written only for trips the live feed has actually shown, so this grows to the
/// few hundred in flight rather than the archive's ~25,000.
@Model
public final class StoredTrip {
    @Attribute(.unique) public var id: String
    public var routeID: String
    public var headsign: String
    public var directionID: Int?
    /// Nil for the rare trip published without a path.
    public var shapeID: String?

    public init(id: String, routeID: String, headsign: String, directionID: Int?, shapeID: String?) {
        self.id = id
        self.routeID = routeID
        self.headsign = headsign
        self.directionID = directionID
        self.shapeID = shapeID
    }
}
