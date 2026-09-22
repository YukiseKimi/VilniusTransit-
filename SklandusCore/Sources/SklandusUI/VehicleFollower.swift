import MapKit

/// Keeps a selected vehicle in view without chasing its every move.
///
/// The map moves only when the vehicle leaves the dead zone in the middle of the
/// view (see `FollowPolicy`), and never while the reader is moving the map.
@MainActor
final class VehicleFollower {
    /// The vehicle the state below belongs to.
    private var fleetNumber: String?
    private var wasFollowing = false
    /// Until then, a vehicle out of view is brought back rather than released:
    /// the map is still resizing around the inspector.
    private var settlingUntil = Date.distantPast
    /// Set while the follower itself moves the map.
    private var isRecentering = false
    /// A move the follower did not make — the reader panning or zooming — is in
    /// progress, or ended at `lastForeignChange`.
    private var isForeignChangeActive = false
    private var lastForeignChange = Date.distantPast
    private var lastRecenter = Date.distantPast

    /// Quiet time after the reader moves the map before following resumes, so
    /// the map does not pull back mid-gesture.
    private static let cooldown: TimeInterval = 1.5
    private static let settlingTime: TimeInterval = 2
    /// Long enough for a recentring animation to finish before another starts.
    private static let recenterInterval: TimeInterval = 0.75

    /// Called every frame with the selected vehicle's position. Returns what was
    /// decided, so the caller can switch following off on `.release`.
    @discardableResult
    func update(
        fleetNumber: String,
        following: Bool,
        coordinate: CLLocationCoordinate2D,
        on mapView: MKMapView,
        at now: Date
    ) -> FollowDecision {
        if fleetNumber != self.fleetNumber || (following && !wasFollowing) {
            settlingUntil = now.addingTimeInterval(Self.settlingTime)
        }
        self.fleetNumber = fleetNumber
        wasFollowing = following

        guard following, now.timeIntervalSince(lastRecenter) > Self.recenterInterval else { return .stay }
        let settling = now < settlingUntil
        if !settling {
            guard !isForeignChangeActive, now.timeIntervalSince(lastForeignChange) > Self.cooldown
            else { return .stay }
        }

        let decision = FollowPolicy.decide(
            for: MKMapPoint(coordinate),
            in: mapView.visibleMapRect,
            settling: settling
        )
        if decision == .recenter {
            isRecentering = true
            mapView.setCenter(coordinate, animated: true)
            isRecentering = false
            lastRecenter = now
        }
        return decision
    }

    func reset() {
        fleetNumber = nil
        wasFollowing = false
    }

    func regionWillChange() {
        guard !isRecentering else { return }
        isForeignChangeActive = true
        lastForeignChange = Date()
    }

    func regionDidChange() {
        guard isForeignChangeActive else { return }
        isForeignChangeActive = false
        lastForeignChange = Date()
    }
}
