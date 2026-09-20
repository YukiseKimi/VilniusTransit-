import Testing
import Foundation
import SwiftData
@testable import SklandusKit

@Suite("Hydration queue")
struct HydrationQueueTests {

    /// A queue, its store, and the temporary directory to clean up afterwards.
    private struct Harness {
        let queue: HydrationQueue
        let store: TimetableStore
        let directory: URL
    }

    /// A store in memory and a cache seeded from the fixture, so nothing touches
    /// the network or the real archive directory.
    private func makeQueue() throws -> Harness {
        let schema = Schema([
            StoredRoute.self, StoredStation.self, StoredTrip.self,
            StoredShape.self, StoredCatalogMeta.self
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = TimetableStore(modelContainer: container)

        let directory = URL.temporaryDirectory.appending(path: "sklandus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try #require(
            Bundle.module.url(forResource: "gtfs_sample", withExtension: "zip", subdirectory: "Fixtures")
        )
        try Data(contentsOf: fixture).write(to: directory.appending(path: "timetable.zip"))

        let cache = ArchiveCache(directory: directory)
        return Harness(
            queue: HydrationQueue(store: store, archives: cache),
            store: store,
            directory: directory
        )
    }

    private func importCatalog(into store: TimetableStore) async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "gtfs_sample", withExtension: "zip", subdirectory: "Fixtures")
        )
        let archive = try GTFSArchive(data: try Data(contentsOf: fixture))
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
    }

    @Test("requested trips are gathered, then hydrated in one pass")
    func gathersThenHydrates() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        // Two separate requests, as two polls would produce.
        await queue.request(trips: ["A7-01-6-260901-ba-1300"])
        await queue.request(trips: ["T2-13-6-260907-ba-1320"])
        #expect(await queue.pendingCount == 2)

        await queue.flush()
        #expect(await queue.pendingCount == 0)
        #expect(try await store.counts().trips == 2)
    }

    @Test("trips already stored are never requested again")
    func skipsStoredTrips() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        await queue.request(trips: ["A7-01-6-260901-ba-1300"])
        await queue.flush()

        await queue.request(trips: ["A7-01-6-260901-ba-1300"])
        #expect(await queue.pendingCount == 0)
    }

    /// A vehicle on a layover movement appears in every poll. Without remembering
    /// that its trip is not in the archive, each poll would trigger another scan.
    @Test("a trip the archive lacks is asked for once, then remembered as absent")
    func remembersAbsentTrips() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        await queue.request(trips: ["A50-02-6-260901-aa1-1030"])
        #expect(await queue.pendingCount == 1)
        await queue.flush()

        #expect(await queue.absentCount == 1)
        await queue.request(trips: ["A50-02-6-260901-aa1-1030"])
        #expect(await queue.pendingCount == 0)
    }

    @Test("a mixed request hydrates what exists and remembers what does not")
    func mixedRequest() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        await queue.request(trips: ["A7-01-6-260901-ba-1300", "A50-02-6-260901-aa1-1030"])
        await queue.flush()

        #expect(try await store.counts().trips == 1)
        #expect(await queue.absentCount == 1)
    }

    @Test("flushing with nothing pending does no work")
    func emptyFlush() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        await queue.flush()
        #expect(try await store.counts().trips == 0)
    }

    /// The window is what turns a burst of misses into a single archive scan.
    @Test("requests inside the window are served by one flush")
    func coalescesWithinWindow() async throws {
        let harness = try makeQueue()
        let (queue, store) = (harness.queue, harness.store)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try await importCatalog(into: store)

        for trip in ["A7-01-6-260901-ba-1300", "A7-02-6-260901-ba-1400", "T2-13-6-260907-ba-1320"] {
            await queue.request(trips: [trip])
        }
        #expect(await queue.pendingCount == 3)
        await queue.flush()
        #expect(try await store.counts().trips == 3)
        // Two of those share a shape, so only two shapes were read.
        #expect(try await store.counts().shapes == 2)
    }
}
