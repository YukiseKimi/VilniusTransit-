import SwiftUI
import MapKit
import VilniusTransitKit

#if os(macOS)
typealias TransitMapRepresentable = NSViewRepresentable
#else
typealias TransitMapRepresentable = UIViewRepresentable
#endif

/// `MKMapView` wrapped for SwiftUI.
///
/// SwiftUI's own `Map` rebuilds its content tree on every change, gives no view
/// reuse, and offers no way to move a marker from one coordinate to another. With
/// ~385 vehicles refreshing every few seconds that is the whole problem, so the map
/// itself stays `MKMapView` and everything around it stays SwiftUI.
///
/// Only the representable conformance differs between Mac and iPad — the coordinator
/// below, which holds all the diffing, interpolation, culling and overlay logic, is
/// identical on both.
public struct TransitMapView: TransitMapRepresentable {

    var vehicles: [Vehicle]
    /// The static timetable. Empty until it loads; every use degrades to nil.
    var catalog: GTFSCatalog
    /// Changes whenever `vehicles` is meaningfully new. Cheaper than diffing an
    /// array of 385 structs on every SwiftUI update pass.
    var dataToken: Int
    /// How long a marker takes to travel to its new fix. Matched to the poll interval.
    var glide: TimeInterval
    var emphasis: MKStandardMapConfiguration.EmphasisStyle
    @Binding var selectedFleetNumber: String?

    public init(
        vehicles: [Vehicle],
        catalog: GTFSCatalog,
        dataToken: Int,
        glide: TimeInterval,
        emphasis: MKStandardMapConfiguration.EmphasisStyle,
        selectedFleetNumber: Binding<String?>
    ) {
        self.vehicles = vehicles
        self.catalog = catalog
        self.dataToken = dataToken
        self.glide = glide
        self.emphasis = emphasis
        self._selectedFleetNumber = selectedFleetNumber
    }

    public static let vilnius = CLLocationCoordinate2D(latitude: 54.6872, longitude: 25.2797)

    /// Carries the route's published colour to the renderer.
    public final class RoutePolyline: MKPolyline {
        var color: String?
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    public func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateNSView(_ mapView: MKMapView, context: Context) { updateMap(mapView, context: context) }
    public static func dismantleNSView(_ mapView: MKMapView, coordinator: Coordinator) { coordinator.detach() }
    #else
    public func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    public func updateUIView(_ mapView: MKMapView, context: Context) { updateMap(mapView, context: context) }
    public static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) { coordinator.detach() }
    #endif

    private func makeMap(context: Context) -> MKMapView {
        // SwiftUI already knows the display scale; no need to ask NSScreen/UIScreen.
        MarkerImages.shared.setScale(context.environment.displayScale)
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isPitchEnabled = false
        #if os(macOS)
        // Mac gets on-screen zoom buttons; iPad users pinch.
        mapView.showsZoomControls = true
        #endif
        mapView.register(VehicleAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: VehicleAnnotationView.reuseIdentifier)
        mapView.register(StationAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: StationAnnotationView.reuseIdentifier)
        mapView.setRegion(
            MKCoordinateRegion(center: Self.vilnius,
                               span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.22)),
            animated: false
        )
        context.coordinator.attach(to: mapView)
        return mapView
    }

    private func updateMap(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Moving a window between displays can change the scale.
        MarkerImages.shared.setScale(context.environment.displayScale)

        if let config = mapView.preferredConfiguration as? MKStandardMapConfiguration,
           config.emphasisStyle != emphasis {
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        } else if !(mapView.preferredConfiguration is MKStandardMapConfiguration) {
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        }

        context.coordinator.ingest(vehicles: vehicles, token: dataToken, glide: glide)
        context.coordinator.syncSelection(to: selectedFleetNumber)
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        fileprivate var parent: TransitMapView
        private weak var mapView: MKMapView?

        private var interpolator = FleetInterpolator()
        private var annotations: [String: VehicleAnnotation] = [:]
        private var lastToken: Int?
        private var tickTimer: Timer?
        private var isApplyingSelection = false
        private var routeOverlay: RoutePolyline?
        private var stationAnnotations: [StationAnnotation] = []
        private var overlayFleetNumber: String?

        /// 20 fps is smooth to the eye and a fifth of the work of matching the
        /// display refresh rate, which nothing here needs.
        private static let tickInterval: TimeInterval = 1.0 / 20.0

        init(_ parent: TransitMapView) {
            self.parent = parent
            super.init()
        }

        func attach(to mapView: MKMapView) {
            self.mapView = mapView
            // .common keeps markers moving while the user pans or zooms; the default
            // mode would freeze them mid-gesture.
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

        // MARK: Snapshot ingest

        func ingest(vehicles: [Vehicle], token: Int, glide: TimeInterval) {
            guard token != lastToken, let mapView else { return }
            lastToken = token

            let now = Date()
            let diff = interpolator.apply(vehicles, now: now, glide: glide)
            guard !diff.isEmpty else { return }

            if !diff.removed.isEmpty {
                let going = diff.removed.compactMap { annotations.removeValue(forKey: $0) }
                mapView.removeAnnotations(going)
            }

            var incoming: [VehicleAnnotation] = []
            incoming.reserveCapacity(diff.added.count)
            for id in diff.added {
                guard let track = interpolator.track(id) else { continue }
                let route = parent.catalog.route(forVehicle: track.vehicle)
                let annotation = VehicleAnnotation(
                    vehicle: track.vehicle,
                    coordinate: track.coordinate(at: now),
                    heading: track.heading(at: now),
                    routeColorHex: route?.color,
                    routeLongName: route?.longName
                )
                annotations[id] = annotation
                incoming.append(annotation)
            }
            if !incoming.isEmpty { mapView.addAnnotations(incoming) }

            // Refresh the badge for vehicles whose route, mode or punctuality moved.
            // Position is left to the interpolation tick.
            for id in diff.updated {
                guard let annotation = annotations[id], let track = interpolator.track(id) else { continue }
                // Captured before the reassignment below: a vehicle turning round
                // at a terminus keeps its fleet number but starts a new trip.
                let previousTrip = annotation.vehicle.gtfsTripID
                annotation.vehicle = track.vehicle
                let route = parent.catalog.route(forVehicle: track.vehicle)
                annotation.routeColorHex = route?.color
                annotation.routeLongName = route?.longName
                // The drawn route and its stops must follow it.
                if id == parent.selectedFleetNumber, previousTrip != track.vehicle.gtfsTripID {
                    overlayFleetNumber = nil
                    updateRouteOverlay(for: id, on: mapView)
                }
                if let view = mapView.view(for: annotation) as? VehicleAnnotationView {
                    view.applyAppearance(annotation, selected: id == parent.selectedFleetNumber)
                }
            }
        }

        // MARK: Interpolation tick

        private func tick() {
            guard let mapView, !annotations.isEmpty else { return }
            let now = Date()

            // Only animate what the user can actually see. Panned-away vehicles keep
            // their data updated but cost nothing to draw.
            let visible = mapView.visibleMapRect.insetBy(
                dx: -mapView.visibleMapRect.size.width * 0.2,
                dy: -mapView.visibleMapRect.size.height * 0.2
            )

            // Moving an annotation costs a KVO round trip through MapKit, so skip
            // anything that would not shift the marker by half a point on screen.
            // Zoomed out over the whole city that silences most of the fleet; zoomed
            // in it changes nothing.
            let metersPerPoint = mapView.visibleMapRect.size.width
                * MKMetersPerMapPointAtLatitude(mapView.region.center.latitude)
                / max(mapView.bounds.width, 1)
            let threshold = 0.5 * metersPerPoint
            let latEpsilon = threshold / 111_320
            let lonEpsilon = latEpsilon / max(cos(mapView.region.center.latitude * .pi / 180), 0.1)

            for (id, annotation) in annotations {
                guard let track = interpolator.track(id) else { continue }
                let coordinate = track.coordinate(at: now)
                guard visible.contains(MKMapPoint(coordinate)) else { continue }
                if abs(coordinate.latitude - annotation.coordinate.latitude) < latEpsilon,
                   abs(coordinate.longitude - annotation.coordinate.longitude) < lonEpsilon {
                    continue
                }

                annotation.coordinate = coordinate
                annotation.heading = track.heading(at: now)
                if let view = mapView.view(for: annotation) as? VehicleAnnotationView {
                    view.applyMotion(annotation)
                }
            }
        }

        // MARK: Selection

        func syncSelection(to fleetNumber: String?) {
            guard let mapView else { return }
            updateRouteOverlay(for: fleetNumber, on: mapView)

            let current = (mapView.selectedAnnotations.first as? VehicleAnnotation)?.fleetNumber
            guard current != fleetNumber else { return }

            isApplyingSelection = true
            defer { isApplyingSelection = false }

            if let fleetNumber, let annotation = annotations[fleetNumber] {
                mapView.selectAnnotation(annotation, animated: true)
                // Bring an off-screen pick into view rather than silently selecting
                // something the user cannot see.
                if !mapView.visibleMapRect.contains(MKMapPoint(annotation.coordinate)) {
                    mapView.setCenter(annotation.coordinate, animated: true)
                }
            } else {
                mapView.selectedAnnotations.forEach { mapView.deselectAnnotation($0, animated: true) }
            }
        }

        // MARK: Route overlay

        /// Draws the selected vehicle's path from `shapes.txt` and the stations it
        /// calls at.
        ///
        /// Both are scoped to the selection. All 945 shapes at once is 170k points
        /// of visual mud, and all 845 stations puts ~990 overlapping dots in the
        /// default viewport. One route's worth of each is legible and meaningful.
        private func updateRouteOverlay(for fleetNumber: String?, on mapView: MKMapView) {
            guard fleetNumber != overlayFleetNumber else { return }
            overlayFleetNumber = fleetNumber

            if let existing = routeOverlay {
                mapView.removeOverlay(existing)
                routeOverlay = nil
            }
            if !stationAnnotations.isEmpty {
                mapView.removeAnnotations(stationAnnotations)
                stationAnnotations = []
            }

            guard let fleetNumber,
                  let vehicle = annotations[fleetNumber]?.vehicle,
                  let tripID = vehicle.gtfsTripID
            else { return }

            let colorHex = parent.catalog.route(forTrip: tripID)?.color

            if let coordinates = parent.catalog.shape(forTrip: tripID), coordinates.count > 1 {
                let polyline = RoutePolyline(coordinates: coordinates, count: coordinates.count)
                polyline.color = colorHex
                mapView.addOverlay(polyline, level: .aboveRoads)
                routeOverlay = polyline
            }

            let stations = parent.catalog.stations(forTrip: tripID)
            guard !stations.isEmpty else { return }
            stationAnnotations = stations.enumerated().map { offset, station in
                StationAnnotation(
                    station: station,
                    sequence: offset + 1,
                    total: stations.count,
                    colorHex: colorHex
                )
            }
            mapView.addAnnotations(stationAnnotations)
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let route = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: route)
            let color = route.color.flatMap(RGBA.init(hex:)) ?? RGBA(0.04, 0.52, 1.00)
            // `strokeColor` is typed as the platform colour, so this is the one
            // place the drawing code has to name it.
            #if os(macOS)
            renderer.strokeColor = NSColor(cgColor: color.withAlpha(0.85).cgColor)
            #else
            renderer.strokeColor = UIColor(cgColor: color.withAlpha(0.85).cgColor)
            #endif
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let station = annotation as? StationAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: StationAnnotationView.reuseIdentifier,
                    for: station
                ) as? StationAnnotationView
                view?.apply(station)
                return view
            }
            guard let vehicle = annotation as? VehicleAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: VehicleAnnotationView.reuseIdentifier,
                for: vehicle
            ) as? VehicleAnnotationView
            view?.applyAppearance(vehicle, selected: vehicle.fleetNumber == parent.selectedFleetNumber)
            view?.applyMotion(vehicle)
            return view
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            // Clicking a stop shows its callout; it is not a vehicle selection.
            if view.annotation is StationAnnotation { return }
            guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
            parent.selectedFleetNumber = annotation.fleetNumber
            (view as? VehicleAnnotationView)?.applyAppearance(annotation, selected: true)
        }

        public func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is StationAnnotation { return }
            guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
            if parent.selectedFleetNumber == annotation.fleetNumber { parent.selectedFleetNumber = nil }
            (view as? VehicleAnnotationView)?.applyAppearance(annotation, selected: false)
        }
    }
}
