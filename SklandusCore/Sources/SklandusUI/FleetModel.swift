import Foundation
import Observation
import SklandusKit

/// The live fleet, and everything the interface reads about it.
///
/// Derived values are computed once per snapshot and stored, never as computed
/// properties. SwiftUI re-evaluates those on every render pass, and walking ~390
/// vehicles each time was measured in the spike at 20% CPU on its own.
@MainActor
@Observable
public final class FleetModel {

    // MARK: - Feed state

    public private(set) var vehicles: [Vehicle] = []
    public private(set) var status: FeedStatus = .connecting
    public private(set) var lastUpdate: Date?
    /// Bumped on every accepted snapshot, so views can tell "new data" from "same
    /// data, rendered again" without comparing arrays.
    public private(set) var snapshotToken = 0

    // MARK: - Derived once per snapshot

    /// Vehicles running a scheduled trip. The right denominator for any ratio: the
    /// rest are heading to or from depots and can never match a timetable.
    public private(set) var inServiceCount = 0
    /// Share of in-service vehicles within a minute of their timetable.
    public private(set) var onTimePercentage: Double?
    private var modeCounts: [TransitMode: Int] = [:]

    public func count(of mode: TransitMode) -> Int { modeCounts[mode] ?? 0 }

    // MARK: - Diagnostics

    public private(set) var pollCount = 0
    /// Polls the server answered 304 — bandwidth not spent.
    public private(set) var unchangedCount = 0
    /// Rows the parser rejected. Persistently non-zero means the feed's shape moved.
    public private(set) var skippedRows = 0

    private let pollInterval: TimeInterval
    private var client: VehicleFeedClient?
    private var pumpTask: Task<Void, Never>?

    public init(pollInterval: TimeInterval = 5) {
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    public func start() {
        guard pumpTask == nil else { return }
        let client = VehicleFeedClient(pollInterval: .seconds(Int(pollInterval)))
        self.client = client
        pumpTask = Task { [weak self] in
            for await event in await client.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        let client = self.client
        self.client = nil
        Task { await client?.stop() }
    }

    // MARK: - Events

    /// Exposed so tests can drive the model without a network.
    func handle(_ event: VehicleFeedClient.Event) {
        pollCount += 1
        switch event {
        case .snapshot(let snapshot):
            apply(snapshot)
        case .unchanged:
            unchangedCount += 1
            status = .unchanged
        case .offline:
            status = .offline
        case .failure(let message):
            status = .failing(message)
        }
    }

    private func apply(_ snapshot: VehicleFeedClient.Snapshot) {
        vehicles = snapshot.vehicles
        lastUpdate = snapshot.receivedAt
        skippedRows = snapshot.skippedRows
        snapshotToken &+= 1
        status = .live
        recomputeDerived()
    }

    /// One pass over the fleet producing everything the interface reads.
    private func recomputeDerived() {
        var counts: [TransitMode: Int] = [:]
        var scheduled = 0
        var onTime = 0

        for vehicle in vehicles {
            counts[vehicle.mode, default: 0] += 1
            guard vehicle.isInService else { continue }
            scheduled += 1
            if vehicle.punctuality == .onTime { onTime += 1 }
        }

        modeCounts = counts
        inServiceCount = scheduled
        onTimePercentage = scheduled > 0 ? Double(onTime) / Double(scheduled) * 100 : nil
    }
}
