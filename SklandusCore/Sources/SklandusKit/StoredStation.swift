import Foundation
import SwiftData
import CoreLocation

/// A place passengers wait, as stored: same-named stops within 150 m merged.
/// 842 rows, kept in full.
@Model
public final class StoredStation {
    @Attribute(.unique) public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// The individual stop ids merged into this station, usually one per direction.
    public var platformIDs: [String]

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public init(id: String, name: String, coordinate: CLLocationCoordinate2D, platformIDs: [String]) {
        self.id = id
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.platformIDs = platformIDs
    }
}
