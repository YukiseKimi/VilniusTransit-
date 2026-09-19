import SwiftUI
import AppKit
import VilniusTransitKit
import VilniusTransitUI

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
