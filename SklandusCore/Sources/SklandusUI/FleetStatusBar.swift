import SwiftUI
import SklandusKit

/// A line of live figures under the map: whether the feed is healthy, how much is
/// running, and how much of it is on time.
struct FleetStatusBar: View {
    let model: FleetModel
    let timetable: TimetableStatus

    var body: some View {
        HStack {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .fixedSize()
            }
            if !model.vehicles.isEmpty {
                Divider().frame(height: 12)
                Text("\(model.vehicles.count) vehicles")
                    .monospacedDigit()
                if let onTime = model.onTimePercentage {
                    Divider().frame(height: 12)
                    Text("\(Int(onTime))% on time")
                        .monospacedDigit()
                        .help("Of the \(model.inServiceCount) running a scheduled trip")
                }
                Divider().frame(height: 12)
                Text(timetableText)
                    .foregroundStyle(timetableIsHealthy ? .secondary : .primary)
                    .help("Routes and stations are stored in full; trips arrive as vehicles need them.")
            }
        }
        .font(.caption)
        .padding()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.bottom)
    }

    private var timetableText: String {
        switch timetable {
        case .loading:
            return "Timetable loading…"
        case .ready(let routes, _):
            return "\(routes) routes"
        case .failed:
            return "Timetable unavailable"
        }
    }

    private var timetableIsHealthy: Bool {
        if case .failed = timetable { return false }
        return true
    }

    private var statusColor: Color {
        switch model.status {
        case .live: .green
        case .unchanged: .teal
        case .connecting: .gray
        case .offline: .orange
        case .failing: .red
        }
    }

    private var statusText: String {
        switch model.status {
        case .connecting:
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
