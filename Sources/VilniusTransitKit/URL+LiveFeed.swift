import Foundation
import Network

public extension URL {
    /// Full live feed: one row per vehicle, ~385 rows / ~47 KB, refreshed continuously.
    static let vilniusLiveFeed = URL(string: "https://stops.lt/vilnius/gps_full.txt")!
}
