import SwiftUI
import MapKit
import VilniusTransitKit

struct VehicleInspector: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        Group {
            if let vehicle = model.selectedVehicle {
                Form {
                    Section {
                        LabeledContent("Route", value: vehicle.route.isEmpty ? "—" : vehicle.route)
                        if let route = model.resolved(vehicle), !route.longName.isEmpty {
                            LabeledContent("Line", value: route.longName)
                        }
                        LabeledContent("Towards", value: vehicle.headsign)
                        LabeledContent("Mode", value: vehicle.mode.displayName)
                        LabeledContent("Fleet no.", value: vehicle.id)
                    }
                    Section("Right now") {
                        LabeledContent("Speed", value: "\(Int(vehicle.speed)) km/h")
                        LabeledContent("Heading", value: "\(Int(vehicle.heading))°")
                        LabeledContent("Punctuality") { PunctualityLabel(vehicle: vehicle) }
                        LabeledContent(
                            "Fix time",
                            value: VilniusTime.clockString(secondsSinceMidnight: vehicle.measuredAtSecondsSinceMidnight)
                        )
                    }
                    Section("Timetable") {
                        LabeledContent("Trip", value: vehicle.gtfsTripID ?? "not in service")
                            .textSelection(.enabled)
                        LabeledContent("route_type", value: "\(model.resolved(vehicle)?.routeType ?? vehicle.mode.gtfsRouteType)")
                        if let shape = model.shape(for: vehicle) {
                            LabeledContent("Path", value: "\(shape.count) points")
                        } else if vehicle.isInService {
                            // Layover and driver-break movements carry GTFS-shaped
                            // trip IDs that the published feed does not contain.
                            LabeledContent("Path", value: "not in the timetable")
                        }
                        LabeledContent("Vehicle code", value: vehicle.vehicleTypeCode.isEmpty ? "—" : vehicle.vehicleTypeCode)
                    }
                    let calls = model.stations(for: vehicle)
                    if !calls.isEmpty {
                        Section("Calls at \(calls.count) stops") {
                            ForEach(Array(calls.enumerated()), id: \.element.id) { index, station in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 18, alignment: .trailing)
                                    Text(station.name)
                                        .lineLimit(1)
                                    if station.platformCount > 1 {
                                        Image(systemName: "arrow.left.arrow.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .help("\(station.platformCount) platforms grouped")
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No vehicle selected",
                    systemImage: "bus",
                    description: Text("\(Platform.selectVerb) any marker on the map.")
                )
            }
        }
    }
}
