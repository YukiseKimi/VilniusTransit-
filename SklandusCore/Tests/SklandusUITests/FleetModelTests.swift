import Testing
import Foundation
import CoreLocation
@testable import SklandusUI
@testable import SklandusKit

@MainActor
@Suite("Fleet model")
struct FleetModelTests {

    private func vehicle(
        id: String,
        mode: TransitMode = .bus,
        deviation: Int? = 0,
        inService: Bool = true
    ) -> Vehicle {
        Vehicle(
            id: id, mode: mode, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            speed: 20, heading: 90,
            deviationSeconds: inService ? deviation : nil,
            measuredAtSecondsSinceMidnight: 48000, headsign: "Test",
            gtfsTripID: inService ? "A7-01" : nil, vehicleTypeCode: "KWZ"
        )
    }

    private func snapshot(_ vehicles: [Vehicle]) -> VehicleFeedClient.Snapshot {
        VehicleFeedClient.Snapshot(
            vehicles: vehicles, receivedAt: Date(), skippedRows: 0, byteCount: 1000
        )
    }

    @Test("starts out connecting, with nothing to show")
    func initialState() {
        let model = FleetModel()
        #expect(model.status == .connecting)
        #expect(model.vehicles.isEmpty)
        #expect(model.onTimePercentage == nil)
    }

    @Test("a snapshot becomes the fleet, and bumps the token")
    func appliesSnapshot() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle(id: "1"), vehicle(id: "2")])))
        #expect(model.vehicles.count == 2)
        #expect(model.status == .live)
        #expect(model.snapshotToken == 1)
        #expect(model.lastUpdate != nil)
    }

    @Test("counts by mode come from one pass, not a computed property")
    func countsByMode() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([
            vehicle(id: "1", mode: .bus),
            vehicle(id: "2", mode: .bus),
            vehicle(id: "3", mode: .trolleybus),
            vehicle(id: "4", mode: .ferry)
        ])))
        #expect(model.count(of: .bus) == 2)
        #expect(model.count(of: .trolleybus) == 1)
        #expect(model.count(of: .ferry) == 1)
    }

    /// Vehicles heading to a depot carry no trip and no deviation. Counting them
    /// in the punctuality ratio made a midnight fleet look broken in the spike.
    @Test("punctuality counts only vehicles actually running a trip")
    func punctualityIgnoresOutOfService() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([
            vehicle(id: "1", deviation: 0),      // on time
            vehicle(id: "2", deviation: 200),    // late
            vehicle(id: "3", inService: false),  // heading to a depot
            vehicle(id: "4", inService: false)
        ])))
        #expect(model.inServiceCount == 2)
        #expect(model.onTimePercentage == 50)
    }

    @Test("a fleet with nothing in service has no punctuality, rather than zero")
    func noScheduledVehicles() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle(id: "1", inService: false)])))
        #expect(model.inServiceCount == 0)
        #expect(model.onTimePercentage == nil)
    }

    @Test("a 304 keeps the fleet and records the saving")
    func unchangedKeepsVehicles() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle(id: "1")])))
        model.handle(.unchanged)
        #expect(model.vehicles.count == 1)
        #expect(model.status == .unchanged)
        #expect(model.unchangedCount == 1)
        // The token does not move: this is the same data, not new data.
        #expect(model.snapshotToken == 1)
    }

    @Test("going offline keeps the last fleet on screen")
    func offlineKeepsVehicles() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle(id: "1")])))
        model.handle(.offline)
        #expect(model.status == .offline)
        #expect(model.vehicles.count == 1)
    }

    @Test("a failure is surfaced with its reason")
    func failureCarriesReason() {
        let model = FleetModel()
        model.handle(.failure("Feed returned HTTP 503"))
        #expect(model.status == .failing("Feed returned HTTP 503"))
    }

    @Test("skipped rows are surfaced, since they mean the feed's shape moved")
    func surfacesSkippedRows() {
        let model = FleetModel()
        model.handle(.snapshot(VehicleFeedClient.Snapshot(
            vehicles: [vehicle(id: "1")], receivedAt: Date(), skippedRows: 3, byteCount: 10
        )))
        #expect(model.skippedRows == 3)
    }
}

@MainActor
@Suite("Selection")
struct FleetSelectionTests {

    private func vehicle(_ id: String, tripID: String? = "A7-01") -> Vehicle {
        Vehicle(
            id: id, mode: .bus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            speed: 20, heading: 90, deviationSeconds: 0,
            measuredAtSecondsSinceMidnight: 48000, headsign: "Test",
            gtfsTripID: tripID, vehicleTypeCode: "KWZ"
        )
    }

    private func snapshot(_ vehicles: [Vehicle]) -> VehicleFeedClient.Snapshot {
        VehicleFeedClient.Snapshot(
            vehicles: vehicles, receivedAt: Date(), skippedRows: 0, byteCount: 1000
        )
    }

    @Test("selecting a vehicle finds it in the current fleet")
    func selects() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125"), vehicle("4126")])))
        model.select("4126")
        #expect(model.selectedFleetNumber == "4126")
        #expect(model.selectedVehicle?.id == "4126")
    }

    /// The fleet is replaced wholesale every five seconds; the selection must not
    /// be.
    @Test("a selection survives new snapshots and follows the vehicle")
    func survivesSnapshots() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125")])))
        model.select("4125")

        var moved = vehicle("4125")
        moved = Vehicle(
            id: "4125", mode: .bus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: 54.70, longitude: 25.30),
            speed: 40, heading: 180, deviationSeconds: 30,
            measuredAtSecondsSinceMidnight: 48005, headsign: "Test",
            gtfsTripID: "A7-01", vehicleTypeCode: "KWZ"
        )
        model.handle(.snapshot(snapshot([moved])))

        #expect(model.selectedFleetNumber == "4125")
        #expect(model.selectedVehicle?.speed == 40)
        #expect(model.selectedVehicle?.coordinate.latitude == 54.70)
    }

    /// End of shift: the vehicle stops being reported.
    @Test("a vehicle leaving the feed clears the selection")
    func clearsWhenVehicleLeaves() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125"), vehicle("4126")])))
        model.select("4125")

        model.handle(.snapshot(snapshot([vehicle("4126")])))
        #expect(model.selectedFleetNumber == nil)
        #expect(model.selectedVehicle == nil)
    }

    /// A vehicle turning round at a terminus keeps its fleet number but starts a
    /// new trip, which the drawn route has to follow.
    @Test("a selected vehicle changing trip keeps the selection")
    func survivesTripChange() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125", tripID: "A7-01")])))
        model.select("4125")

        model.handle(.snapshot(snapshot([vehicle("4125", tripID: "A7-02")])))
        #expect(model.selectedFleetNumber == "4125")
        #expect(model.selectedVehicle?.gtfsTripID == "A7-02")
    }

    @Test("selecting nothing clears both the number and the vehicle")
    func deselects() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125")])))
        model.select("4125")
        model.select(nil)
        #expect(model.selectedFleetNumber == nil)
        #expect(model.selectedVehicle == nil)
    }

    @Test("selecting a vehicle that is not in the fleet selects nothing")
    func unknownSelection() {
        let model = FleetModel()
        model.handle(.snapshot(snapshot([vehicle("4125")])))
        model.select("9999")
        #expect(model.selectedVehicle == nil)
    }
}
