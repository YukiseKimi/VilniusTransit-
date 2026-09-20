import Foundation
import SwiftData
import CoreLocation

/// The path a route follows, plus the stations along it.
///
/// Path and stop list live on one row because they are keyed identically, by shape,
/// and are always wanted together: drawing a selected vehicle's route means drawing
/// the line and its stops in the same breath.
@Model
public final class StoredShape {
    @Attribute(.unique) public var id: String
    /// Coordinates packed at 16 bytes a point; see `CoordinateBlob`.
    @Attribute(.externalStorage) public var pathData: Data
    /// Station ids in call order.
    public var stationIDs: [String]
    /// When a vehicle last used this shape. Shapes unused for a week are evicted,
    /// so the store stays proportional to the routes actually watched.
    public var lastUsed: Date

    public var path: [CLLocationCoordinate2D] { CoordinateBlob.decode(pathData) }

    public init(
        id: String,
        path: [CLLocationCoordinate2D],
        stationIDs: [String],
        lastUsed: Date = Date()
    ) {
        self.id = id
        self.pathData = CoordinateBlob.encode(path)
        self.stationIDs = stationIDs
        self.lastUsed = lastUsed
    }
}
