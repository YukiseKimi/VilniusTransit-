import SwiftUI
import SklandusUI

/// The Mac app. Everything it shows lives in SklandusUI, shared with iPad.
@main
struct SklandusMacApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
