import SwiftUI
import SklandusKit

/// The selected vehicle, in the inspector beside the map.
struct VehicleInspector: View {
    let details: VehicleDetails
    @Binding var following: Bool

    var body: some View {
        Form {
            Section {
                VehicleInspectorHeader(details: details)
            }
            Section {
                LabeledContent("Timetable", value: details.punctualityText)
                LabeledContent("Speed", value: details.speedText)
                LabeledContent(details.modeName, value: details.fleetNumber)
                Toggle("Follow on map", systemImage: "location", isOn: $following)
            }
            Section("Stops") {
                VehicleStopList(state: details.stops)
            }
        }
        .formStyle(.grouped)
    }
}
