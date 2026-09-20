import SwiftUI
import SklandusUI

/// The iPad app. Everything it shows lives in SklandusUI, shared with the Mac.
@main
struct SklandusPadApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
