import Foundation
import CoreLocation

/// Smooths a vehicle's motion between the discrete fixes the feed gives us.
///
/// The feed reports roughly every few seconds, so drawing raw fixes makes vehicles
/// teleport. Rather than dead-reckoning forward from speed and heading — which
/// overshoots corners and drives buses through buildings — this interpolates
/// *between two known fixes*. The marker trails reality by about one poll interval
/// and in exchange never occupies a position the vehicle did not actually hold.
public struct VehicleTrack: Sendable {

    /// A move faster than this is GPS noise or a reassigned fleet number, not a
    /// trolleybus. Snap rather than slide the marker at an impossible speed.
    private static let maxPlausibleSpeed: CLLocationSpeed = 150 / 3.6  // m/s

    /// Once a vehicle's own fix is this stale, we have no idea what path it took to
    /// get where it now is, so we place it rather than animate a route it may never
    /// have driven. Observed in the wild: a bus sits at a terminus for three minutes,
    /// then reappears 800 m away having turned around and started the return trip.
    private static let staleFixSeconds = 30

    /// Fallback when two fixes are close enough in time that implied speed is noise.
    private static let teleportThresholdMeters: CLLocationDistance = 400

    /// A fix further than this from the route's own path is not that route's
    /// vehicle rounding a corner — it is a diversion, a depot run, or a fix too
    /// poor to trust. Matching is abandoned and the raw position drawn.
    private static let maxMatchOffset: CLLocationDistance = 45

    /// How far either side of the last match to look for the next one. Wide
    /// enough for a bus at 90 km/h between fixes, narrow enough that it cannot
    /// land on the opposite carriageway where the route doubles back.
    private static let matchWindow: CLLocationDistance = 400

    /// Vehicles do not reverse; this much apparent backwards movement is GPS
    /// noise at a standstill, and more than it means the match was wrong.
    private static let maxBacktrack: CLLocationDistance = 30

    public private(set) var vehicle: Vehicle

    private var fromCoordinate: CLLocationCoordinate2D
    private var toCoordinate: CLLocationCoordinate2D
    private var fromHeading: Double
    private var toHeading: Double
    private var startedAt: Date
    private var duration: TimeInterval

    /// The path this vehicle's trip follows, once the timetable has produced it.
    private var path: RoutePath?
    /// Metres along that path at each end of the current leg. Both are set only
    /// while the vehicle is matched to its route; otherwise the raw fixes are used.
    private var fromDistance: CLLocationDistance?
    private var toDistance: CLLocationDistance?

    /// Whether the marker is being drawn on the route's path rather than at the
    /// position the feed reported.
    public var isMatchedToRoute: Bool { path != nil && fromDistance != nil && toDistance != nil }

    public init(vehicle: Vehicle, now: Date = Date(), path: RoutePath? = nil) {
        self.vehicle = vehicle
        self.fromCoordinate = vehicle.coordinate
        self.toCoordinate = vehicle.coordinate
        self.fromHeading = vehicle.heading
        self.toHeading = vehicle.heading
        self.startedAt = now
        self.duration = 0
        self.path = path
        // No previous match to search around, so the whole path is considered.
        if let match = path?.match(vehicle.coordinate), match.offset <= Self.maxMatchOffset {
            fromDistance = match.distanceAlong
            toDistance = match.distanceAlong
        }
    }

    /// Retargets the animation at a fresh fix.
    ///
    /// The new leg starts from wherever the marker is *right now*, not from the
    /// previous fix, so an update arriving mid-glide does not snap backwards.
    public mutating func update(
        with newVehicle: Vehicle,
        now: Date = Date(),
        over duration: TimeInterval,
        path newPath: RoutePath? = nil
    ) {
        let current = coordinate(at: now)
        let currentHeading = heading(at: now)
        let currentDistance = distanceAlong(at: now)
        // A vehicle that reaches a terminus starts a new trip on a new path.
        if newPath !== path {
            path = newPath
            fromDistance = nil
            toDistance = nil
        }
        let previousFix = vehicle.measuredAtSecondsSinceMidnight
        self.vehicle = newVehicle

        let jump = distance(from: current, to: newVehicle.coordinate)

        // Judge plausibility against the *vehicle's* clock, not ours. Fixes arrive
        // at their own cadence — roughly three quarters refresh each 5 s poll, the
        // rest lag — so wall-clock time between polls badly understates how long a
        // move actually took, and would reject real movement as a teleport.
        let fixDelta = FeedClock.interval(from: previousFix, to: newVehicle.measuredAtSecondsSinceMidnight)
        let elapsed = fixDelta.map(Double.init) ?? now.timeIntervalSince(startedAt)

        let isTeleport: Bool
        if let fixDelta, fixDelta > Self.staleFixSeconds {
            isTeleport = true
        } else if elapsed >= 0.5 {
            isTeleport = jump / elapsed > Self.maxPlausibleSpeed
        } else {
            isTeleport = jump > Self.teleportThresholdMeters
        }

        let matched = match(newVehicle.coordinate, from: currentDistance)

        if isTeleport || duration <= 0 {
            fromCoordinate = newVehicle.coordinate
            toCoordinate = newVehicle.coordinate
            fromHeading = newVehicle.heading
            toHeading = newVehicle.heading
            fromDistance = matched
            toDistance = matched
            self.duration = 0
        } else {
            fromCoordinate = current
            toCoordinate = newVehicle.coordinate
            fromHeading = currentHeading
            // A stationary vehicle reports a stale heading; keep the last real one
            // so parked markers do not spin.
            toHeading = jump < 1 ? currentHeading : newVehicle.heading
            self.duration = duration
            if let matched {
                // The leg starts wherever the marker is now, or at the new fix if
                // this is the first one to land on the path.
                let start = currentDistance ?? matched
                fromDistance = start
                // Small backwards jitter at a standstill must not reverse the
                // marker down the road.
                toDistance = max(matched, start)
            } else {
                fromDistance = nil
                toDistance = nil
            }
        }
        startedAt = now
    }

    /// The reported position placed on the route's path, when it can be believed.
    private func match(
        _ coordinate: CLLocationCoordinate2D,
        from current: CLLocationDistance?
    ) -> CLLocationDistance? {
        guard let path else { return nil }
        let nearby = path.match(coordinate, near: current, window: Self.matchWindow)
        // Falling back to the whole path covers a vehicle rejoining its route
        // after a diversion, and its first fix after the shape arrives.
        let candidate = (nearby?.offset ?? .greatestFiniteMagnitude) <= Self.maxMatchOffset
            ? nearby
            : path.match(coordinate)
        guard let candidate, candidate.offset <= Self.maxMatchOffset else { return nil }
        if let current, candidate.distanceAlong < current - Self.maxBacktrack { return nil }
        return candidate.distanceAlong
    }

    /// How far along its path the marker is right now, if it is on it.
    private func distanceAlong(at time: Date) -> CLLocationDistance? {
        guard let from = fromDistance, let to = toDistance else { return nil }
        return from + (to - from) * progress(at: time)
    }

    public func coordinate(at time: Date) -> CLLocationCoordinate2D {
        if let path, let distance = distanceAlong(at: time),
           let position = path.position(at: distance) {
            return position.coordinate
        }
        let fraction = progress(at: time)
        guard fraction < 1 else { return toCoordinate }
        return CLLocationCoordinate2D(
            latitude: fromCoordinate.latitude + (toCoordinate.latitude - fromCoordinate.latitude) * fraction,
            longitude: fromCoordinate.longitude
                + (toCoordinate.longitude - fromCoordinate.longitude) * fraction
        )
    }

    public func heading(at time: Date) -> Double {
        // On the path, the road's own direction is steadier than the feed's
        // heading, which jitters while a vehicle is stopped.
        if vehicle.speed >= 1, let path, let distance = distanceAlong(at: time),
           let position = path.position(at: distance) {
            return position.bearing
        }
        let fraction = progress(at: time)
        guard fraction < 1 else { return toHeading }
        // Take the short way round so a 350 -> 10 turn does not spin 340 degrees.
        var delta = (toHeading - fromHeading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let value = fromHeading + delta * fraction
        return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// True once the marker has reached the latest fix and needs no further redraws.
    public func isSettled(at time: Date) -> Bool { progress(at: time) >= 1 }

    private func progress(at time: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(time.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    private func distance(
        from first: CLLocationCoordinate2D,
        to second: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }
}
