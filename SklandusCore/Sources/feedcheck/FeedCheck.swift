import Foundation
import SklandusKit

/// Polls the real feed and prints what came back.
///
/// The test suite runs against a recorded fixture so it needs no network; this is
/// the other half, checking the parser and client against the live server. It is
/// how the spike caught a vehicle that had gone stale at a terminus and reappeared
/// 811 m away, which looked like a 584 km/h teleport until measured against the
/// vehicle's own clock.
@main
struct FeedCheck {
    static func main() async {
        switch CommandLine.arguments.dropFirst().first {
        case "gtfs":
            await TimetableCheck.run()
            return
        case "store":
            await StoreCheck.run()
            return
        default:
            break
        }
        let client = VehicleFeedClient(pollInterval: .seconds(5))
        print("Polling \(URL.vilniusLiveFeed.absoluteString)\n")

        guard let first = await poll(client, label: "Poll 1") else { return }

        var interpolator = FleetInterpolator()
        let firstTime = Date()
        interpolator.apply(first.vehicles, now: firstTime, glide: 5)

        // Long enough apart that vehicles have genuinely moved.
        try? await Task.sleep(for: .seconds(6))
        guard let second = await poll(client, label: "\nPoll 2") else { return }

        let secondTime = Date()
        let diff = interpolator.apply(second.vehicles, now: secondTime, glide: 5)
        print("  diff            \(diff.added.count) added, \(diff.updated.count) updated, "
              + "\(diff.removed.count) retired")

        // A track only animates if its endpoints differ; a vehicle whose fix did
        // not refresh is unsettled but going nowhere.
        let moving = second.vehicles.filter { vehicle in
            guard let track = interpolator.track(vehicle.id) else { return false }
            let start = track.coordinate(at: secondTime)
            let end = track.coordinate(at: secondTime.addingTimeInterval(5))
            return start.latitude != end.latitude || start.longitude != end.longitude
        }
        print("  animating       \(moving.count) moving, "
              + "\(second.vehicles.count - moving.count) stationary or snapped")

        if let fastest = moving.max(by: { $0.speed < $1.speed }),
           let track = interpolator.track(fastest.id) {
            print("\n  Interpolating \(fastest.mode.displayName) \(fastest.id) "
                  + "on route \(fastest.route) (\(Int(fastest.speed)) km/h):")
            for step in stride(from: 0.0, through: 5.0, by: 1.25) {
                let at = secondTime.addingTimeInterval(step)
                let point = track.coordinate(at: at)
                print("    t+\(step.fixed(2))s  \(point.latitude.fixed(6)), "
                      + "\(point.longitude.fixed(6))  hdg \(track.heading(at: at).fixed(0))")
            }
        }

        await client.stop()
    }

    private static func poll(
        _ client: VehicleFeedClient,
        label: String
    ) async -> VehicleFeedClient.Snapshot? {
        do {
            switch try await client.poll() {
            case .snapshot(let snapshot):
                report(snapshot, label: label)
                return snapshot
            case .unchanged:
                print("\(label): 304 Not Modified — conditional request worked, no body sent.")
                return nil
            case .offline:
                print("\(label): offline.")
                return nil
            case .failure(let message):
                print("\(label): \(message)")
                return nil
            }
        } catch {
            print("\(label): \(error.localizedDescription)")
            return nil
        }
    }

    private static func report(_ snapshot: VehicleFeedClient.Snapshot, label: String) {
        let vehicles = snapshot.vehicles
        print("\(label): \(vehicles.count) vehicles, \(snapshot.byteCount) bytes, "
              + "\(snapshot.skippedRows) rows skipped")

        for mode in TransitMode.allCases {
            let count = vehicles.count { $0.mode == mode }
            guard count > 0 else { continue }
            print("  \(mode.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(count)")
        }

        let scheduled = vehicles.filter(\.isInService)
        print("  in service   \(scheduled.count)  (\(vehicles.count - scheduled.count) deadheading)")

        // Punctuality is the payoff from the feed's schedule-deviation column.
        let buckets: [(String, Punctuality)] = [
            ("early", .early), ("on time", .onTime), ("late", .late), ("5min+ late", .veryLate)
        ]
        let summary = buckets.compactMap { name, bucket -> String? in
            let count = scheduled.count { $0.punctuality == bucket }
            return count > 0 ? "\(name) \(count)" : nil
        }
        print("  punctuality  \(summary.joined(separator: ", "))")
    }
}
