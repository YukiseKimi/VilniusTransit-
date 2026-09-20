import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import SklandusKit

/// A store backed by memory, so tests leave nothing on disk.
private func makeStore() throws -> TimetableStore {
    let schema = Schema([
        StoredRoute.self, StoredStation.self, StoredTrip.self,
        StoredShape.self, StoredCatalogMeta.self
    ])
    let container = try ModelContainer(
        for: schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return TimetableStore(modelContainer: container)
}

private func fixtureArchive() throws -> GTFSArchive {
    let url = try #require(
        Bundle.module.url(forResource: "gtfs_sample", withExtension: "zip", subdirectory: "Fixtures")
    )
    return try GTFSArchive(data: try Data(contentsOf: url))
}

@Suite("Coordinate packing")
struct CoordinateBlobTests {

    @Test("a path survives the round trip intact")
    func roundTrip() {
        let path = [
            CLLocationCoordinate2D(latitude: 54.6872, longitude: 25.2797),
            CLLocationCoordinate2D(latitude: 54.6885, longitude: 25.2799)
        ]
        let decoded = CoordinateBlob.decode(CoordinateBlob.encode(path))
        #expect(decoded.count == 2)
        #expect(decoded[0].latitude == 54.6872)
        #expect(decoded[1].longitude == 25.2799)
    }

    /// 16 bytes a point is what makes one row per shape affordable instead of one
    /// row per point.
    @Test("a point costs 16 bytes")
    func size() {
        let path = Array(repeating: CLLocationCoordinate2D(latitude: 1, longitude: 2), count: 100)
        #expect(CoordinateBlob.encode(path).count == 1600)
    }

    @Test("an empty or partial blob decodes to nothing rather than crashing")
    func degradesSafely() {
        #expect(CoordinateBlob.decode(Data()).isEmpty)
        #expect(CoordinateBlob.decode(Data([1, 2, 3])).isEmpty)
    }
}

@Suite("Timetable store")
struct TimetableStoreTests {

    @Test("importing stores routes and stations in full")
    func importsCatalog() async throws {
        let store = try makeStore()
        try await store.importCatalog(
            from: fixtureArchive(),
            lastModified: "Fri, 11 Sep 2026",
            etag: "v1"
        )
        let counts = try await store.counts()
        #expect(counts.routes == 4)
        #expect(counts.stations == 5)
        // Nothing on-demand is stored yet.
        #expect(counts.trips == 0)
        #expect(counts.shapes == 0)
    }

    @Test("only the requested trips are hydrated")
    func hydratesOnDemand() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")

        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)
        let counts = try await store.counts()
        #expect(counts.trips == 1)
        // Its shape came along, because a trip is not much use without its path.
        #expect(counts.shapes == 1)
    }

    @Test("a hydrated trip resolves to route, path and stops")
    func resolvesTrip() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)

        let resolved = try await #require(store.resolved(tripID: "A7-01-6-260901-ba-1300"))
        #expect(resolved.routeShortName == "7")
        #expect(resolved.routeLongName == "Stotis-Šiaurės miestelis")
        #expect(resolved.routeColor == "0073AC")
        #expect(resolved.path.count == 3)
        #expect(resolved.stationIDs.count == 3)
    }

    /// Before hydration, and for layover movements the timetable never contains,
    /// the answer is nil rather than an error: the vehicle still draws from the
    /// feed's own labels.
    @Test("an unhydrated or absent trip resolves to nil")
    func unknownTripIsNil() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        #expect(try await store.resolved(tripID: "A50-02-6-260901-aa1-1030") == nil)
    }

    @Test("missingTrips reports only what is not stored")
    func reportsMisses() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)

        let missing = try await store.missingTrips(
            from: ["A7-01-6-260901-ba-1300", "T2-13-6-260907-ba-1320"]
        )
        #expect(missing == ["T2-13-6-260907-ba-1320"])
    }

    @Test("two trips sharing a shape store that shape once")
    func sharesShapes() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        // Both of these run shape_7_ba.
        try await store.hydrate(
            trips: ["A7-01-6-260901-ba-1300", "A7-02-6-260901-ba-1400"],
            from: archive
        )
        let counts = try await store.counts()
        #expect(counts.trips == 2)
        #expect(counts.shapes == 1)
    }

    /// Trip ids embed a schedule version, so trips hydrated from an old archive
    /// would quietly stop matching rather than fail loudly.
    @Test("a new archive clears what the old one produced")
    func newArchiveClearsHydratedData() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "old", etag: "1")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)
        #expect(try await store.counts().trips == 1)

        try await store.importCatalog(from: archive, lastModified: "new", etag: "2")
        let counts = try await store.counts()
        #expect(counts.trips == 0)
        #expect(counts.shapes == 0)
        // Routes and stations are replaced, not lost.
        #expect(counts.routes == 4)
    }

    @Test("re-importing the same archive keeps hydrated trips")
    func sameArchiveKeepsHydratedData() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "same", etag: "1")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)

        try await store.importCatalog(from: archive, lastModified: "same", etag: "1")
        #expect(try await store.counts().trips == 1)
    }

    @Test("shapes unused for a week are evicted, with the trips that used them")
    func evictsStaleShapes() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)

        // Nothing is stale yet.
        #expect(try await store.evictStaleShapes() == 0)

        let later = Date().addingTimeInterval(TimetableStore.shapeLifetime + 60)
        #expect(try await store.evictStaleShapes(now: later) == 1)
        let counts = try await store.counts()
        #expect(counts.shapes == 0)
        #expect(counts.trips == 0)
    }

    @Test("stations come back in the order asked for")
    func stationsKeepCallOrder() async throws {
        let store = try makeStore()
        let archive = try fixtureArchive()
        try await store.importCatalog(from: archive, lastModified: "a", etag: "b")
        try await store.hydrate(trips: ["A7-01-6-260901-ba-1300"], from: archive)

        let resolved = try await #require(store.resolved(tripID: "A7-01-6-260901-ba-1300"))
        let stations = try await store.stations(ids: resolved.stationIDs)
        #expect(stations.map(\.id) == resolved.stationIDs)
        #expect(stations.first?.name == "1-asis Lentvaris")
    }
}
