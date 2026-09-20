import Foundation

/// Times as the live feed reports them: seconds since midnight in Vilnius.
///
/// The feed's `MatavimoLaikas` is a count of seconds since local midnight, not a
/// timestamp, and it can exceed 86400 because transit service days run past
/// midnight. The timezone is deliberately the city's rather than the reader's; see
/// `AppInfo.cityTimeZone`.
public enum FeedClock {
    /// Renders a fix time back into a wall clock reading.
    public static func clockString(secondsSinceMidnight seconds: Int) -> String {
        let wrapped = ((seconds % 86400) + 86400) % 86400
        // Pinned to POSIX so the digits are the same wherever the reader is.
        let twoDigits = IntegerFormatStyle<Int>(locale: Locale(identifier: "en_US_POSIX"))
            .precision(.integerLength(2))
            .grouping(.never)
        return [wrapped / 3600, (wrapped / 60) % 60, wrapped % 60]
            .map { $0.formatted(twoDigits) }
            .joined(separator: ":")
    }

    /// Seconds between two fix times, allowing for the service day rolling past
    /// midnight. Nil when the pair cannot be made sense of.
    public static func interval(from: Int, to: Int) -> Int? {
        let day = 86400
        let start = ((from % day) + day) % day
        let end = ((to % day) + day) % day
        var delta = end - start
        if delta < 0 { delta += day }
        // A gap of most of a day is a clock artefact, not a stale vehicle.
        return delta > day / 2 ? nil : delta
    }
}
