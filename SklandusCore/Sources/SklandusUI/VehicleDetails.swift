import Foundation
import SklandusKit

/// Everything the inspector shows about a vehicle, worked out in one place so it
/// can be tested without drawing anything.
struct VehicleDetails: Equatable {
    let fleetNumber: String
    let routeName: String
    let headsign: String
    /// The route's full name from the timetable, when it adds something.
    let routeLongName: String?
    let colorHex: String?
    let modeName: String
    let punctualityText: String
    let speedText: String
    let stops: StopListState

    init(vehicle: Vehicle, trip: ResolvedTrip?, stops: [GTFSStation]) {
        fleetNumber = vehicle.id
        routeName = trip?.routeShortName.nonEmpty ?? vehicle.route
        headsign = trip?.headsign.nonEmpty ?? vehicle.headsign
        routeLongName = trip?.routeLongName.nonEmpty
        colorHex = trip?.routeColor
        modeName = vehicle.mode.displayName
        punctualityText = Self.punctuality(vehicle)
        speedText = Measurement(value: vehicle.speed, unit: UnitSpeed.kilometersPerHour).formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
        )
        if !vehicle.isInService {
            self.stops = .notInService
        } else if stops.isEmpty {
            self.stops = .loading
        } else {
            self.stops = .stops(stops)
        }
    }

    /// The feed reports seconds; whole minutes are what a passenger reads.
    private static func punctuality(_ vehicle: Vehicle) -> String {
        guard let deviation = vehicle.deviationSeconds else { return "Not in service" }
        let minutes = max(1, Int((Double(abs(deviation)) / 60).rounded()))
        switch vehicle.punctuality {
        case .onTime, .unknown: return "On time"
        case .early: return "\(minutes) min early"
        case .late, .veryLate: return "\(minutes) min late"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
