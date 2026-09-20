import Foundation

/// Facts about the app itself that both platforms and the tests share.
public enum AppInfo {
    /// Shown under the icon and in the About window.
    public static let displayName = "Sklandus"

    /// The city's timezone. Pinned because the transit feeds report times in
    /// Vilnius local time regardless of where the reader happens to be.
    public static let cityTimeZone = TimeZone(identifier: "Europe/Vilnius") ?? .gmt
}
