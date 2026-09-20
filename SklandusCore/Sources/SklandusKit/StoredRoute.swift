import Foundation
import SwiftData

/// A route, as stored. 115 rows, small enough to keep in full.
///
/// `.unique` is safe here because this store is local only; the AGENTS.md rules
/// that forbid it apply to SwiftData backed by CloudKit.
@Model
public final class StoredRoute {
    @Attribute(.unique) public var id: String
    public var shortName: String
    public var longName: String
    /// 3 = bus, 4 = ferry, 800 = trolleybus (extended GTFS).
    public var routeType: Int
    /// Six hex digits. Encodes service class — one blue for regular buses, red for
    /// trolleybuses, black for night routes, green for express, teal for the ferry.
    public var color: String
    public var textColor: String

    public init(
        id: String,
        shortName: String,
        longName: String,
        routeType: Int,
        color: String,
        textColor: String
    ) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.routeType = routeType
        self.color = color
        self.textColor = textColor
    }
}
