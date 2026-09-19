import Foundation
import CoreLocation

/// Vehicle class as published in the `Transportas` column of the live feed.
public enum TransitMode: String, Sendable, Hashable, CaseIterable {
    case bus
    case trolleybus
    case ferry

    /// The feed uses Lithuanian plurals. Unknown values are rejected rather than guessed.
    init?(feedValue: some StringProtocol) {
        switch feedValue {
        case "Autobusai":   self = .bus
        case "Troleibusai": self = .trolleybus
        case "Laivai":      self = .ferry
        default:            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .bus:        "Bus"
        case .trolleybus: "Trolleybus"
        case .ferry:      "Ferry"
        }
    }

    /// GTFS `route_type`. 800 is the extended-GTFS trolleybus code, which is what
    /// `routes.txt` actually uses for the 16 trolleybus routes.
    public var gtfsRouteType: Int {
        switch self {
        case .bus:        3
        case .trolleybus: 800
        case .ferry:      4
        }
    }
}
