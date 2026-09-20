import SwiftUI
import SklandusKit

/// The app: the live fleet on a map, coloured by the city's own route data.
public struct RootView: View {
    @State private var services = AppServices()
    @State private var selection: String?

    public init() {}

    public var body: some View {
        FleetMapView(
            vehicles: services.fleet.vehicles,
            resolver: services.resolver,
            dataToken: services.fleet.snapshotToken,
            appearanceToken: services.resolver.revision,
            selection: $selection
        )
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            FleetStatusBar(model: services.fleet, timetable: services.timetableStatus)
        }
        .task { services.start() }
        // Each new snapshot brings trips the resolver may not know yet.
        .task(id: services.fleet.snapshotToken) { await services.refreshTrips() }
        .onChange(of: selection) { _, new in services.fleet.select(new) }
        // A selected vehicle can leave the feed at the end of its shift.
        .onChange(of: services.fleet.selectedFleetNumber) { _, new in
            if selection != new { selection = new }
        }
    }
}

#Preview {
    RootView()
}
