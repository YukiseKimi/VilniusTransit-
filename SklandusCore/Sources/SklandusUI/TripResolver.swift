import Foundation
import Observation
import SklandusKit

/// Trip details, held in memory for the map to read synchronously.
///
/// Reading a trip out of the store costs about a millisecond. That is nothing for
/// the one vehicle a person selects, but the map colours every vehicle by its
/// route, and ~390 lookups a poll would cost roughly 0.4 s — far too slow for a
/// five-second cycle. A vehicle keeps the same trip until it reaches a terminus,
/// so the answers are worth keeping.
@MainActor
@Observable
public final class TripResolver {

    /// Above this many cached trips, entries no longer in the fleet are dropped.
    /// A day's running produces far more trips than are ever in flight at once.
    private static let softLimit = 1500

    private var cache: [String: ResolvedTrip] = [:]
    /// Trips the timetable does not contain. Kept so a layover vehicle does not
    /// cause a fresh lookup on every poll.
    private var absent: Set<String> = []

    /// Bumped whenever the cache gains entries, so views know to redraw.
    public private(set) var revision = 0

    private let source: TripSource

    public init(source: TripSource) {
        self.source = source
    }

    /// The cached details for a trip. Synchronous by design: this is called from
    /// the render path, once per visible vehicle.
    public func resolved(_ tripID: String?) -> ResolvedTrip? {
        guard let tripID else { return nil }
        return cache[tripID]
    }

    public var cachedCount: Int { cache.count }
    public var absentCount: Int { absent.count }

    /// Brings the cache up to date with a new snapshot.
    ///
    /// Anything already cached is left alone. Anything unknown is looked up, and
    /// whatever the store does not have yet is handed to hydration; those vehicles
    /// draw from the feed's own labels in the meantime.
    public func observe(_ vehicles: [Vehicle]) async {
        let running = Set(vehicles.compactMap(\.gtfsTripID))
        let unknown = running.subtracting(cache.keys).subtracting(absent)

        if !unknown.isEmpty {
            var found = 0
            for tripID in unknown {
                guard let resolved = await source.resolved(tripID: tripID) else { continue }
                cache[tripID] = resolved
                found += 1
            }
            if found > 0 { revision &+= 1 }

            // Whatever the store could not answer goes to hydration. It is not
            // recorded as absent here: absence is only known once a read has
            // actually happened, which the source reports next time round.
            let stillMissing = unknown.subtracting(cache.keys)
            if !stillMissing.isEmpty {
                await source.request(trips: stillMissing)
            }
        }

        evictIfNeeded(keeping: running)
    }

    /// Re-reads trips whose details were incomplete — a route line that had not
    /// been hydrated when it was first cached.
    public func refreshIncomplete() async {
        let incomplete = cache.values.filter { !$0.hasPath }.map(\.tripID)
        guard !incomplete.isEmpty else { return }
        var changed = false
        for tripID in incomplete {
            guard let resolved = await source.resolved(tripID: tripID), resolved.hasPath else { continue }
            cache[tripID] = resolved
            changed = true
        }
        if changed { revision &+= 1 }
    }

    /// Marks a trip as one the timetable will never contain.
    public func markAbsent(_ tripID: String) {
        absent.insert(tripID)
    }

    private func evictIfNeeded(keeping running: Set<String>) {
        guard cache.count > Self.softLimit else { return }
        cache = cache.filter { running.contains($0.key) }
        absent = absent.intersection(running)
    }
}
