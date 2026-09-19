import SwiftUI
import MapKit
import VilniusTransitKit

struct SidebarView: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedRoute) {
            Section("Modes") {
                ForEach(TransitMode.allCases, id: \.self) { mode in
                    Toggle(isOn: binding(for: mode)) {
                        HStack {
                            Circle()
                                .fill(MarkerImages.fallbackColor(for: mode).swiftUI)
                                .frame(width: 9, height: 9)
                            Text(mode.displayName)
                            Spacer()
                            Text("\(model.count(of: mode))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .transitToggleStyle()
                }
                Toggle("Out of service", isOn: $model.showOutOfService)
                    .transitToggleStyle()
                    .help("Vehicles with no GTFS trip — deadheading to or from a depot")
            }

            Section("Routes") {
                if model.selectedRoute != nil {
                    Button("Show all routes") { model.selectedRoute = nil }
                        .buttonStyle(.borderless)
                }
                ForEach(model.routeSummaries) { route in
                    HStack {
                        Text(route.name)
                            .font(.caption)
                            .bold()
                            .fontDesign(.rounded)
                            .foregroundStyle(badgeTextColor(for: route).swiftUI)
                            .padding(.horizontal)
                            .background(badgeColor(for: route).swiftUI, in: Capsule())
                            .frame(minWidth: 38, alignment: .leading)
                        if let longName = route.longName, !longName.isEmpty {
                            Text(longName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        Text("\(route.vehicleCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(route.name)
                    .help(route.longName ?? route.name)
                }
            }
        }
        #if os(macOS)
        .searchable(text: $model.routeQuery, placement: .sidebar, prompt: "Route")
        #else
        .searchable(text: $model.routeQuery, prompt: "Route")
        #endif
    }

    private func badgeColor(for route: FleetModel.RouteSummary) -> RGBA {
        route.colorHex.flatMap(RGBA.init(hex:)) ?? MarkerImages.fallbackColor(for: route.mode)
    }

    /// Night routes are published as black, which needs light text.
    private func badgeTextColor(for route: FleetModel.RouteSummary) -> RGBA {
        MarkerImages.readableText(on: badgeColor(for: route))
    }

    private func binding(for mode: TransitMode) -> Binding<Bool> {
        Binding(
            get: { model.enabledModes.contains(mode) },
            set: { isOn in
                if isOn { model.enabledModes.insert(mode) } else { model.enabledModes.remove(mode) }
            }
        )
    }
}

// MARK: - Inspector
