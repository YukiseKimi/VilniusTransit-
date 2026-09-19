import SwiftUI
import MapKit
import VilniusTransitKit

struct StatusBar: View {
    @Environment(FleetModel.self) private var model

    var body: some View {
        HStack {
            HStack {
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
                .help("In-service vehicles matched to the stops.lt timetable. Vehicles heading to or from a depot have no trip and are not counted.")
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
        .padding()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.bottom)
    }

    private var catalogText: String {
        switch model.catalogStatus {
        case .loading:
            return "Timetable loading…"
        case .ready(let trips, _, let fromCache):
            let joined = model.joinedCount
            let source = fromCache ? "cached" : "fresh"
            return "\(joined)/\(model.inServiceCount) joined · \(trips) trips (\(source))"
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
