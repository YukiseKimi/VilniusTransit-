import Foundation
import CoreLocation

public extension URL {
    /// Static timetable. 4.2 MB zipped, 39 MB unpacked, rebuilt whenever schedules change.
    static let vilniusGTFS = URL(string: "https://www.stops.lt/vilnius/vilnius/gtfs.zip")!
}
