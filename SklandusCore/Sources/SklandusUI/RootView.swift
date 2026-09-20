import SwiftUI
import SklandusKit

/// The app: the live fleet on a map, coloured by the city's own route data.
public struct RootView: View {
    @State private var services = AppServices()

    public init() {}

    public var body: some View {
        FleetMapView(
            vehicles: services.fleet.vehicles,
            resolver: services.resolver,
            dataToken: services.fleet.snapshotToken,
            appearanceToken: services.resolver.revision
        )
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            FleetStatusBar(model: services.fleet, timetable: services.timetableStatus)
        }
        .task { services.start() }
        // Each new snapshot brings trips the resolver may not know yet.
        .task(id: services.fleet.snapshotToken) { await services.refreshTrips() }
    }
}

#Preview {
    RootView()
}
