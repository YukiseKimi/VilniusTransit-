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

    public private(set) var vehicle: Vehicle

    private var fromCoordinate: CLLocationCoordinate2D
    private var toCoordinate: CLLocationCoordinate2D
    private var fromHeading: Double
    private var toHeading: Double
    private var startedAt: Date
    private var duration: TimeInterval

    public init(vehicle: Vehicle, now: Date = Date()) {
        self.vehicle = vehicle
        self.fromCoordinate = vehicle.coordinate
        self.toCoordinate = vehicle.coordinate
        self.fromHeading = vehicle.heading
        self.toHeading = vehicle.heading
        self.startedAt = now
        self.duration = 0
    }

    /// Retargets the animation at a fresh fix.
    ///
    /// The new leg starts from wherever the marker is *right now*, not from the
    /// previous fix, so an update arriving mid-glide does not snap backwards.
    public mutating func update(with newVehicle: Vehicle, now: Date = Date(), over duration: TimeInterval) {
        let current = coordinate(at: now)
        let currentHeading = heading(at: now)
        let previousFix = vehicle.measuredAtSecondsSinceMidnight
        self.vehicle = newVehicle

        let jump = distance(from: current, to: newVehicle.coordinate)

        // Judge plausibility against the *vehicle's* clock, not ours. Fixes arrive
        // at their own cadence — roughly three quarters refresh each 5 s poll, the
        // rest lag — so wall-clock time between polls badly understates how long a
        // move actually took, and would reject real movement as a teleport.
        let fixDelta = Self.fixInterval(from: previousFix, to: newVehicle.measuredAtSecondsSinceMidnight)
        let elapsed = fixDelta.map(Double.init) ?? now.timeIntervalSince(startedAt)

        let isTeleport: Bool
        if let fixDelta, fixDelta > Self.staleFixSeconds {
            isTeleport = true
        } else if elapsed >= 0.5 {
            isTeleport = jump / elapsed > Self.maxPlausibleSpeed
        } else {
            isTeleport = jump > Self.teleportThresholdMeters
        }

        if isTeleport || duration <= 0 {
            fromCoordinate = newVehicle.coordinate
            toCoordinate = newVehicle.coordinate
            fromHeading = newVehicle.heading
            toHeading = newVehicle.heading
            self.duration = 0
        } else {
            fromCoordinate = current
            toCoordinate = newVehicle.coordinate
            fromHeading = currentHeading
            // A stationary vehicle reports a stale heading; keep the last real one
            // so parked markers do not spin.
            toHeading = jump < 1 ? currentHeading : newVehicle.heading
            self.duration = duration
        }
        startedAt = now
    }

    public func coordinate(at time: Date) -> CLLocationCoordinate2D {
        let t = progress(at: time)
        guard t < 1 else { return toCoordinate }
        return CLLocationCoordinate2D(
            latitude: fromCoordinate.latitude + (toCoordinate.latitude - fromCoordinate.latitude) * t,
            longitude: fromCoordinate.longitude + (toCoordinate.longitude - fromCoordinate.longitude) * t
        )
    }

    public func heading(at time: Date) -> Double {
        let t = progress(at: time)
        guard t < 1 else { return toHeading }
        // Take the short way round so a 350 -> 10 turn does not spin 340 degrees.
        var delta = (toHeading - fromHeading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let value = fromHeading + delta * t
        return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// True once the marker has reached the latest fix and needs no further redraws.
    public func isSettled(at time: Date) -> Bool { progress(at: time) >= 1 }

    private func progress(at time: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(time.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    /// Seconds between two `MatavimoLaikas` readings, allowing for the service day
    /// rolling past midnight. Returns nil if the pair cannot be made sense of.
    static func fixInterval(from: Int, to: Int) -> Int? {
        let day = 86400
        let a = ((from % day) + day) % day
        let b = ((to % day) + day) % day
        var delta = b - a
        if delta < 0 { delta += day }
        // A "gap" of most of a day is a clock artefact, not a stale vehicle.
        return delta > day / 2 ? nil : delta
    }

    private func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
