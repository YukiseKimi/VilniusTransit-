import Foundation
import CoreLocation
import Observation
import VilniusTransitKit

/// Owns the live fleet and the user's filters. The map owns motion; this owns data.
@MainActor
@Observable
public final class FleetModel {

    public init() {}

    /// What the static timetable is doing, shown in the status bar so a failed or
    /// still-loading catalog is visible rather than silently degrading the map.
    public enum CatalogStatus: Equatable {
        case loading
        case ready(trips: Int, shapes: Int, fromCache: Bool)
        case failed(String)
    }

    public enum Status: Equatable {
        case idle
        case live
        case unchanged
        case offline
        case failing(String)
    }

    // Feed state
    public private(set) var vehicles: [Vehicle] = []
    public private(set) var status: Status = .idle
    public private(set) var lastUpdate: Date?
    public private(set) var lastByteCount = 0
    public private(set) var skippedRows = 0
    /// How many polls the server answered 304 — i.e. bandwidth the app did not spend.
    public private(set) var notModifiedCount = 0
    public private(set) var pollCount = 0
    /// Bumped on every accepted snapshot; the map uses it to skip redundant work.
    public private(set) var snapshotToken = 0

    // Static timetable
    public private(set) var catalog: GTFSCatalog = .empty
    public private(set) var catalogStatus: CatalogStatus = .loading
    /// Bumped when the catalog arrives so the map re-resolves every annotation.
    public private(set) var catalogToken = 0

    // Filters. Each recomputes derived state once, rather than leaving O(n) work
    // in computed properties that SwiftUI re-evaluates on every body pass.
    public var enabledModes: Set<TransitMode> = Set(TransitMode.allCases) { didSet { recompute() } }
    public var showOutOfService = true { didSet { recompute() } }
    public var routeQuery = "" { didSet { recomputeRoutes() } }
    public var selectedRoute: String? { didSet { recompute() } }
    public var selectedFleetNumber: String?

    // Derived state, recomputed when data or filters move — never per render.
    public private(set) var filteredVehicles: [Vehicle] = []
    public private(set) var routeSummaries: [RouteSummary] = []
    public private(set) var joinedCount = 0
    public private(set) var onTimePercentage: Double?
    private var modeCounts: [TransitMode: Int] = [:]

    public let pollInterval: TimeInterval = 5

    private var client: VehicleFeedClient?
    private var pumpTask: Task<Void, Never>?
    private let gtfs = GTFSStore()
    private var catalogTask: Task<Void, Never>?

    // MARK: - Derived

    /// Identifies (data, filters) so the map re-ingests when either moves.
    public var dataToken: Int {
        var hasher = Hasher()
        hasher.combine(snapshotToken)
        hasher.combine(catalogToken)
        hasher.combine(enabledModes)
        hasher.combine(showOutOfService)
        hasher.combine(selectedRoute)
        return hasher.finalize()
    }

    public var selectedVehicle: Vehicle? {
        guard let selectedFleetNumber else { return nil }
        return vehicles.first { $0.id == selectedFleetNumber }
    }

    public func count(of mode: TransitMode) -> Int { modeCounts[mode] ?? 0 }

    public func resolved(_ vehicle: Vehicle) -> GTFSRoute? { catalog.route(forVehicle: vehicle) }

    public func shape(for vehicle: Vehicle) -> [CLLocationCoordinate2D]? {
        guard let tripID = vehicle.gtfsTripID else { return nil }
        return catalog.shape(forTrip: tripID)
    }

    /// Stations this vehicle's current trip calls at, in order.
    public func stations(for vehicle: Vehicle) -> [GTFSStation] {
        guard let tripID = vehicle.gtfsTripID else { return [] }
        return catalog.stations(forTrip: tripID)
    }

    public struct RouteSummary: Identifiable, Hashable {
        public var id: String { name }
        public let name: String
        public let mode: TransitMode
        public let vehicleCount: Int
        public let colorHex: String?
        public let longName: String?
    }

    /// One pass over the fleet producing everything the UI reads.
    private func recompute() {
        var filtered: [Vehicle] = []
        filtered.reserveCapacity(vehicles.count)
        var counts: [TransitMode: Int] = [:]
        var joined = 0
        var scheduled = 0
        var onTime = 0

        for vehicle in vehicles {
            counts[vehicle.mode, default: 0] += 1
            if catalog.route(forVehicle: vehicle) != nil { joined += 1 }
            if vehicle.isInService {
                scheduled += 1
                if vehicle.punctuality == .onTime { onTime += 1 }
            }
            guard enabledModes.contains(vehicle.mode) else { continue }
            if !showOutOfService && !vehicle.isInService { continue }
            if let selectedRoute, vehicle.route != selectedRoute { continue }
            filtered.append(vehicle)
        }

        filteredVehicles = filtered
        modeCounts = counts
        joinedCount = joined
        onTimePercentage = scheduled > 0 ? Double(onTime) / Double(scheduled) * 100 : nil
        recomputeRoutes()
    }

    private func recomputeRoutes() {
        struct Accumulator { var mode: TransitMode; var count: Int; var route: GTFSRoute? }
        var counts: [String: Accumulator] = [:]
        for vehicle in vehicles where enabledModes.contains(vehicle.mode) {
            guard !vehicle.route.isEmpty else { continue }
            if var existing = counts[vehicle.route] {
                existing.count += 1
                // Layover movements do not join, so keep the first route that does.
                if existing.route == nil { existing.route = catalog.route(forVehicle: vehicle) }
                counts[vehicle.route] = existing
            } else {
                counts[vehicle.route] = Accumulator(
                    mode: vehicle.mode, count: 1, route: catalog.route(forVehicle: vehicle)
                )
            }
        }

        let query = routeQuery.trimmingCharacters(in: .whitespaces)
        routeSummaries = counts
            .map { name, value in
                RouteSummary(
                    name: name, mode: value.mode, vehicleCount: value.count,
                    colorHex: value.route?.color, longName: value.route?.longName
                )
            }
            // localizedStandardContains ignores case and diacritics, so "zirmunai"
            // finds "Žirmūnai" — which matters for Lithuanian stop names.
            .filter { query.isEmpty || $0.name.localizedStandardContains(query)
                || ($0.longName?.localizedStandardContains(query) ?? false) }
            // Route names are alphanumeric ("7", "3G", "N2"), so sort numerically
            // where possible and fall back to text.
            .sorted { lhs, rhs in
                let l = Int(lhs.name.filter(\.isNumber)) ?? Int.max
                let r = Int(rhs.name.filter(\.isNumber)) ?? Int.max
                return l == r ? lhs.name < rhs.name : l < r
            }
    }

    // MARK: - Lifecycle

    public func loadCatalog() {
        guard catalogTask == nil else { return }
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Cached archive first: the map is fully joined on the first frame
                // instead of after a 4 MB download.
                let loaded = try await self.gtfs.load()
                self.apply(loaded)
                // Then see whether the city has published a newer timetable.
                if loaded.fromCache, let fresh = try await self.gtfs.refresh() {
                    self.apply(fresh)
                }
            } catch {
                self.catalogStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ loaded: GTFSStore.Loaded) {
        catalog = loaded.catalog
        defer { recompute() }
        catalogStatus = .ready(
            trips: loaded.stats.trips,
            shapes: loaded.stats.shapes,
            fromCache: loaded.fromCache
        )
        catalogToken &+= 1
    }

    public func start() {
        loadCatalog()
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
            recompute()
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
