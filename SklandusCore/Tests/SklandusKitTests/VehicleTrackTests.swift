import Testing
import Foundation
import CoreLocation
@testable import SklandusKit

@Suite("Motion interpolation")
struct VehicleTrackTests {

    private func vehicle(id: String = "8008", lat: Double, lon: Double, heading: Double = 0) -> Vehicle {
        Vehicle(
            id: id, mode: .bus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            speed: 30, heading: heading, deviationSeconds: 0,
            measuredAtSecondsSinceMidnight: 48000, headsign: "Test",
            gtfsTripID: "A7-01", vehicleTypeCode: "KWZ"
        )
    }

    @Test("a marker sits still until it is given somewhere to go")
    func startsSettled() {
        let t0 = Date()
        let track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27), now: t0)
        #expect(track.isSettled(at: t0))
        #expect(track.coordinate(at: t0.addingTimeInterval(10)).latitude == 54.68)
    }

    @Test("position is halfway across the leg at half the glide")
    func interpolatesMidpoint() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27), now: t0)
        // ~64 m in 5 s, i.e. about 46 km/h — what a bus between stops actually does.
        track.update(with: vehicle(lat: 54.6805, lon: 25.2705), now: t0, over: 5)

        let mid = track.coordinate(at: t0.addingTimeInterval(2.5))
        #expect(abs(mid.latitude - 54.68025) < 1e-6)
        #expect(abs(mid.longitude - 25.27025) < 1e-6)
    }

    @Test("the leg ends exactly on the reported fix and stays there")
    func clampsAtEnd() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27), now: t0)
        track.update(with: vehicle(lat: 54.6805, lon: 25.2705), now: t0, over: 5)

        let end = track.coordinate(at: t0.addingTimeInterval(60))
        #expect(abs(end.latitude - 54.6805) < 1e-9)
        #expect(track.isSettled(at: t0.addingTimeInterval(5)))
    }

    @Test("heading takes the short way round 0/360")
    func headingWrapsShortest() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27, heading: 350), now: t0)
        track.update(with: vehicle(lat: 54.6805, lon: 25.2705, heading: 10), now: t0, over: 4)

        // Going the long way would put us near 180 at the midpoint.
        let mid = track.heading(at: t0.addingTimeInterval(2))
        #expect(mid > 355 || mid < 5)
    }

    @Test("an implausible jump snaps instead of sliding across the city")
    func snapsOnTeleport() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27), now: t0)
        track.update(with: vehicle(lat: 54.75, lon: 25.40), now: t0, over: 5)

        let immediately = track.coordinate(at: t0.addingTimeInterval(0.01))
        #expect(abs(immediately.latitude - 54.75) < 1e-9)
        #expect(track.isSettled(at: t0))
    }

    @Test("a fix arriving mid-glide continues from where the marker actually is")
    func retargetsWithoutSnapback() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.680, lon: 25.270), now: t0)
        track.update(with: vehicle(lat: 54.6804, lon: 25.270), now: t0, over: 5)

        let halfway = track.coordinate(at: t0.addingTimeInterval(2.5))
        let t1 = t0.addingTimeInterval(2.5)
        track.update(with: vehicle(lat: 54.6808, lon: 25.270), now: t1, over: 5)

        // The new leg must begin at the interpolated position, not jump backwards.
        let resumed = track.coordinate(at: t1)
        #expect(abs(resumed.latitude - halfway.latitude) < 1e-9)
    }

    @Test("a stationary vehicle does not spin on a stale heading")
    func keepsHeadingWhenParked() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.68, lon: 25.27, heading: 90), now: t0)
        track.update(with: vehicle(lat: 54.68, lon: 25.27, heading: 270), now: t0, over: 5)
        #expect(track.heading(at: t0.addingTimeInterval(5)) == 90)
    }
}

@Suite("Fleet diffing")
struct FleetInterpolatorTests {

    private func vehicle(_ id: String, lat: Double = 54.68) -> Vehicle {
        Vehicle(
            id: id, mode: .bus, route: "7",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 25.27),
            speed: 0, heading: 0, deviationSeconds: nil,
            measuredAtSecondsSinceMidnight: 1, headsign: "T",
            gtfsTripID: nil, vehicleTypeCode: "K"
        )
    }

    @Test("first snapshot is all additions")
    func firstSnapshot() {
        var interpolator = FleetInterpolator()
        let diff = interpolator.apply([vehicle("a"), vehicle("b")], glide: 5)
        #expect(Set(diff.added) == ["a", "b"])
        #expect(diff.updated.isEmpty)
        #expect(diff.removed.isEmpty)
    }

    @Test("vehicles that vanish from the feed are retired")
    func retiresMissing() {
        var interpolator = FleetInterpolator()
        interpolator.apply([vehicle("a"), vehicle("b")], glide: 5)
        let diff = interpolator.apply([vehicle("a"), vehicle("c")], glide: 5)

        #expect(diff.added == ["c"])
        #expect(diff.updated == ["a"])
        #expect(diff.removed == ["b"])
        #expect(interpolator.track("b") == nil)
        #expect(interpolator.tracks.count == 2)
    }

    @Test("an unchanged fleet produces no adds or removes")
    func stableFleet() {
        var interpolator = FleetInterpolator()
        interpolator.apply([vehicle("a")], glide: 5)
        let diff = interpolator.apply([vehicle("a", lat: 54.69)], glide: 5)
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.updated == ["a"])
    }
}

@Suite("Teleport detection")
struct TeleportTests {

    /// `fix` is `MatavimoLaikas` — the vehicle's own measurement clock, which is
    /// what plausibility must be judged against.
    private func vehicle(lat: Double, fix: Int) -> Vehicle {
        Vehicle(
            id: "8008", mode: .bus, route: "120",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: 25.27),
            speed: 0, heading: 0, deviationSeconds: nil,
            measuredAtSecondsSinceMidnight: fix, headsign: "T",
            gtfsTripID: nil, vehicleTypeCode: "K"
        )
    }

    @Test("an ordinary 5 s hop between stops animates")
    func normalMoveGlides() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.6800, fix: 49500), now: t0)
        // ~33 m over 5 s of vehicle time: about 24 km/h.
        track.update(with: vehicle(lat: 54.6803, fix: 49505), now: t0.addingTimeInterval(5), over: 5)
        #expect(track.isSettled(at: t0.addingTimeInterval(5)) == false)
    }

    /// Bus 564 on route 120, observed live: parked at the terminus for over three
    /// minutes, then reported 811 m away on the return trip. Wall-clock arithmetic
    /// calls that 584 km/h; the vehicle's own clock calls it 15 km/h. It is real
    /// movement, but we never saw the path, so the marker is placed, not flown.
    @Test("a vehicle that went stale at a terminus is placed, not flown")
    func staleFixSnaps() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.757590, fix: 49503), now: t0)
        track.update(with: vehicle(lat: 54.757688, fix: 49702), now: t0.addingTimeInterval(5), over: 5)
        #expect(track.isSettled(at: t0.addingTimeInterval(5)))
    }

    @Test("an impossible speed within one fix interval is rejected")
    func impossibleSpeedSnaps() {
        let t0 = Date()
        var track = VehicleTrack(vehicle: vehicle(lat: 54.680, fix: 49500), now: t0)
        // ~550 m in 5 s of vehicle time — about 400 km/h. Not a bus.
        track.update(with: vehicle(lat: 54.685, fix: 49505), now: t0.addingTimeInterval(5), over: 5)
        #expect(track.isSettled(at: t0.addingTimeInterval(5)))
    }

    @Test("fix intervals survive the service day rolling past midnight")
    func fixIntervalWraps() {
        #expect(FeedClock.interval(from: 49500, to: 49505) == 5)
        #expect(FeedClock.interval(from: 86395, to: 5) == 10)
        // GTFS night services report past 24:00; 90000 is 01:00 the next day.
        #expect(FeedClock.interval(from: 86390, to: 90000) == 3610)
        #expect(FeedClock.interval(from: 49505, to: 49500) == nil)
    }
}
