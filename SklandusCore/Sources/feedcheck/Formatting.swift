import Foundation

extension Double {
    /// Fixed decimal places, pinned to POSIX so diagnostic output is comparable
    /// between machines.
    func fixed(_ places: Int) -> String {
        formatted(
            .number
                .precision(.fractionLength(places))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
    }
}
