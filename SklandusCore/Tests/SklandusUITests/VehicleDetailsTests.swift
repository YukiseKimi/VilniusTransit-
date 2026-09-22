import Testing
import CoreLocation
@testable import SklandusUI
@testable import SklandusKit

@Suite("Vehicle details")
struct VehicleDetailsTests {
    private func vehicle(deviation: Int?, speed: Double = 31.6, trip: String? = "T1") -> Vehicle {
        Vehicle(
            id: "1234", mode: .trolleybus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            speed: speed, heading: 90,
            deviationSeconds: deviation,
            measuredAtSecondsSinceMidnight: 48000, headsign: "Feed headsign",
            gtfsTripID: trip, vehicleTypeCode: "KWZ"
        )
    }

    private let trip = ResolvedTrip(
        tripID: "T1", headsign: "Guriai", routeShortName: "33",
        routeLongName: "Stotis – Guriai", routeColor: "0073AC", routeType: 3,
        path: [], stationIDs: ["a"]
    )

    private let station = GTFSStation(
        id: "a", name: "Katedros aikštė",
        coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.28),
        platformIDs: ["a"]
    )

    @Test("the timetable's names win over the feed's labels")
    func prefersTimetable() {
        let details = VehicleDetails(vehicle: vehicle(deviation: 0), trip: trip, stops: [])
        #expect(details.routeName == "33")
        #expect(details.headsign == "Guriai")
        #expect(details.routeLongName == "Stotis – Guriai")
        #expect(details.colorHex == "0073AC")
    }

    @Test("without a trip, the feed's labels are used")
    func fallsBackToFeed() {
        let details = VehicleDetails(vehicle: vehicle(deviation: 0), trip: nil, stops: [])
        #expect(details.routeName == "7")
        #expect(details.headsign == "Feed headsign")
        #expect(details.routeLongName == nil)
    }

    @Test("deviation reads as whole minutes, late or early", arguments: [
        (0, "On time"), (45, "On time"), (-60, "On time"),
        (61, "1 min late"), (150, "3 min late"), (420, "7 min late"),
        (-130, "2 min early")
    ])
    func punctuality(deviation: Int, expected: String) {
        let details = VehicleDetails(vehicle: vehicle(deviation: deviation), trip: trip, stops: [])
        #expect(details.punctualityText == expected)
    }

    @Test("stops are loading until they arrive, and absent between runs")
    func stopStates() {
        let running = vehicle(deviation: 0)
        #expect(VehicleDetails(vehicle: running, trip: trip, stops: []).stops == .loading)
        #expect(VehicleDetails(vehicle: running, trip: trip, stops: [station]).stops == .stops([station]))
        let idle = VehicleDetails(vehicle: vehicle(deviation: nil, trip: nil), trip: nil, stops: [])
        #expect(idle.stops == .notInService)
        #expect(idle.punctualityText == "Not in service")
    }

    @Test("speed is shown in whole km/h")
    func speed() {
        let details = VehicleDetails(vehicle: vehicle(deviation: 0, speed: 31.6), trip: trip, stops: [])
        #expect(details.speedText.contains("32"))
    }
}
