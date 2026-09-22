import SwiftUI
import SklandusKit

/// The stops a vehicle calls at on this trip, in order.
struct VehicleStopList: View {
    let state: StopListState

    var body: some View {
        switch state {
        case .notInService:
            Text("Between runs — no stops scheduled")
                .foregroundStyle(.secondary)
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Loading stops…")
                    .foregroundStyle(.secondary)
            }
        case .stops(let stations):
            // Loop routes call at their first station again at the end, so the
            // position, not the station, is what makes a row unique.
            ForEach(stations.enumerated(), id: \.offset) { offset, station in
                // Number first, so a long name wraps under itself rather than
                // pushing the number onto a line of its own.
                HStack(alignment: .firstTextBaseline) {
                    Text(offset + 1, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(station.name)
                }
            }
        }
    }
}
