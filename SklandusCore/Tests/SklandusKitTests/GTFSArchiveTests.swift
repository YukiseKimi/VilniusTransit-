import Testing
import Foundation
import CoreLocation
@testable import SklandusKit

private func fixture() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "gtfs_sample", withExtension: "zip", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

private func archive() throws -> GTFSArchive {
    try GTFSArchive(data: fixture())
}

@Suite("ZIP reader")
struct ZIPArchiveTests {

    @Test("lists every entry")
    func listsEntries() throws {
        let zip = try ZIPArchive(data: fixture())
        let names = Set(zip.entries.map(\.name))
        #expect(names == ["routes.txt", "trips.txt", "shapes.txt", "stop_times.txt", "stops.txt", "agency.txt"])
    }

    @Test("inflates a deflated entry")
    func inflatesDeflate() throws {
        let zip = try ZIPArchive(data: fixture())
        let entry = try #require(zip.entry(named: "routes.txt"))
        #expect(entry.method == 8)
        let text = String(decoding: try zip.contents(of: entry), as: UTF8.self)
        #expect(text.contains("Stotis-Šiaurės miestelis"))
    }

    /// Not every entry is compressed; reading a stored one as deflate gives garbage.
    @Test("reads a stored entry")
    func readsStored() throws {
        let zip = try ZIPArchive(data: fixture())
        let entry = try #require(zip.entry(named: "stops.txt"))
        #expect(entry.method == 0)
        #expect(String(decoding: try zip.contents(of: entry), as: UTF8.self).contains("Geležinio Vilko"))
    }

    @Test("a missing entry is nil, not a throw")
    func missingEntry() throws {
        #expect(try ZIPArchive(data: fixture()).contents(of: "frequencies.txt") == nil)
    }

    @Test("rejects data that is not a ZIP")
    func rejectsGarbage() {
        #expect(throws: ZIPArchive.ZIPError.self) {
            _ = try ZIPArchive(data: Data(repeating: 0x41, count: 4096))
        }
    }
}

@Suite("Timetable, loaded in full")
struct GTFSFullLoadTests {

    @Test("routes carry the city's published colours")
    func routes() throws {
        let routes = try archive().routes()
        #expect(routes.count == 4)
        let express = try #require(routes.first { $0.shortName == "7" })
        #expect(express.longName == "Stotis-Šiaurės miestelis")
        #expect(express.color == "0073AC")
        // Trolleybuses use the extended GTFS route type, not 11.
        #expect(routes.first { $0.shortName == "2" }?.routeType == 800)
    }

    @Test("same-named stops within 150 m become one station")
    func groupsDirectionPairs() throws {
        let stations = try archive().stations()
        let pair = try #require(stations.first { $0.name == "Kalvarijų" && $0.platformCount > 1 })
        #expect(pair.platformIDs == ["16292", "16293"])
        // The station sits at the centroid, not on one of its platforms.
        #expect(abs(pair.coordinate.latitude - 54.70009) < 1e-5)
    }

    @Test("same-named stops far apart stay separate places")
    func doesNotOverMerge() throws {
        let kalvariju = try archive().stations().filter { $0.name == "Kalvarijų" }
        #expect(kalvariju.count == 2)
        #expect(kalvariju.contains { $0.platformIDs == ["16294"] })
    }

    @Test("quoting survives into stop descriptions")
    func quoting() throws {
        let stops = try archive().stops()
        #expect(stops.first { $0.id == "16291" }?.detail == "visos kryptys, troleibusai")
        #expect(stops.first { $0.id == "16292" }?.detail == "\"D\" stotelė")
    }
}

@Suite("Timetable, loaded on demand")
struct GTFSOnDemandTests {

    @Test("asking for two trips returns only those two")
    func loadsOnlyRequestedTrips() throws {
        let trips = try archive().trips(ids: ["A7-01-6-260901-ba-1300", "T2-13-6-260907-ba-1320"])
        #expect(trips.count == 2)
        #expect(Set(trips.map(\.id)) == ["A7-01-6-260901-ba-1300", "T2-13-6-260907-ba-1320"])
        #expect(trips.first { $0.id.hasPrefix("A7") }?.shapeID == "shape_7_ba")
    }

    /// Roughly 1–3% of in-service vehicles run layover movements whose trip ids are
    /// GTFS-shaped but absent from the published feed. They must come back empty
    /// rather than throwing, so the vehicle can still be shown from feed labels.
    @Test("an unknown trip id is absent, not an error")
    func unknownTripIsAbsent() throws {
        let trips = try archive().trips(ids: ["A50-02-6-260901-aa1-1030"])
        #expect(trips.isEmpty)
    }

    @Test("asking for nothing reads nothing")
    func emptyRequest() throws {
        #expect(try archive().trips(ids: []).isEmpty)
        #expect(try archive().shapes(ids: []).isEmpty)
        #expect(try archive().stopLists(forShapes: [], stations: []).isEmpty)
    }

    @Test("shape points come back ordered by sequence, not file order")
    func shapesAreOrdered() throws {
        let shapes = try archive().shapes(ids: ["shape_7_ba"])
        let path = try #require(shapes["shape_7_ba"])
        #expect(path.count == 3)
        #expect(path.map(\.latitude) == [54.6872, 54.6885, 54.6900])
    }

    @Test("only the requested shapes are decoded")
    func loadsOnlyRequestedShapes() throws {
        let shapes = try archive().shapes(ids: ["shape_2_ba"])
        #expect(Set(shapes.keys) == ["shape_2_ba"])
    }

    @Test("stop lists are ordered, and a station reached twice appears once")
    func stopLists() throws {
        let archive = try archive()
        let stations = try archive.stations()
        let lists = try archive.stopLists(forShapes: ["shape_7_ba"], stations: stations)
        let names = try #require(lists["shape_7_ba"]).compactMap { id in
            stations.first { $0.id == id }?.name
        }
        #expect(names == ["1-asis Lentvaris", "Kalvarijų", "Geležinio Vilko st."])
    }

    /// Every trip sharing a shape calls at the same stops, so only one trip per
    /// shape is read out of a 504k-row file. In the fixture the other two trips on
    /// this shape carry deliberately wrong stop rows; if they were ever read, this
    /// fails.
    @Test("one representative trip per shape, chosen deterministically")
    func representativeIsLowestTripID() throws {
        let archive = try archive()
        let representatives = try archive.representativeTrips(forShapes: ["shape_7_ba"])
        #expect(representatives["shape_7_ba"] == "A7-01-6-260901-ba-1300")

        let stations = try archive.stations()
        let first = try archive.stopLists(forShapes: ["shape_7_ba"], stations: stations)
        for _ in 0..<3 {
            #expect(try archive.stopLists(forShapes: ["shape_7_ba"], stations: stations) == first)
        }
    }

    @Test("a trip with no shape has no path and no stops")
    func tripWithoutShape() throws {
        let archive = try archive()
        let trip = try #require(try archive.trips(ids: ["AL1-01-1-260901-ab-0820"]).first)
        #expect(trip.shapeID == nil)
        #expect(try archive.shapes(ids: ["shape_does_not_exist"]).isEmpty)
    }
}
