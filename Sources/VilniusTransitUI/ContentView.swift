import SwiftUI
import MapKit
import VilniusTransitKit

public struct ContentView: View {
    @Environment(FleetModel.self) private var model
    @State private var emphasis: MKStandardMapConfiguration.EmphasisStyle = .muted
    @State private var showInspector = true

    public init() {}

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            TransitMapView(
                vehicles: model.filteredVehicles,
                catalog: model.catalog,
                dataToken: model.dataToken,
                glide: model.pollInterval,
                emphasis: emphasis,
                selectedFleetNumber: $model.selectedFleetNumber
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { StatusBar() }
            .inspector(isPresented: $showInspector) {
                VehicleInspector()
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Map style", selection: $emphasis) {
                        Text("Muted").tag(MKStandardMapConfiguration.EmphasisStyle.muted)
                        Text("Default").tag(MKStandardMapConfiguration.EmphasisStyle.default)
                    }
                    .pickerStyle(.segmented)
                    .help("Muted plays down the basemap so vehicles read clearly")
                }
                ToolbarItem {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                }
            }
        }
        .navigationTitle("Vilnius Transit")
    }
}

// MARK: - Sidebar
