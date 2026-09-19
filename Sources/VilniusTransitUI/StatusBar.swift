import SwiftUI
import MapKit
import VilniusTransitKit

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
