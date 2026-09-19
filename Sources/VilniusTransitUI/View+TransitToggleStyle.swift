import SwiftUI
import MapKit
import VilniusTransitKit

extension View {
    /// Checkboxes read as native on the Mac and wrong on iPad, which expects a
    /// switch. The only chrome difference between the two.
    @ViewBuilder
    func transitToggleStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }
}
