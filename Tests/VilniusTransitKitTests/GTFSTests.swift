import Testing
import Foundation
import CoreLocation
@testable import VilniusTransitKit

private func fixtureArchive() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "gtfs_sample", withExtension: "zip", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

@Suite("ZIP reader")
struct ZIPArchiveTests {

    @Test("lists every entry with its sizes")
    func listsEntries() throws {
        let archive = try ZIPArchive(data: fixtureArchive())
        let names = Set(archive.entries.map(\.name))
        #expect(names == ["routes.txt", "trips.txt", "shapes.txt", "stop_times.txt", "stops.txt", "agency.txt"])
    }

    @Test("inflates a deflated entry")
    func inflatesDeflate() throws {
        let archive = try ZIPArchive(data: fixtureArchive())
        let entry = try #require(archive.entry(named: "routes.txt"))
        #expect(entry.method == 8)
        let text = String(decoding: try archive.contents(of: entry), as: UTF8.self)
        #expect(text.contains("Stotis-Šiaurės miestelis"))
        #expect(try archive.contents(of: entry).count == entry.uncompressedSize)
    }

    /// Not every entry is compressed — a small or already-dense file is often
    /// STORED, and reading it as deflate would produce garbage.
    @Test("reads a stored (uncompressed) entry")
    func readsStored() throws {
        let archive = try ZIPArchive(data: fixtureArchive())
        let entry = try #require(archive.entry(named: "stops.txt"))
        #expect(entry.method == 0)
        let text = String(decoding: try archive.contents(of: entry), as: UTF8.self)
        #expect(text.contains("Geležinio Vilko"))
    }

    @Test("a missing entry is nil, not a throw")
    func missingEntry() throws {
        let archive = try ZIPArchive(data: fixtureArchive())
        #expect(try archive.contents(of: "frequencies.txt") == nil)
    }

    @Test("rejects data that is not a ZIP")
    func rejectsGarbage() {
        #expect(throws: ZIPArchive.ZIPError.self) {
            _ = try ZIPArchive(data: Data(repeating: 0x41, count: 4096))
        }
    }
}

@Suite("GTFS CSV")
struct GTFSCSVTests {

    private func csv(_ text: String) throws -> GTFSCSV { try GTFSCSV(Data(text.utf8)) }

    @Test("strips the UTF-8 BOM from the first column name")
    func stripsBOM() throws {
        let parsed = try csv("\u{FEFF}route_id,route_type\nabc,3\n")
        #expect(parsed.columns == ["route_id", "route_type"])
        // Without stripping, index(of:) silently returns nil forever.
        #expect(parsed.index(of: "route_id") == 0)
    }

    @Test("a quoted field may contain commas")
    func quotedCommas() throws {
        let parsed = try csv("a,b,c\n1,\"visos kryptys, troleibusai\",3\n")
        var captured: [String] = []
        parsed.forEachRow { captured = [$0.string(0), $0.string(1), $0.string(2)] }
        #expect(captured == ["1", "visos kryptys, troleibusai", "3"])
    }

    @Test("doubled quotes collapse to one")
    func escapedQuotes() throws {
        let parsed = try csv("a,b\n1,\"\"\"D\"\" stotelė\"\n")
        var value = ""
        parsed.forEachRow { value = $0.string(1) }
        #expect(value == "\"D\" stotelė")
    }

    @Test("CRLF and LF both terminate a row")
    func lineEndings() throws {
        let parsed = try csv("a,b\r\n1,2\r\n3,4\n")
        var rows: [[String]] = []
        parsed.forEachRow { rows.append([$0.string(0), $0.string(1)]) }
        #expect(rows == [["1", "2"], ["3", "4"]])
    }

    @Test("an empty quoted field is empty, not a quote character")
    func emptyQuoted() throws {
        let parsed = try csv("a,b\n1,\"\"\n")
        var isEmpty = false
        var value = "x"
        parsed.forEachRow { isEmpty = $0.isEmpty(1); value = $0.string(1) }
        #expect(isEmpty)
        #expect(value.isEmpty)
    }

    @Test("a trailing newline does not produce a phantom row")
    func noPhantomRow() throws {
        let parsed = try csv("a,b\n1,2\n")
        var count = 0
        parsed.forEachRow { _ in count += 1 }
        #expect(count == 1)
    }

    @Test("missing columns fail loudly and name what is missing")
    func missingColumns() throws {
        let parsed = try csv("route_id,route_type\nabc,3\n")
        #expect(throws: GTFSCSV.CSVError.self) {
            _ = try parsed.indices(of: ["route_id", "shape_id", "trip_headsign"])
        }
    }

    @Test("numeric accessors reject non-numeric text rather than returning zero")
    func numericAccessors() throws {
        let parsed = try csv("i,d,bad,empty\n-42,54.6872,abc,\n")
        parsed.forEachRow { row in
            #expect(row.int(0) == -42)
            #expect(row.double(1) == 54.6872)
            #expect(row.int(2) == nil)
            #expect(row.double(3) == nil)
        }
    }
}

@Suite("GTFS decoding")
struct GTFSDecoderTests {

    @Test("decodes the archive, inflating only what it needs")
    func decodesAndSkips() throws {
        let (catalog, stats) = try GTFSDecoder.decode(archive: fixtureArchive())
        #expect(stats.routes == 4)
        #expect(stats.trips == 5)
        #expect(stats.stops == 6)
        #expect(stats.stations == 5)
        // stop_times is inflated but discarded down to one stop list per shape;
        // agency.txt is never touched at all.
        #expect(stats.skippedFiles == ["agency.txt"])
        #expect(catalog.trips["A7-01-6-260901-ba-1300"] != nil)
    }

    /// GTFS makes no promise about row order, and drawing shape points as they
    /// appear would zigzag the polyline across the city.
    @Test("shape points are ordered by sequence, not file order")
    func sortsShapePoints() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        let shape = try #require(catalog.shapes["shape_7_ba"])
        #expect(shape.count == 3)
        #expect(shape.map { $0.latitude } == [54.6872, 54.6885, 54.6900])
    }

    @Test("the live trip ID joins through to route, colour and shape")
    func joinsLiveTripToRoute() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        let vehicle = Vehicle(
            id: "8008", mode: .bus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            speed: 30, heading: 90, deviationSeconds: 12,
            measuredAtSecondsSinceMidnight: 48000, headsign: "Šiaurės miestelis",
            gtfsTripID: "A7-01-6-260901-ba-1300", vehicleTypeCode: "KWZ"
        )
        let route = try #require(catalog.route(forVehicle: vehicle))
        #expect(route.shortName == "7")
        #expect(route.longName == "Stotis-Šiaurės miestelis")
        #expect(route.color == "0073AC")
        #expect(catalog.shape(forTrip: "A7-01-6-260901-ba-1300")?.count == 3)
    }

    /// About 1% of in-service vehicles run driver-break and layover movements whose
    /// trip IDs are GTFS-shaped but absent from the published feed (headsigns like
    /// "Pietūs Antakalnio žiede"). They must degrade, not crash.
    @Test("an unknown trip ID yields nil rather than failing")
    func unknownTripDegrades() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        #expect(catalog.trip("A50-02-6-260901-aa1-1030") == nil)
        #expect(catalog.route(forTrip: "A50-02-6-260901-aa1-1030") == nil)
        #expect(catalog.shape(forTrip: "A50-02-6-260901-aa1-1030") == nil)
    }

    @Test("a trip with no shape_id has no polyline but still resolves its route")
    func tripWithoutShape() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        let trip = try #require(catalog.trip("AL1-01-1-260901-ab-0820"))
        #expect(trip.shapeID == nil)
        #expect(catalog.shape(forTrip: trip.id) == nil)
        #expect(catalog.route(forTrip: trip.id)?.routeType == 4)
    }

    @Test("quoting survives the whole pipeline into stop descriptions")
    func stopQuotingRoundTrip() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        #expect(catalog.stops["16291"]?.detail == "visos kryptys, troleibusai")
        #expect(catalog.stops["16292"]?.detail == "\"D\" stotelė")
        #expect(catalog.stops["18327"]?.detail == "")
    }

    @Test("trolleybus routes keep the extended route_type 800")
    func extendedRouteType() throws {
        let (catalog, _) = try GTFSDecoder.decode(archive: fixtureArchive())
        #expect(catalog.routes["vilnius_trolley_2"]?.routeType == 800)
        #expect(catalog.routes["vilnius_trolley_2"]?.color == "DC3131")
    }
}

@Suite("Stations")
struct GTFSStationTests {

    private func catalog() throws -> GTFSCatalog {
        try GTFSDecoder.decode(archive: fixtureArchive()).catalog
    }

    /// Vilnius lists each direction as its own stop — 1,424 of 1,553 share a name
    /// with another — so raw stops put twin dots on every corner.
    @Test("same-named stops within 150 m become one station")
    func groupsDirectionPairs() throws {
        let catalog = try catalog()
        let station = try #require(catalog.stations.first { $0.name == "Kalvarijų" && $0.platformCount > 1 })
        #expect(station.platformIDs == ["16292", "16293"])
        // Centroid of the pair, not one of the platforms.
        #expect(abs(station.coordinate.latitude - 54.70009) < 1e-5)
    }

    @Test("same-named stops far apart stay separate places")
    func doesNotOverMerge() throws {
        let catalog = try catalog()
        let kalvariju = catalog.stations.filter { $0.name == "Kalvarijų" }
        // Three stops share the name; two are a pair, the third is 10 km away.
        #expect(kalvariju.count == 2)
        #expect(kalvariju.contains { $0.platformIDs == ["16294"] })
    }

    @Test("a station id is the lowest-sorting platform, so it is stable")
    func stableStationID() throws {
        let catalog = try catalog()
        let station = try #require(catalog.stations.first { $0.platformCount > 1 })
        #expect(station.id == station.platformIDs.sorted().first)
    }

    @Test("calls are ordered by stop_sequence, not file order")
    func ordersCalls() throws {
        let catalog = try catalog()
        let calls = catalog.stations(forTrip: "A7-01-6-260901-ba-1300")
        #expect(calls.map(\.name) == ["1-asis Lentvaris", "Kalvarijų", "Geležinio Vilko st."])
    }

    /// Sequence 4 returns to the station visited at sequence 2 via its other
    /// platform. One dot on the map, not two.
    @Test("a station reached twice appears once")
    func dedupesRepeatCalls() throws {
        let catalog = try catalog()
        let calls = catalog.stations(forTrip: "A7-01-6-260901-ba-1300")
        #expect(Set(calls.map(\.id)).count == calls.count)
    }

    /// Every trip sharing a shape calls at the same stops, so only one
    /// representative trip per shape is read out of the 504k-row file.
    @Test("trips sharing a shape share its stop list")
    func sharesStopListByShape() throws {
        let catalog = try catalog()
        // N1-01 and A7-02 both use shape_7_ba but neither is its representative;
        // their own stop_times rows (all pointing at one stop) are never read.
        let day = catalog.stations(forTrip: "A7-01-6-260901-ba-1300")
        #expect(day.count == 3)
        for other in ["N1-01-6-260901-ab-0030", "A7-02-6-260901-ba-1400"] {
            #expect(catalog.stations(forTrip: other).map(\.id) == day.map(\.id))
        }
    }

    @Test("a trip with no shape has no calls rather than failing")
    func tripWithoutShapeHasNoCalls() throws {
        let catalog = try catalog()
        #expect(catalog.stations(forTrip: "AL1-01-1-260901-ab-0820").isEmpty)
        #expect(catalog.stations(forTrip: "does-not-exist").isEmpty)
    }

    /// The representative trip per shape was originally taken from unordered
    /// dictionary iteration, so decoding the same archive twice could yield
    /// different stop lists. It is now the lowest-sorting trip id.
    @Test("decoding the same archive twice gives identical stop lists")
    func decodeIsDeterministic() throws {
        let data = try fixtureArchive()
        let first = try GTFSDecoder.decode(archive: data).catalog
        for _ in 0..<5 {
            let again = try GTFSDecoder.decode(archive: data).catalog
            #expect(first.stationsByShape == again.stationsByShape)
            #expect(first.stations.map(\.id) == again.stations.map(\.id))
            #expect(first.stations.map(\.platformIDs) == again.stations.map(\.platformIDs))
        }
    }

    @Test("station lookup by id round-trips")
    func lookupByID() throws {
        let catalog = try catalog()
        let station = try #require(catalog.stations.first)
        #expect(catalog.station(station.id)?.name == station.name)
        #expect(catalog.station("nonsense") == nil)
    }
}

@Suite("HTTP dates")
struct HTTPDateTests {
    /// The exact header stops.lt sends, so a parser regression shows up here and
    /// not as a timetable that silently never refreshes.
    @Test("parses the server's real Last-Modified header")
    func parsesRealHeader() throws {
        let date = try #require(GTFSStore.httpDate("Fri, 11 Sep 2026 18:45:34 GMT"))
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 11)
        #expect(parts.hour == 18)
        #expect(parts.minute == 45)
        #expect(parts.second == 34)
    }

    @Test("rejects anything that is not RFC 1123")
    func rejectsGarbage() {
        #expect(GTFSStore.httpDate("") == nil)
        #expect(GTFSStore.httpDate("2026-09-11T18:45:34Z") == nil)
    }
}
