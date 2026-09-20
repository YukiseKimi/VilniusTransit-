import SwiftUI
import SklandusKit

/// A line of live figures under the map: whether the feed is healthy, how much is
/// running, and how much of it is on time.
struct FleetStatusBar: View {
    let model: FleetModel

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
            }
        }
        .font(.caption)
        .padding()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(.bottom)
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
