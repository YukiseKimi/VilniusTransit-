import SwiftUI
import SklandusKit

/// The app: the live fleet on a map, coloured by the city's own route data.
public struct RootView: View {
    @State private var services = AppServices()
    @State private var selection: String?
    /// On by default for each new selection; the map turns it off when the
    /// reader moves away from the vehicle.
    @State private var following = true

    public init() {}

    public var body: some View {
        FleetMapView(
            vehicles: services.fleet.vehicles,
            resolver: services.resolver,
            dataToken: services.fleet.snapshotToken,
            appearanceToken: services.resolver.revision,
            selection: $selection,
            following: $following,
            stops: services.selectedStops
        )
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            FleetStatusBar(model: services.fleet, timetable: services.timetableStatus)
        }
        .inspector(isPresented: inspectorPresented) {
            if let vehicle = services.fleet.selectedVehicle {
                VehicleInspector(
                    details: VehicleDetails(
                        vehicle: vehicle,
                        trip: services.resolver.resolved(vehicle.gtfsTripID),
                        stops: services.selectedStops
                    ),
                    following: $following
                )
            }
        }
        .task { services.start() }
        // Each new snapshot brings trips the resolver may not know yet.
        .task(id: services.fleet.snapshotToken) {
            await services.refreshTrips()
            // A vehicle that turned round at a terminus calls at different stops.
            await services.refreshSelectedStops()
        }
        .task(id: selection) { await services.refreshSelectedStops() }
        .task(id: services.resolver.revision) { await services.refreshSelectedStops() }
        .onChange(of: selection) { _, new in
            services.fleet.select(new)
            if new != nil { following = true }
        }
        // A selected vehicle can leave the feed at the end of its shift.
        .onChange(of: services.fleet.selectedFleetNumber) { _, new in
            if selection != new { selection = new }
        }
    }

    /// Open while something is selected; closing it clears the selection.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { if !$0 { selection = nil } }
        )
    }
}

#Preview {
    RootView()
}
