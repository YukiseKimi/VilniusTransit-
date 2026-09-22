import SwiftUI

/// Route number in the route's own colour, and where the vehicle is heading.
struct VehicleInspectorHeader: View {
    let details: VehicleDetails

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(details.routeName)
                    .font(.largeTitle)
                    .bold()
                    .foregroundStyle(routeStyle)
                Text("→ \(details.headsign)")
                    .font(.title3)
            }
            if let longName = details.routeLongName {
                Text(longName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Night routes are published as black, which vanishes in dark mode; they
    /// fall back to the primary text colour.
    private var routeStyle: Color {
        guard let rgba = details.colorHex.flatMap(RGBA.init(hex:)), rgba.luminance > 0.15 else {
            return .primary
        }
        return rgba.swiftUI
    }
}
