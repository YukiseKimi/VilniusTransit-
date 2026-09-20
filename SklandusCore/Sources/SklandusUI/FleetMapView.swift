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
    /// How long a marker takes to travel to its new fix, matched to the poll.
    var glide: TimeInterval
    var emphasis: MKStandardMapConfiguration.EmphasisStyle

    public init(
        vehicles: [Vehicle],
        resolver: TripResolver? = nil,
        dataToken: Int,
        appearanceToken: Int = 0,
        glide: TimeInterval = 5,
        emphasis: MKStandardMapConfiguration.EmphasisStyle = .muted
    ) {
        self.vehicles = vehicles
        self.resolver = resolver
        self.dataToken = dataToken
        self.appearanceToken = appearanceToken
        self.glide = glide
        self.emphasis = emphasis
    }

    /// Vilnius, wide enough to hold the city's routes.
    public static let vilnius = CLLocationCoordinate2D(latitude: 54.6872, longitude: 25.2797)

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    public func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateNSView(_ mapView: MKMapView, context: Context) {
        updateMap(mapView, context: context)
    }
    public static func dismantleNSView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }
    #else
    public func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateUIView(_ mapView: MKMapView, context: Context) {
        updateMap(mapView, context: context)
    }
    public static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
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
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        fileprivate var parent: FleetMapView
        private weak var mapView: MKMapView?

        private var interpolator = FleetInterpolator()
        private var annotations: [String: VehicleAnnotation] = [:]
        private var lastToken: Int?
        private var lastAppearanceToken: Int?
        private var tickTimer: Timer?

        /// 20 fps is smooth to the eye and a fraction of the work of matching the
        /// display's refresh rate, which nothing here needs.
        private static let tickInterval: TimeInterval = 1.0 / 20.0

        init(_ parent: FleetMapView) {
            self.parent = parent
            super.init()
        }

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            // .common keeps markers moving while the map is panned or zoomed; the
            // default mode freezes them mid-gesture.
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }

        func detach() {
            tickTimer?.invalidate()
            tickTimer = nil
            mapView = nil
        }

        // MARK: Snapshots

        func ingest(vehicles: [Vehicle], token: Int, glide: TimeInterval) {
            guard token != lastToken, let mapView else { return }
            lastToken = token

            let now = Date()
            let diff = interpolator.apply(vehicles, now: now, glide: glide)
            guard !diff.isEmpty else { return }

            if !diff.removed.isEmpty {
                mapView.removeAnnotations(diff.removed.compactMap { annotations.removeValue(forKey: $0) })
            }

            var incoming: [VehicleAnnotation] = []
            incoming.reserveCapacity(diff.added.count)
            for id in diff.added {
                guard let track = interpolator.track(id) else { continue }
                let resolved = parent.resolver?.resolved(track.vehicle.gtfsTripID)
                let annotation = VehicleAnnotation(
                    vehicle: track.vehicle,
                    coordinate: track.coordinate(at: now),
                    heading: track.heading(at: now),
                    routeColorHex: resolved?.routeColor,
                    routeLongName: resolved?.routeLongName
                )
                annotations[id] = annotation
                incoming.append(annotation)
            }
            if !incoming.isEmpty { mapView.addAnnotations(incoming) }

            for id in diff.updated {
                guard let annotation = annotations[id], let track = interpolator.track(id) else { continue }
                // A vehicle turning round at a terminus keeps its fleet number but
                // starts a new trip, so its route can change underneath it.
                let previousTrip = annotation.vehicle.gtfsTripID
                annotation.vehicle = track.vehicle
                if previousTrip != track.vehicle.gtfsTripID {
                    let resolved = parent.resolver?.resolved(track.vehicle.gtfsTripID)
                    annotation.routeColorHex = resolved?.routeColor
                    annotation.routeLongName = resolved?.routeLongName
                }
                if let view = mapView.view(for: annotation) as? VehicleAnnotationView {
                    view.applyAppearance(annotation, selected: false)
                }
            }
        }

        /// Repaints markers once the resolver has learned their routes. Hydration
        /// arrives after the vehicles do, so the first sight of a vehicle is often
        /// in fallback colours.
        func refreshAppearance(token: Int) {
            guard token != lastAppearanceToken, let mapView, let resolver = parent.resolver else { return }
            lastAppearanceToken = token

            for (_, annotation) in annotations {
                let resolved = resolver.resolved(annotation.vehicle.gtfsTripID)
                guard annotation.routeColorHex != resolved?.routeColor else { continue }
                annotation.routeColorHex = resolved?.routeColor
                annotation.routeLongName = resolved?.routeLongName
                (mapView.view(for: annotation) as? VehicleAnnotationView)?
                    .applyAppearance(annotation, selected: false)
            }
        }

        // MARK: Motion

        private func tick() {
            guard let mapView, !annotations.isEmpty else { return }
            let now = Date()

            // Only animate what can actually be seen. Vehicles panned off-screen
            // keep their data current but cost nothing to draw.
            let visible = mapView.visibleMapRect.insetBy(
                dx: -mapView.visibleMapRect.size.width * 0.2,
                dy: -mapView.visibleMapRect.size.height * 0.2
            )
            // Moving an annotation is a KVO round trip through MapKit, so skip
            // anything that would not shift the marker half a point on screen.
            let metresPerPoint = mapView.visibleMapRect.size.width
                * MKMetersPerMapPointAtLatitude(mapView.region.center.latitude)
                / max(mapView.bounds.width, 1)
            let latitudeEpsilon = 0.5 * metresPerPoint / 111_320
            let longitudeEpsilon = latitudeEpsilon
                / max(cos(mapView.region.center.latitude * .pi / 180), 0.1)

            for (id, annotation) in annotations {
                guard let track = interpolator.track(id) else { continue }
                let coordinate = track.coordinate(at: now)
                guard visible.contains(MKMapPoint(coordinate)) else { continue }
                if abs(coordinate.latitude - annotation.coordinate.latitude) < latitudeEpsilon,
                   abs(coordinate.longitude - annotation.coordinate.longitude) < longitudeEpsilon {
                    continue
                }
                annotation.coordinate = coordinate
                annotation.heading = track.heading(at: now)
                (mapView.view(for: annotation) as? VehicleAnnotationView)?.applyMotion(annotation)
            }
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let vehicle = annotation as? VehicleAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: VehicleAnnotationView.reuseIdentifier,
                for: vehicle
            ) as? VehicleAnnotationView
            view?.applyAppearance(vehicle, selected: false)
            view?.applyMotion(vehicle)
            return view
        }
    }
}
