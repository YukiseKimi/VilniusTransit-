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
                                .fill(Color(MarkerImages.fallbackColor(for: mode)))
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
                    HStack(spacing: 8) {
                        Text(route.name)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(badgeTextColor(for: route)))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(badgeColor(for: route)), in: Capsule())
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
        .searchable(text: $model.routeQuery, placement: .sidebar, prompt: "Route")
    }

    private func badgeColor(for route: FleetModel.RouteSummary) -> NSColor {
        route.colorHex.flatMap(MarkerImages.color(hex:)) ?? MarkerImages.fallbackColor(for: route.mode)
    }

    /// Night routes are published as black, which needs light text.
    private func badgeTextColor(for route: FleetModel.RouteSummary) -> NSColor {
        let fill = badgeColor(for: route)
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
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
                        LabeledContent("Punctuality") { punctuality(vehicle) }
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
            Divider().frame(height: 12)
            Text(catalogText)
                .foregroundStyle(catalogIsHealthy ? .secondary : .primary)
                .help("Static timetable from stops.lt, cached on disk and refreshed conditionally")
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

    private var catalogText: String {
        switch model.catalogStatus {
        case .loading:
            return "Timetable loading…"
        case .ready(let trips, _, let fromCache):
            let joined = model.joinedCount
            let source = fromCache ? "cached" : "fresh"
            return "\(joined)/\(model.vehicles.count) joined · \(trips) trips (\(source))"
        case .failed:
            return "Timetable unavailable"
        }
    }

    private var catalogIsHealthy: Bool {
        if case .failed = model.catalogStatus { return false }
        return true
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
