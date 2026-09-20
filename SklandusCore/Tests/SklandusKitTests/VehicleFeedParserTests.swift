import Testing
import Foundation
import CoreLocation
@testable import SklandusKit

@Suite("gps_full.txt parser")
struct VehicleFeedParserTests {

    /// A real capture from the live feed, header and all.
    static func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "gps_full_sample", withExtension: "txt", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test("parses every data row and skips none")
    func parsesFixture() throws {
        let data = try Self.fixture()
        let result = VehicleFeedParser.parse(data)
        #expect(result.skippedRows == 0)
        #expect(result.vehicles.count == 40)  // 41 lines minus the header
    }

    @Test("header row is not treated as a vehicle")
    func skipsHeader() {
        let result = VehicleFeedParser.parse(text: """
        Transportas,Marsrutas,ReisoID,MasinosNumeris,Ilguma,Platuma,Greitis,Azimutas,ReisoPradziaMinutemis,NuokrypisSekundemis,MatavimoLaikas,MasinosTipas,KryptiesTipas,KryptiesPavadinimas,ReisoIdGTFS,IntervalasPries,IntervalasPaskui,
        """)
        #expect(result.vehicles.isEmpty)
        #expect(result.skippedRows == 0)
    }

    @Test("decodes a trolleybus row into real units")
    func decodesTrolleybus() throws {
        let row = "Troleibusai,1,27221541243,2770,25205915,54684770,11,344,763,84,48685,KWNZ,B>A,Karoliniškės,T1-02-6-260901-ab-1330,2381,2315,"
        let vehicle = try #require(VehicleFeedParser.parse(text: row).vehicles.first)

        #expect(vehicle.id == "2770")
        #expect(vehicle.mode == .trolleybus)
        #expect(vehicle.mode.gtfsRouteType == 800)
        #expect(vehicle.route == "1")
        // x1e6 scaling, and longitude/latitude are NOT in the column order you expect.
        #expect(abs(vehicle.coordinate.longitude - 25.205915) < 1e-9)
        #expect(abs(vehicle.coordinate.latitude - 54.684770) < 1e-9)
        #expect(vehicle.speed == 11)
        #expect(vehicle.heading == 344)
        #expect(vehicle.deviationSeconds == 84)
        #expect(vehicle.punctuality == .late)
        #expect(vehicle.headsign == "Karoliniškės")
        #expect(vehicle.gtfsTripID == "T1-02-6-260901-ab-1330")
        #expect(vehicle.isInService)
    }

    @Test("a deadheading vehicle has no trip and no deviation")
    func handlesEmptyTripID() throws {
        let row = "Autobusai,1G,,4163,25292878,54720649,0,346,,,48550,KWZD,B>D,Autobusų parkas (Verkių g.),,,,"
        let vehicle = try #require(VehicleFeedParser.parse(text: row).vehicles.first)

        #expect(vehicle.gtfsTripID == nil)
        #expect(vehicle.isInService == false)
        #expect(vehicle.deviationSeconds == nil)
        #expect(vehicle.punctuality == .unknown)
        // Empty is not zero: the vehicle really is at the depot, not on time.
        #expect(vehicle.headsign == "Autobusų parkas (Verkių g.)")
    }

    @Test("ferries decode as their own mode")
    func decodesFerry() throws {
        let data = try Self.fixture()
        let ferries = VehicleFeedParser.parse(data).vehicles.filter { $0.mode == .ferry }
        #expect(!ferries.isEmpty)
        #expect(ferries.allSatisfy { $0.mode.gtfsRouteType == 4 })
    }

    @Test("malformed rows are dropped, not fatal", arguments: [
        "",                                   // blank
        "Metro,1,,999,25200000,54680000,0,0,,,100,K,A>B,Nowhere,,,,",   // unknown mode
        "Autobusai,1,,999,notanumber,54680000,0,0,,,100,K,A>B,X,,,,",   // bad coordinate
        "Autobusai,1,,,25200000,54680000,0,0,,,100,K,A>B,X,,,,",        // no fleet number
        "Autobusai,1,,999",                                             // truncated
        "Autobusai,1,,999,0,0,0,0,,,100,K,A>B,X,,,,"                    // null island
    ])
    func rejectsBadRows(_ row: String) {
        #expect(VehicleFeedParser.parse(text: row).vehicles.isEmpty)
    }

    @Test("one bad row does not cost the good ones")
    func isolatesBadRows() {
        let good = "Autobusai,7,27218471303,8008,25292544,54716455,0,62,783,-39,48687,KWZ,B>A,Šiaurės miestelis,A7-01-6-260901-ba-1300,264,1450,"
        let result = VehicleFeedParser.parse(text: "\(good)\nGARBAGE\n\(good.replacingOccurrences(of: "8008", with: "8009"))")
        #expect(result.vehicles.count == 2)
        #expect(result.skippedRows == 1)
    }

    @Test("negative deviation means running early")
    func signedDeviation() throws {
        let row = "Autobusai,7,27218471303,8008,25292544,54716455,0,62,783,-390,48687,KWZ,B>A,Šiaurės miestelis,A7-01-6-260901-ba-1300,264,1450,"
        let vehicle = try #require(VehicleFeedParser.parse(text: row).vehicles.first)
        #expect(vehicle.deviationSeconds == -390)
        #expect(vehicle.punctuality == .early)
    }

    @Test("CRLF line endings parse identically to LF")
    func toleratesCRLF() {
        let row = "Autobusai,7,27218471303,8008,25292544,54716455,0,62,783,-39,48687,KWZ,B>A,Test,A7-01,264,1450,"
        #expect(VehicleFeedParser.parse(text: "\(row)\r\n").vehicles.count == 1)
    }

    @Test("feed clock renders in Vilnius wall time, including past midnight")
    func clockFormatting() {
        #expect(FeedClock.clockString(secondsSinceMidnight: 48685) == "13:31:25")
        #expect(FeedClock.clockString(secondsSinceMidnight: 0) == "00:00:00")
        // GTFS service days run past 24:00 for night buses.
        #expect(FeedClock.clockString(secondsSinceMidnight: 90000) == "01:00:00")
    }
}
