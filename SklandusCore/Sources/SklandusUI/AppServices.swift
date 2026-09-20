import Foundation
import Observation
import SwiftData
import OSLog
import SklandusKit

/// Everything the app runs on, assembled in one place.
///
/// The map depends on `fleet` and `resolver` only; the store, archive cache and
/// hydration queue stay behind them.
@MainActor
@Observable
public final class AppServices {
    private static let log = Logger(subsystem: "com.yukisekimi.sklandus", category: "services")

    public let fleet: FleetModel
    public let resolver: TripResolver
    public private(set) var timetableStatus: TimetableStatus = .loading

    private let store: TimetableStore
    private let archives: ArchiveCache
    private let hydration: HydrationQueue
    private var bootstrapTask: Task<Void, Never>?

    public init(inMemory: Bool = false) {
        let schema = Schema([
            StoredRoute.self, StoredStation.self, StoredTrip.self,
            StoredShape.self, StoredCatalogMeta.self
        ])
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
            )
        } catch {
            // A store that will not open must not take the app down: the feed still
            // carries route numbers and destinations, so the map stays useful.
            Self.log.error("Falling back to an in-memory store: \(error.localizedDescription)")
            // swiftlint:disable:next force_try
            container = try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        let store = TimetableStore(modelContainer: container)
        let archives = ArchiveCache()
        // One queue, shared: it remembers which trips the archive lacks, and two
        // queues would each learn that separately while splitting every batch.
        let hydration = HydrationQueue(store: store, archives: archives)
        self.store = store
        self.archives = archives
        self.hydration = hydration
        self.fleet = FleetModel()
        self.resolver = TripResolver(
            source: TimetableTripSource(store: store, hydration: hydration)
        )
    }

    /// Starts the feed immediately and loads the timetable behind it.
    ///
    /// Order matters: vehicles should appear while the timetable is still arriving,
    /// drawing from the feed's own route numbers until their colours are known.
    public func start() {
        fleet.start()
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { [weak self] in
            await self?.loadTimetable()
        }
    }

    public func stop() {
        fleet.stop()
        bootstrapTask?.cancel()
        bootstrapTask = nil
    }

    /// Brings the resolver up to date with the fleet. Called once per snapshot.
    public func refreshTrips() async {
        await resolver.observe(fleet.vehicles)
        // Trips cached before their shape was hydrated get their path filled in.
        await resolver.refreshIncomplete()
    }

    private func loadTimetable() async {
        do {
            // Disk first so a returning user is joined immediately, network second.
            let archive = try await archives.load()
            try await importIfNeeded(archive)

            if archive.fromCache, let fresh = try await archives.refresh() {
                try await importIfNeeded(fresh)
            }

            let counts = try await store.counts()
            timetableStatus = .ready(routes: counts.routes, stations: counts.stations)
            Self.log.info("Timetable ready: \(counts.routes) routes, \(counts.stations) stations")

            // Housekeeping, once per launch: shapes nobody has looked at in a week.
            _ = try? await store.evictStaleShapes()
        } catch {
            timetableStatus = .failed(error.localizedDescription)
            Self.log.error("Timetable unavailable: \(error.localizedDescription)")
        }
    }

    private func importIfNeeded(_ fetched: ArchiveCache.Fetched) async throws {
        let identity = try await store.archiveIdentity()
        let unchanged = identity?.lastModified == fetched.lastModified
            && identity?.etag == fetched.etag
        let alreadyLoaded = try await store.isCatalogLoaded()
        guard !(unchanged && alreadyLoaded) else { return }

        let archive = try GTFSArchive(data: fetched.data)
        try await store.importCatalog(
            from: archive,
            lastModified: fetched.lastModified,
            etag: fetched.etag
        )
    }
}
