import SwiftUI
import MapKit
import SklandusKit

#if os(macOS)
typealias FleetMapRepresentable = NSViewRepresentable
#else
typealias FleetMapRepresentable = UIViewRepresentable
#endif

/// The live fleet on a map.
///
/// `MKMapView` rather than SwiftUI's `Map`: with ~390 vehicles moving every few
/// seconds, `Map` rebuilds its content on every change, reuses no annotation views,
/// and offers no way to move a marker from one coordinate to another. Only the
/// representable conformance differs between Mac and iPad; the coordinator holding
/// the diffing, interpolation and culling is the same on both.
public struct FleetMapView: FleetMapRepresentable {

    var vehicles: [Vehicle]
    /// Trip details held in memory. Read once per marker, so it has to answer
    /// synchronously.
    var resolver: TripResolver?
    /// Changes when the fleet is genuinely new, so a redraw does not re-ingest the
    /// same snapshot.
    var dataToken: Int
    /// Changes when the resolver learns something, so markers that were drawn in
    /// fallback colours get repainted once their route is known.
    var appearanceToken: Int
    /// The selected vehicle's fleet number, or nil. A binding because selection
    /// can start either on the map or elsewhere in the interface.
    @Binding var selection: String?
    /// How long a marker takes to travel to its new fix, matched to the poll.
    var glide: TimeInterval
    var emphasis: MKStandardMapConfiguration.EmphasisStyle

    public init(
        vehicles: [Vehicle],
        resolver: TripResolver? = nil,
        dataToken: Int,
        appearanceToken: Int = 0,
        selection: Binding<String?> = .constant(nil),
        glide: TimeInterval = 5,
        emphasis: MKStandardMapConfiguration.EmphasisStyle = .muted
    ) {
        self._selection = selection
        self.vehicles = vehicles
        self.resolver = resolver
        self.dataToken = dataToken
        self.appearanceToken = appearanceToken
        self.glide = glide
        self.emphasis = emphasis
    }

    /// Vilnius, wide enough to hold the city's routes.
    public static let vilnius = CLLocationCoordinate2D(latitude: 54.6872, longitude: 25.2797)

    public func makeCoordinator() -> FleetMapCoordinator { FleetMapCoordinator(self) }

    #if os(macOS)
    public func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateNSView(_ mapView: MKMapView, context: Context) {
        updateMap(mapView, context: context)
    }
    public static func dismantleNSView(_ mapView: MKMapView, coordinator: FleetMapCoordinator) {
        coordinator.detach()
    }
    #else
    public func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateUIView(_ mapView: MKMapView, context: Context) {
        updateMap(mapView, context: context)
    }
    public static func dismantleUIView(_ mapView: MKMapView, coordinator: FleetMapCoordinator) {
        coordinator.detach()
    }
    #endif

    private func makeMap(context: Context) -> MKMapView {
        MarkerImages.shared.setScale(context.environment.displayScale)
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isPitchEnabled = false
        mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        #if os(macOS)
        // The Mac gets on-screen zoom buttons; on iPad people pinch.
        mapView.showsZoomControls = true
        #endif
        mapView.register(
            VehicleAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: VehicleAnnotationView.reuseIdentifier
        )
        mapView.setRegion(
            MKCoordinateRegion(
                center: Self.vilnius,
                span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.22)
            ),
            animated: false
        )
        context.coordinator.attach(to: mapView)
        return mapView
    }

    private func updateMap(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Moving a window between displays changes the scale markers are drawn at.
        MarkerImages.shared.setScale(context.environment.displayScale)

        if let configuration = mapView.preferredConfiguration as? MKStandardMapConfiguration,
           configuration.emphasisStyle != emphasis {
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        }
        context.coordinator.ingest(vehicles: vehicles, token: dataToken, glide: glide)
        context.coordinator.refreshAppearance(token: appearanceToken)
        context.coordinator.syncSelection(to: selection)
    }
}
