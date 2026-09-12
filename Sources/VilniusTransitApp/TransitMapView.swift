import SwiftUI
import MapKit
import VilniusTransitKit

/// `MKMapView` wrapped for SwiftUI.
///
/// SwiftUI's own `Map` rebuilds its content tree on every change, gives no view
/// reuse, and offers no way to move a marker from one coordinate to another. With
/// ~385 vehicles refreshing every few seconds that is the whole problem, so the map
/// itself stays AppKit and everything around it stays SwiftUI.
struct TransitMapView: NSViewRepresentable {

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

    static let vilnius = CLLocationCoordinate2D(latitude: 54.6872, longitude: 25.2797)

    /// Carries the route's published colour to the renderer.
    final class RoutePolyline: MKPolyline {
        var color: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsZoomControls = true
        mapView.showsScale = true
        mapView.isPitchEnabled = false
        mapView.register(VehicleAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: VehicleAnnotationView.reuseIdentifier)
        mapView.setRegion(
            MKCoordinateRegion(center: Self.vilnius,
                               span: MKCoordinateSpan(latitudeDelta: 0.13, longitudeDelta: 0.22)),
            animated: false
        )
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        if let config = mapView.preferredConfiguration as? MKStandardMapConfiguration,
           config.emphasisStyle != emphasis {
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        } else if !(mapView.preferredConfiguration is MKStandardMapConfiguration) {
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: emphasis)
        }

        context.coordinator.ingest(vehicles: vehicles, token: dataToken, glide: glide)
        context.coordinator.syncSelection(to: selectedFleetNumber)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        fileprivate var parent: TransitMapView
        private weak var mapView: MKMapView?

        private var interpolator = FleetInterpolator()
        private var annotations: [String: VehicleAnnotation] = [:]
        private var lastToken: Int?
        private var tickTimer: Timer?
        private var isApplyingSelection = false
        private var routeOverlay: RoutePolyline?
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
                annotation.vehicle = track.vehicle
                // A vehicle changes trip at a terminus, so its route can change
                // under the same fleet number.
                let route = parent.catalog.route(forVehicle: track.vehicle)
                annotation.routeColorHex = route?.color
                annotation.routeLongName = route?.longName
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

        /// Draws the selected vehicle's own path from `shapes.txt`.
        ///
        /// Only the selection gets a polyline: all 945 route shapes at once is
        /// 170k points of visual mud, and MapKit would redraw every one of them on
        /// each pan.
        private func updateRouteOverlay(for fleetNumber: String?, on mapView: MKMapView) {
            guard fleetNumber != overlayFleetNumber else { return }
            overlayFleetNumber = fleetNumber

            if let existing = routeOverlay {
                mapView.removeOverlay(existing)
                routeOverlay = nil
            }
            guard let fleetNumber,
                  let vehicle = annotations[fleetNumber]?.vehicle,
                  let tripID = vehicle.gtfsTripID,
                  let coordinates = parent.catalog.shape(forTrip: tripID),
                  coordinates.count > 1
            else { return }

            let polyline = RoutePolyline(coordinates: coordinates, count: coordinates.count)
            polyline.color = parent.catalog.route(forTrip: tripID)?.color
            mapView.addOverlay(polyline, level: .aboveRoads)
            routeOverlay = polyline
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let route = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: route)
            let color = route.color.flatMap(MarkerImages.color(hex:)) ?? .systemBlue
            renderer.strokeColor = color.withAlphaComponent(0.85)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let vehicle = annotation as? VehicleAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: VehicleAnnotationView.reuseIdentifier,
                for: vehicle
            ) as? VehicleAnnotationView
            view?.applyAppearance(vehicle, selected: vehicle.fleetNumber == parent.selectedFleetNumber)
            view?.applyMotion(vehicle)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
            parent.selectedFleetNumber = annotation.fleetNumber
            (view as? VehicleAnnotationView)?.applyAppearance(annotation, selected: true)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
            if parent.selectedFleetNumber == annotation.fleetNumber { parent.selectedFleetNumber = nil }
            (view as? VehicleAnnotationView)?.applyAppearance(annotation, selected: false)
        }
    }
}
