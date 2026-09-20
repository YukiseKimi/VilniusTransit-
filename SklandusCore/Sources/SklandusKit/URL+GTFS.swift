import Foundation
import CoreLocation

public extension URL {
    /// The static timetable: ~4 MB zipped, ~36 MB unpacked, rebuilt whenever the
    /// city changes schedules.
    ///
    /// Force-unwrapped deliberately: a literal that fails to parse is a mistake in
    /// this file, not a runtime condition any caller could handle.
    static let vilniusGTFS = URL(string: "https://www.stops.lt/vilnius/vilnius/gtfs.zip")!
}
