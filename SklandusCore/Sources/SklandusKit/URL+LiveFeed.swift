import Foundation

public extension URL {
    /// The live vehicle feed: one row per vehicle, ~385 rows and ~47 KB, refreshed
    /// continuously. Published by the city via stops.lt.
    ///
    /// Force-unwrapped deliberately: a literal that fails to parse is a mistake in
    /// this file, not a runtime condition any caller could handle.
    static let vilniusLiveFeed = URL(string: "https://stops.lt/vilnius/gps_full.txt")!
}
