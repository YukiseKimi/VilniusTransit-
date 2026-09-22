import MapKit
import SklandusKit

/// The stops drawn on the map, which are the selected vehicle's and no others.
///
/// All 845 stations at once puts ~990 overlapping dots in the default view; one
/// route's worth is 13 to 40, and each one means something: this vehicle will
/// call there.
@MainActor
final class StopLayer {
    private var annotations: [StationAnnotation] = []

    var isEmpty: Bool { annotations.isEmpty }

    /// Replaces what is drawn when the selection's route changes. Comparing the
    /// stations first keeps a redraw of the same route free.
    func sync(_ stations: [GTFSStation], colorHex: String?, on mapView: MKMapView) {
        guard annotations.map(\.station.id) != stations.map(\.id) else { return }

        if !annotations.isEmpty {
            mapView.removeAnnotations(annotations)
            annotations = []
        }
        guard !stations.isEmpty else { return }

        annotations = stations.enumerated().map { offset, station in
            StationAnnotation(
                station: station,
                sequence: offset + 1,
                total: stations.count,
                colorHex: colorHex
            )
        }
        mapView.addAnnotations(annotations)
    }
}
