import SwiftUI
import MapKit
import VilniusTransitKit

/// Coloured dot plus a plain-language schedule deviation.
struct PunctualityLabel: View {
    let vehicle: Vehicle

    var body: some View {
        HStack {
            Circle()
                .fill(MarkerImages.color(for: vehicle.punctuality).swiftUI)
                .frame(width: 8, height: 8)
            Text(description)
        }
    }

    private var description: String {
        guard let deviation = vehicle.deviationSeconds else { return "Not scheduled" }
        if abs(deviation) < 60 { return "On time" }
        let minutes = abs(deviation) / 60, seconds = abs(deviation) % 60
        return "\(minutes)m \(seconds)s \(deviation > 0 ? "late" : "early")"
    }
}

// MARK: - Status
