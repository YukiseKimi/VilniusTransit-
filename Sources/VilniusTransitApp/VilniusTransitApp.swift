import SwiftUI
import MapKit
import VilniusTransitKit

@main
struct VilniusTransitApp: App {
    @State private var model = FleetModel()

    var body: some Scene {
        WindowGroup("Vilnius Transit") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.start() }
        }
        .windowToolbarStyle(.unified)

        // A live fleet count without keeping a window open — the sort of thing a
        // Mac app gets almost for free and a web page cannot do at all.
        MenuBarExtra("Vilnius Transit", systemImage: "bus.fill") {
            MenuBarContent().environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(FleetModel.self) private var model
    @State private var emphasis: MKStandardMapConfiguration.EmphasisStyle = .muted
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            TransitMapView(
                vehicles: model.filteredVehicles,
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
                                .fill(Color(MarkerImages.color(for: mode)))
                                .frame(width: 9, height: 9)
                            Text(mode.displayName)
                            Spacer()
                            Text("\(model.count(of: mode))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                Toggle("Out of service", isOn: $model.showOutOfService)
                    .toggleStyle(.checkbox)
                    .help("Vehicles with no GTFS trip — deadheading to or from a depot")
            }

            Section("Routes") {
                if model.selectedRoute != nil {
                    Button("Show all routes") { model.selectedRoute = nil }
                        .buttonStyle(.link)
                }
                ForEach(model.routeSummaries) { route in
                    HStack {
                        Text(route.name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(minWidth: 34, alignment: .leading)
                            .foregroundStyle(Color(MarkerImages.color(for: route.mode)))
                        Spacer()
                        Text("\(route.vehicleCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(route.name)
                }
            }
        }
        .searchable(text: $model.routeQuery, placement: .sidebar, prompt: "Route")
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

struct VehicleInspector: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        Group {
            if let vehicle = model.selectedVehicle {
                Form {
                    Section {
                        LabeledContent("Route", value: vehicle.route.isEmpty ? "—" : vehicle.route)
                        LabeledContent("Towards", value: vehicle.headsign)
                        LabeledContent("Mode", value: vehicle.mode.displayName)
                        LabeledContent("Fleet no.", value: vehicle.id)
                    }
                    Section("Right now") {
                        LabeledContent("Speed", value: "\(Int(vehicle.speed)) km/h")
                        LabeledContent("Heading", value: "\(Int(vehicle.heading))°")
                        LabeledContent("Punctuality") { punctuality(vehicle) }
                        LabeledContent(
                            "Fix time",
                            value: VilniusTime.clockString(secondsSinceMidnight: vehicle.measuredAtSecondsSinceMidnight)
                        )
                    }
                    Section("GTFS") {
                        LabeledContent("Trip", value: vehicle.gtfsTripID ?? "not in service")
                            .textSelection(.enabled)
                        LabeledContent("route_type", value: "\(vehicle.mode.gtfsRouteType)")
                        LabeledContent("Vehicle code", value: vehicle.vehicleTypeCode.isEmpty ? "—" : vehicle.vehicleTypeCode)
                    }
                    Section {
                        Text("Joining trip to `trips.txt` gives the shape, headsign and route colour — that is the next step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "No vehicle selected",
                    systemImage: "bus",
                    description: Text("Click any marker on the map.")
                )
            }
        }
    }

    @ViewBuilder
    private func punctuality(_ vehicle: Vehicle) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(MarkerImages.color(for: vehicle.punctuality)))
                .frame(width: 8, height: 8)
            Text(description(for: vehicle))
        }
    }

    private func description(for vehicle: Vehicle) -> String {
        guard let deviation = vehicle.deviationSeconds else { return "Not scheduled" }
        if abs(deviation) < 60 { return "On time" }
        let minutes = abs(deviation) / 60, seconds = abs(deviation) % 60
        return "\(minutes)m \(seconds)s \(deviation > 0 ? "late" : "early")"
    }
}

// MARK: - Status

struct StatusBar: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText).fixedSize()
            }
            Divider().frame(height: 12)
            Text("\(model.filteredVehicles.count) of \(model.vehicles.count) shown").monospacedDigit()
            if let onTime = model.onTimePercentage {
                Divider().frame(height: 12)
                Text("\(Int(onTime))% on time").monospacedDigit()
            }
            if model.notModifiedCount > 0 {
                Divider().frame(height: 12)
                Text("\(model.notModifiedCount) of \(model.pollCount) polls unchanged")
                    .monospacedDigit()
                    .help("304 Not Modified — no body transferred, nothing re-parsed")
            }
            if model.skippedRows > 0 {
                Divider().frame(height: 12)
                Label("\(model.skippedRows) rows skipped", systemImage: "exclamationmark.triangle")
                    .help("Rows the parser rejected. Persistently non-zero means the feed format moved.")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.bottom, 14)
    }

    private var statusColor: Color {
        switch model.status {
        case .live:      .green
        case .unchanged: .teal
        case .idle:      .gray
        case .offline:   .orange
        case .failing:   .red
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle:
            return "Connecting…"
        case .live, .unchanged:
            guard let lastUpdate = model.lastUpdate else { return "Live" }
            let age = Int(Date().timeIntervalSince(lastUpdate))
            return age < 2 ? "Live" : "Live · \(age)s ago"
        case .offline:
            return "Offline — polling paused"
        case .failing(let reason):
            return reason
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        ForEach(TransitMode.allCases, id: \.self) { mode in
            Text("\(mode.displayName): \(model.count(of: mode))")
        }
        Divider()
        if let onTime = model.onTimePercentage {
            Text("\(Int(onTime))% running on time")
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
