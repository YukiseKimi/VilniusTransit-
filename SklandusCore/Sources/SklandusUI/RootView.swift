import SwiftUI
import SklandusKit

/// The app: the live fleet on a map.
public struct RootView: View {
    @State private var model = FleetModel()

    public init() {}

    public var body: some View {
        FleetMapView(vehicles: model.vehicles, dataToken: model.snapshotToken)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { FleetStatusBar(model: model) }
            .task { model.start() }
    }
}

#Preview {
    RootView()
}
