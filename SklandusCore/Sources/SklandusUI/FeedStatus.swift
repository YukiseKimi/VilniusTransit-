import Foundation

/// What the live feed is doing, in terms the interface can show.
public enum FeedStatus: Sendable, Equatable {
    /// Started, nothing received yet.
    case connecting
    /// A snapshot arrived.
    case live
    /// The server answered 304: what we have is current.
    case unchanged
    /// The network is unreachable, so polling is paused rather than failing.
    case offline
    case failing(String)
}
