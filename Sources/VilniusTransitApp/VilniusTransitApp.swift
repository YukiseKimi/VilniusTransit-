import SwiftUI
import AppKit
import VilniusTransitKit
import VilniusTransitUI

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

// MARK: - Menu bar
