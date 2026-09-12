import Foundation
import Observation
import VilniusTransitKit

/// Owns the live fleet and the user's filters. The map owns motion; this owns data.
@MainActor
@Observable
final class FleetModel {

    enum Status: Equatable {
        case idle
        case live
        case unchanged
        case offline
        case failing(String)
    }

    // Feed state
    private(set) var vehicles: [Vehicle] = []
    private(set) var status: Status = .idle
    private(set) var lastUpdate: Date?
    private(set) var lastByteCount = 0
    private(set) var skippedRows = 0
    /// How many polls the server answered 304 — i.e. bandwidth the app did not spend.
    private(set) var notModifiedCount = 0
    private(set) var pollCount = 0
    /// Bumped on every accepted snapshot; the map uses it to skip redundant work.
    private(set) var snapshotToken = 0

    // Filters
    var enabledModes: Set<TransitMode> = Set(TransitMode.allCases)
    var showOutOfService = true
    var routeQuery = ""
    var selectedRoute: String?
    var selectedFleetNumber: String?

    let pollInterval: TimeInterval = 5

    private var client: VehicleFeedClient?
    private var pumpTask: Task<Void, Never>?

    // MARK: - Derived

    var filteredVehicles: [Vehicle] {
        vehicles.filter { vehicle in
            guard enabledModes.contains(vehicle.mode) else { return false }
            if !showOutOfService && !vehicle.isInService { return false }
            if let selectedRoute, vehicle.route != selectedRoute { return false }
            return true
        }
    }

    /// Identifies (data, filters) so the map re-ingests when either moves.
    var dataToken: Int {
        var hasher = Hasher()
        hasher.combine(snapshotToken)
        hasher.combine(enabledModes)
        hasher.combine(showOutOfService)
        hasher.combine(selectedRoute)
        return hasher.finalize()
    }

    var selectedVehicle: Vehicle? {
        guard let selectedFleetNumber else { return nil }
        return vehicles.first { $0.id == selectedFleetNumber }
    }

    func count(of mode: TransitMode) -> Int {
        vehicles.reduce(into: 0) { $0 += ($1.mode == mode ? 1 : 0) }
    }

    /// Share of in-service vehicles within a minute of the timetable.
    var onTimePercentage: Double? {
        let scheduled = vehicles.filter(\.isInService)
        guard !scheduled.isEmpty else { return nil }
        let onTime = scheduled.filter { $0.punctuality == .onTime }.count
        return Double(onTime) / Double(scheduled.count) * 100
    }

    struct RouteSummary: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let mode: TransitMode
        let vehicleCount: Int
    }

    var routeSummaries: [RouteSummary] {
        var counts: [String: (TransitMode, Int)] = [:]
        for vehicle in vehicles where enabledModes.contains(vehicle.mode) {
            guard !vehicle.route.isEmpty else { continue }
            counts[vehicle.route, default: (vehicle.mode, 0)].1 += 1
        }
        let query = routeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return counts
            .map { RouteSummary(name: $0.key, mode: $0.value.0, vehicleCount: $0.value.1) }
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            // Route names are alphanumeric ("7", "3G", "N2"), so sort numerically
            // where possible and fall back to text.
            .sorted { lhs, rhs in
                let l = Int(lhs.name.filter(\.isNumber)) ?? Int.max
                let r = Int(rhs.name.filter(\.isNumber)) ?? Int.max
                return l == r ? lhs.name < rhs.name : l < r
            }
    }

    // MARK: - Lifecycle

    func start() {
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

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        let client = self.client
        self.client = nil
        Task { await client?.stop() }
    }

    private func handle(_ event: VehicleFeedClient.Event) {
        pollCount += 1
        switch event {
        case .snapshot(let snapshot):
            vehicles = snapshot.vehicles
            lastUpdate = snapshot.receivedAt
            lastByteCount = snapshot.byteCount
            skippedRows = snapshot.skippedRows
            snapshotToken &+= 1
            status = .live
            // A selected vehicle can leave the feed at the end of its shift.
            if let selectedFleetNumber, !vehicles.contains(where: { $0.id == selectedFleetNumber }) {
                self.selectedFleetNumber = nil
            }
        case .unchanged:
            notModifiedCount += 1
            status = .unchanged
        case .offline:
            status = .offline
        case .failure(let message):
            status = .failing(message)
        }
    }
}
