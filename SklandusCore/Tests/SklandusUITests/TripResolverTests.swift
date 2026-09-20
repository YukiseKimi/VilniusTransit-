import Testing
import Foundation
import CoreLocation
@testable import SklandusUI
@testable import SklandusKit

/// A stand-in for the stored timetable that records what was asked of it.
private actor FakeTripSource: TripSource {
    private var stored: [String: ResolvedTrip]
    private(set) var lookups: [String] = []
    private(set) var requested: Set<String> = []

    init(stored: [String: ResolvedTrip] = [:]) {
        self.stored = stored
    }

    func resolved(tripID: String) async -> ResolvedTrip? {
        lookups.append(tripID)
        return stored[tripID]
    }

    func request(trips: Set<String>) async {
        requested.formUnion(trips)
    }

    /// Simulates hydration completing between polls.
    func store(_ trip: ResolvedTrip) {
        stored[trip.tripID] = trip
    }

    func lookupCount(for tripID: String) -> Int {
        lookups.count { $0 == tripID }
    }
}

private func trip(_ id: String, route: String = "7", path: Int = 3) -> ResolvedTrip {
    ResolvedTrip(
        tripID: id,
        headsign: "Test",
        routeShortName: route,
        routeLongName: "Somewhere–Elsewhere",
        routeColor: "0073AC",
        routeType: 3,
        path: Array(
            repeating: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            count: path
        ),
        stationIDs: ["a", "b"]
    )
}

private func vehicle(_ id: String, tripID: String?) -> Vehicle {
    Vehicle(
        id: id, mode: .bus, route: "7",
        coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
        speed: 20, heading: 90, deviationSeconds: 0,
        measuredAtSecondsSinceMidnight: 48000, headsign: "Test",
        gtfsTripID: tripID, vehicleTypeCode: "KWZ"
    )
}

@MainActor
@Suite("Trip resolver")
struct TripResolverTests {

    @Test("a stored trip is cached and then read without touching the source")
    func cachesLookups() async {
        let source = FakeTripSource(stored: ["A7-01": trip("A7-01")])
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: "A7-01")])
        #expect(resolver.resolved("A7-01")?.routeShortName == "7")
        #expect(await source.lookupCount(for: "A7-01") == 1)

        // Three more polls with the same vehicle, as a five-second cycle produces.
        for _ in 0..<3 {
            await resolver.observe([vehicle("1", tripID: "A7-01")])
        }
        #expect(await source.lookupCount(for: "A7-01") == 1)
    }

    /// The whole point: ~390 vehicles a poll must not become ~390 store reads.
    @Test("many vehicles on one trip cost a single lookup")
    func sharesLookupsAcrossVehicles() async {
        let source = FakeTripSource(stored: ["A7-01": trip("A7-01")])
        let resolver = TripResolver(source: source)

        let fleet = (1...50).map { vehicle("\($0)", tripID: "A7-01") }
        await resolver.observe(fleet)
        #expect(await source.lookupCount(for: "A7-01") == 1)
    }

    @Test("a trip the store lacks is handed to hydration")
    func requestsMissingTrips() async {
        let source = FakeTripSource()
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: "A7-99")])
        #expect(resolver.resolved("A7-99") == nil)
        #expect(await source.requested == ["A7-99"])
    }

    @Test("once hydrated, the trip resolves on the next snapshot")
    func picksUpHydratedTrips() async {
        let source = FakeTripSource()
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: "A7-99")])
        #expect(resolver.resolved("A7-99") == nil)

        await source.store(trip("A7-99", route: "99"))
        await resolver.observe([vehicle("1", tripID: "A7-99")])
        #expect(resolver.resolved("A7-99")?.routeShortName == "99")
    }

    /// A vehicle on a layover movement appears in every poll for hours.
    @Test("a trip marked absent is never looked up again")
    func absentTripsAreNotRetried() async {
        let source = FakeTripSource()
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: "A50-xd")])
        resolver.markAbsent("A50-xd")
        await resolver.observe([vehicle("1", tripID: "A50-xd")])
        await resolver.observe([vehicle("1", tripID: "A50-xd")])

        #expect(await source.lookupCount(for: "A50-xd") == 1)
        #expect(resolver.absentCount == 1)
    }

    @Test("a vehicle with no trip is ignored rather than looked up")
    func ignoresVehiclesWithoutTrips() async {
        let source = FakeTripSource()
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: nil)])
        #expect(await source.lookups.isEmpty)
        #expect(resolver.resolved(nil) == nil)
    }

    @Test("the revision moves only when the cache actually gains something")
    func revisionTracksRealChanges() async {
        let source = FakeTripSource(stored: ["A7-01": trip("A7-01")])
        let resolver = TripResolver(source: source)
        #expect(resolver.revision == 0)

        await resolver.observe([vehicle("1", tripID: "A7-01")])
        #expect(resolver.revision == 1)

        await resolver.observe([vehicle("1", tripID: "A7-01")])
        #expect(resolver.revision == 1)
    }

    /// A trip can be cached before its shape has been hydrated, leaving a vehicle
    /// with a route name but no line to draw.
    @Test("a trip cached without its path is re-read once the path arrives")
    func refreshesIncompleteTrips() async {
        let empty = ResolvedTrip(
            tripID: "A7-01", headsign: "Test", routeShortName: "7", routeLongName: "",
            routeColor: "0073AC", routeType: 3, path: [], stationIDs: []
        )
        let source = FakeTripSource(stored: ["A7-01": empty])
        let resolver = TripResolver(source: source)

        await resolver.observe([vehicle("1", tripID: "A7-01")])
        #expect(resolver.resolved("A7-01")?.hasPath == false)

        await source.store(trip("A7-01"))
        await resolver.refreshIncomplete()
        #expect(resolver.resolved("A7-01")?.hasPath == true)
    }

    @Test("the cache is trimmed to the running fleet once it grows large")
    func evictsWhenLarge() async {
        var stored: [String: ResolvedTrip] = [:]
        for index in 0..<1600 { stored["T\(index)"] = trip("T\(index)") }
        let source = FakeTripSource(stored: stored)
        let resolver = TripResolver(source: source)

        await resolver.observe((0..<1600).map { vehicle("v\($0)", tripID: "T\($0)") })
        #expect(resolver.cachedCount == 1600)

        // A later snapshot with only a handful running.
        await resolver.observe((0..<3).map { vehicle("v\($0)", tripID: "T\($0)") })
        #expect(resolver.cachedCount == 3)
    }
}
