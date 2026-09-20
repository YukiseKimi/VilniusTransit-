import Testing
import Foundation
@testable import SklandusKit

@Suite("App info")
struct AppInfoTests {
    @Test("the display name is the one shown under the icon")
    func displayName() {
        #expect(AppInfo.displayName == "Sklandus")
    }

    /// The feeds report times in Vilnius local time, so this must never fall back
    /// to whatever zone the reader's device happens to be in.
    @Test("the city timezone resolves to Vilnius, not the device's zone")
    func cityTimeZone() {
        #expect(AppInfo.cityTimeZone.identifier == "Europe/Vilnius")
    }
}
