import Foundation
import CoreLocation

public struct GTFSRoute: Sendable, Identifiable, Hashable {
    public let id: String
    /// As printed on the vehicle — "7", "3G", "N2". Matches the live feed's `Marsrutas`.
    public let shortName: String
    public let longName: String
    /// 3 = bus, 4 = ferry, 800 = trolleybus (extended GTFS).
    public let routeType: Int
    /// Six hex digits, no leading '#'. Always populated in this feed.
    public let color: String
    public let textColor: String
}
