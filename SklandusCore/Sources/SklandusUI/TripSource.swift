import Foundation
import SklandusKit

/// Where trip details come from.
///
/// An abstraction rather than the store directly, so the cache above it can be
/// tested without a database or an archive, and so the map never learns that
/// SwiftData exists.
public protocol TripSource: Sendable {
    /// The stored details for this trip, or nil if it has not been hydrated (or
    /// never will be, in the case of a layover movement).
    func resolved(tripID: String) async -> ResolvedTrip?

    /// Notes that these trips are wanted. Returns immediately; the source gathers
    /// misses and reads them in one pass.
    func request(trips: Set<String>) async
}
