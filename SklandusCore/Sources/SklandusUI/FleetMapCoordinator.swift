import SwiftUI
import MapKit
import SklandusKit

/// Everything the fleet map does, minus the SwiftUI wrapper.
///
/// Identical on Mac and iPad: only the representable conformance differs, so the
/// diffing, interpolation, culling, selection and overlays all live here.
@MainActor
public final class FleetMapCoordinator: NSObject, MKMapViewDelegate {
    /// The view that owns this coordinator, refreshed on each SwiftUI update.
    var parent: FleetMapView
    private weak var mapView: MKMapView?

    private var interpolator = FleetInterpolator()
    private var stationAnnotations: [StationAnnotation] = []
    private var annotations: [String: VehicleAnnotation] = [:]
    private var lastToken: Int?
    private var lastAppearanceToken: Int?
    private var tickTimer: Timer?
    private var routeOverlay: RoutePolyline?
    /// Set while the coordinator is driving MapKit, so its callbacks are not
    /// mistaken for the user tapping.
    private var isApplyingSelection = false
    private let follower = VehicleFollower()

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
        addAnnotations(for: diff.added, at: now, on: mapView)
        updateAnnotations(for: diff.updated, on: mapView)
    }

    private func addAnnotations(for ids: [String], at now: Date, on mapView: MKMapView) {
        var incoming: [VehicleAnnotation] = []
        incoming.reserveCapacity(ids.count)
        for id in ids {
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
    }

    private func updateAnnotations(for ids: [String], on mapView: MKMapView) {
        for id in ids {
            guard let annotation = annotations[id], let track = interpolator.track(id) else { continue }
            // A vehicle turning round at a terminus keeps its fleet number but
            // starts a new trip, so its route can change underneath it.
            let previousTrip = annotation.vehicle.gtfsTripID
            annotation.vehicle = track.vehicle
            if previousTrip != track.vehicle.gtfsTripID {
                let resolved = parent.resolver?.resolved(track.vehicle.gtfsTripID)
                annotation.routeColorHex = resolved?.routeColor
                annotation.routeLongName = resolved?.routeLongName
                if id == parent.selection {
                    updateRouteOverlay(for: id, on: mapView)
                }
            }
            if let view = mapView.view(for: annotation) as? VehicleAnnotationView {
                view.applyAppearance(annotation, selected: id == parent.selection)
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
                .applyAppearance(annotation, selected: annotation.fleetNumber == parent.selection)
        }
        refreshRouteOverlay()
    }

    // MARK: Motion

    private func tick() {
        guard let mapView, !annotations.isEmpty else { return }
        let now = Date()
        followSelection(on: mapView, at: now)

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

    /// Keeps the selected vehicle in view; the follower decides when.
    private func followSelection(on mapView: MKMapView, at now: Date) {
        guard let fleetNumber = parent.selection, let track = interpolator.track(fleetNumber) else {
            follower.reset()
            return
        }
        let decision = follower.update(
            fleetNumber: fleetNumber,
            following: parent.following,
            coordinate: track.coordinate(at: now),
            on: mapView,
            at: now
        )
        if decision == .release { parent.following = false }
    }

    // MARK: Selection

    /// Mirrors a selection made elsewhere onto the map.
    func syncSelection(to fleetNumber: String?) {
        guard let mapView else { return }
        updateRouteOverlay(for: fleetNumber, on: mapView)

        let selected = mapView.selectedAnnotations.first
        // A stop's callout, opened while its vehicle stays selected.
        if selected is StationAnnotation, fleetNumber != nil { return }
        let current = (selected as? VehicleAnnotation)?.fleetNumber
        guard current != fleetNumber else { return }

        isApplyingSelection = true
        defer { isApplyingSelection = false }

        if let fleetNumber, let annotation = annotations[fleetNumber] {
            mapView.selectAnnotation(annotation, animated: true)
            // Bring an off-screen choice into view rather than selecting
            // something the reader cannot see.
            if !mapView.visibleMapRect.contains(MKMapPoint(annotation.coordinate)) {
                mapView.setCenter(annotation.coordinate, animated: true)
            }
        } else {
            for selected in mapView.selectedAnnotations {
                mapView.deselectAnnotation(selected, animated: true)
            }
        }
    }

    /// Draws the selected vehicle's own path.
    ///
    /// Only the selection gets a line: all 945 route shapes at once is 170,000
    /// points of visual mud, redrawn on every pan.
    private func updateRouteOverlay(for fleetNumber: String?, on mapView: MKMapView) {
        let vehicle = fleetNumber.flatMap { annotations[$0]?.vehicle }
        let tripID = vehicle?.gtfsTripID
        // Nothing to do while the same trip is still drawn. A vehicle turning
        // round at a terminus changes trip, which lands here as a new id.
        guard routeOverlay?.tripID != tripID || tripID == nil else { return }

        if let existing = routeOverlay {
            mapView.removeOverlay(existing)
            routeOverlay = nil
        }
        guard let tripID,
              let resolved = parent.resolver?.resolved(tripID),
              resolved.path.count > 1
        else { return }

        let polyline = RoutePolyline(coordinates: resolved.path, count: resolved.path.count)
        polyline.colorHex = resolved.routeColor
        polyline.tripID = tripID
        mapView.addOverlay(polyline, level: .aboveRoads)
        routeOverlay = polyline
    }

    /// Replaces the stops on the map when the selection's route changes.
    func syncStops(_ stops: [GTFSStation], colorHex: String?) {
        guard let mapView else { return }
        let current = stationAnnotations.map(\.station.id)
        guard current != stops.map(\.id) else { return }

        if !stationAnnotations.isEmpty {
            mapView.removeAnnotations(stationAnnotations)
            stationAnnotations = []
        }
        guard !stops.isEmpty else { return }

        stationAnnotations = stops.enumerated().map { offset, station in
            StationAnnotation(
                station: station,
                sequence: offset + 1,
                total: stops.count,
                colorHex: colorHex
            )
        }
        mapView.addAnnotations(stationAnnotations)
    }

    /// Re-checks the drawn path after hydration, for a vehicle selected before
    /// its route was known.
    func refreshRouteOverlay() {
        guard let mapView, routeOverlay == nil, let selection = parent.selection else { return }
        updateRouteOverlay(for: selection, on: mapView)
    }

    // MARK: MKMapViewDelegate

    public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        follower.regionWillChange()
    }

    public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        follower.regionDidChange()
    }

    public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let route = overlay as? RoutePolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let color = route.colorHex.flatMap(RGBA.init(hex:)) ?? RGBA(0.04, 0.52, 1.00)
        let renderer = MKPolylineRenderer(polyline: route)
        // strokeColor is typed as the platform colour, so this is the one place
        // the drawing code has to name it.
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
        view?.applyAppearance(vehicle, selected: vehicle.fleetNumber == parent.selection)
        view?.applyMotion(vehicle)
        return view
    }

    public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if view.annotation is StationAnnotation { return }
        guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
        parent.selection = annotation.fleetNumber
        (view as? VehicleAnnotationView)?.applyAppearance(annotation, selected: true)
    }

    public func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        if view.annotation is StationAnnotation { return }
        guard !isApplyingSelection, let annotation = view.annotation as? VehicleAnnotation else { return }
        // MapKit selects one annotation at a time, so tapping one of the selected
        // vehicle's stops deselects the vehicle first. Wait to see what was
        // tapped: a stop keeps the vehicle selected, anything else clears it.
        Task { @MainActor [weak self, weak mapView, weak view] in
            guard let self, let mapView else { return }
            if mapView.selectedAnnotations.contains(where: { $0 is StationAnnotation }) { return }
            if self.parent.selection == annotation.fleetNumber { self.parent.selection = nil }
            (view as? VehicleAnnotationView)?.applyAppearance(
                annotation, selected: self.parent.selection == annotation.fleetNumber
            )
        }
    }
}
