import SwiftUI
import SklandusKit

/// Placeholder root of both apps.
///
/// It exists so the project can be built, signed and launched on Mac and iPad
/// before any real feature code is written, which is the cheapest moment to find
/// structural problems.
public struct RootView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            AppInfo.displayName,
            systemImage: "bus.fill",
            description: Text("Live Vilnius transit. Nothing here yet.")
        )
    }
}

#Preview {
    RootView()
}
