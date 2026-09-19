import Foundation
import CoreLocation

/// The feed's timebase is Europe/Vilnius, never the user's zone.
public enum VilniusTime {
    public static let zone = TimeZone(identifier: "Europe/Vilnius")!

    /// Renders `MatavimoLaikas` back into a wall-clock string.
    /// Values can exceed 86400 because GTFS service days run past midnight.
    public static func clockString(secondsSinceMidnight s: Int) -> String {
        let wrapped = ((s % 86400) + 86400) % 86400
        let twoDigits = IntegerFormatStyle<Int>(locale: Locale(identifier: "en_US_POSIX"))
            .precision(.integerLength(2))
            .grouping(.never)
        return [wrapped / 3600, (wrapped / 60) % 60, wrapped % 60]
            .map { $0.formatted(twoDigits) }
            .joined(separator: ":")
    }
}
