import SwiftUI
import VilniusTransitUI

/// The whole iPad app.
///
/// Everything else — the model, the map, the markers, the sidebar, the inspector —
/// comes from `VilniusTransitUI` and is the same code the Mac app runs. If this file
/// ever grows much beyond this, something that should have been shared was not.
@main
struct VilniusTransitPadApp: App {
    @State private var model = FleetModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.start() }
        }
    }
}
