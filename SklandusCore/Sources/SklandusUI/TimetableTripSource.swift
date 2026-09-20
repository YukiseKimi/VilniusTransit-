import Foundation
import SklandusKit

/// A `TripSource` backed by the stored timetable.
public struct TimetableTripSource: TripSource {
    private let store: TimetableStore
    private let hydration: HydrationQueue

    public init(store: TimetableStore, hydration: HydrationQueue) {
        self.store = store
        self.hydration = hydration
    }

    public func resolved(tripID: String) async -> ResolvedTrip? {
        try? await store.resolved(tripID: tripID)
    }

    public func request(trips: Set<String>) async {
        await hydration.request(trips: trips)
    }
}
