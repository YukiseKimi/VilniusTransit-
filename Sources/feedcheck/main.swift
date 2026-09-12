import Foundation
import VilniusTransitKit

/// Diagnostic CLI: proves the feed → parse → interpolate path against the live
/// server without launching the GUI. Useful on its own when the feed misbehaves.
@main
struct FeedCheck {
    static func main() async {
        let client = VehicleFeedClient(pollInterval: .seconds(5))

        print("Polling \(URL.vilniusLiveFeed.absoluteString)\n")

        guard case .snapshot(let first) = try! await client.poll() else {
            print("first poll did not return a snapshot"); exit(1)
        }
        report(first, label: "Poll 1")

        var interpolator = FleetInterpolator()
        let t0 = Date()
        interpolator.apply(first.vehicles, now: t0, glide: 5)

        // Second poll, far enough apart that vehicles have actually moved.
        try? await Task.sleep(for: .seconds(6))
        let second = try! await client.poll()

        switch second {
        case .unchanged:
            print("\nPoll 2: 304 Not Modified — conditional request worked, no body transferred.")
        case .snapshot(let snapshot):
            report(snapshot, label: "\nPoll 2")
            let t1 = Date()
            let diff = interpolator.apply(snapshot.vehicles, now: t1, glide: 5)
            print("  diff            added \(diff.added.count), updated \(diff.updated.count), retired \(diff.removed.count)")

            // A track is only really animating if its endpoints differ; a vehicle
            // whose fix did not refresh is "unsettled" but going nowhere.
            let gliding = snapshot.vehicles.filter { vehicle in
                guard let track = interpolator.track(vehicle.id) else { return false }
                let start = track.coordinate(at: t1)
                let end = track.coordinate(at: t1.addingTimeInterval(5))
                return start.latitude != end.latitude || start.longitude != end.longitude
            }
            print("  animating       \(gliding.count) moving, \(snapshot.vehicles.count - gliding.count) stationary or snapped")

            // Show interpolation doing its job on the fastest vehicle that is
            // genuinely in motion rather than one that merely reports a speed.
            if let fastest = gliding.sorted(by: { $0.speed > $1.speed }).first,
               let track = interpolator.track(fastest.id) {
                print("\n  Interpolating \(fastest.mode.displayName) \(fastest.id) on route \(fastest.route) (\(Int(fastest.speed)) km/h):")
                for step in stride(from: 0.0, through: 5.0, by: 1.25) {
                    let at = t1.addingTimeInterval(step)
                    let c = track.coordinate(at: at)
                    print(String(format: "    t+%.2fs  %.6f, %.6f  hdg %3.0f",
                                 step, c.latitude, c.longitude, track.heading(at: at)))
                }
            }
        default:
            print("\nPoll 2 failed: \(second)")
        }

        await client.stop()
    }

    static func report(_ snapshot: VehicleFeedClient.Snapshot, label: String) {
        let v = snapshot.vehicles
        print("\(label): \(v.count) vehicles, \(snapshot.byteCount) bytes, \(snapshot.skippedRows) rows skipped")
        for mode in TransitMode.allCases {
            let inMode = v.filter { $0.mode == mode }
            guard !inMode.isEmpty else { continue }
            print("  \(mode.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(inMode.count)")
        }
        let scheduled = v.filter(\.isInService)
        print("  in service   \(scheduled.count)  (\(v.count - scheduled.count) deadheading)")

        var buckets: [String: Int] = [:]
        for vehicle in scheduled {
            switch vehicle.punctuality {
            case .early:    buckets["early", default: 0] += 1
            case .onTime:   buckets["on time", default: 0] += 1
            case .late:     buckets["late", default: 0] += 1
            case .veryLate: buckets["5min+ late", default: 0] += 1
            case .unknown:  break
            }
        }
        let summary = ["early", "on time", "late", "5min+ late"]
            .compactMap { name in buckets[name].map { "\(name) \($0)" } }
            .joined(separator: ", ")
        print("  punctuality  \(summary)")
    }
}
