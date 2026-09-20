import MapKit

/// The selected vehicle's path, carrying the colour its renderer should use.
///
/// `MKPolyline` has nowhere to put the route's published colour, and the renderer
/// is handed only the overlay, so the colour travels on a subclass.
final class RoutePolyline: MKPolyline {
    /// Six hex digits from the city's data, or nil when the route is unknown.
    var colorHex: String?
    /// The trip this path belongs to, so the map can tell when it is out of date.
    var tripID: String?
}
