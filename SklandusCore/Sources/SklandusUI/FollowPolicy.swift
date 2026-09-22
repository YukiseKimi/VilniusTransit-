import MapKit

/// When following a vehicle should move the map.
///
/// Recentring on every fix would keep the map in constant motion, which is
/// tiring to watch and makes the streets around the vehicle impossible to read.
/// Instead the middle of the view is a dead zone: the vehicle travels freely
/// inside it, and the map only moves once the vehicle reaches the outer band.
enum FollowPolicy {
    /// Share of the visible width and height, on each side, that forms the outer
    /// band. A quarter leaves the middle half as the dead zone.
    static let margin = 0.25

    /// - Parameter settling: true just after a vehicle is selected or following
    ///   is switched on, while the map may still be resizing around the
    ///   inspector. A vehicle off-screen then is brought back, not given up on.
    static func decide(for point: MKMapPoint, in visible: MKMapRect, settling: Bool) -> FollowDecision {
        let deadZone = visible.insetBy(
            dx: visible.size.width * margin,
            dy: visible.size.height * margin
        )
        if deadZone.contains(point) { return .stay }
        // A vehicle moves a few dozen metres between fixes and is glided there, so
        // on its own it reaches the band long before the edge. Being wholly out
        // of view means the map was moved away from it.
        if visible.contains(point) || settling { return .recenter }
        return .release
    }
}
