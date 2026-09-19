import Foundation
import VilniusTransitKit

/// Diagnostic CLI: proves the feed → parse → interpolate path against the live
/// server without launching the GUI. Useful on its own when the feed misbehaves.
@main
struct FeedCheck {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "gtfs" {
            await checkGTFS()
            return
        }
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
                    print("    t+\(step.fixed(2))s  \(c.latitude.fixed(6)), \(c.longitude.fixed(6))  hdg \(track.heading(at: at).fixed(0))")
                }
            }
        default:
            print("\nPoll 2 failed: \(second)")
        }

        await client.stop()
    }

    /// Downloads the real archive and decodes it, reporting what the join buys.
    static func checkGTFS() async {
        print("Downloading \(URL.vilniusGTFS.absoluteString)")
        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(from: .vilniusGTFS) else {
            print("download failed"); exit(1)
        }
        let modified = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified")
        print("  \((Double(data.count) / 1_048_576).fixed(1)) MB in \(Date().timeIntervalSince(started).fixed(1))s   Last-Modified: \(modified ?? "—")")

        do {
            let archive = try ZIPArchive(data: data)
            print("\n  Archive contents:")
            for entry in archive.entries.sorted(by: { $0.uncompressedSize > $1.uncompressedSize }) {
                let used = GTFSDecoder.required.contains(entry.name)
                let size = (Double(entry.uncompressedSize) / 1024).fixed(1)
                print("    \(entry.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(size) KB  \(used ? "inflated" : "skipped")")
            }

            let (catalog, stats) = try GTFSDecoder.decode(archive: data)
            print("\n  Decoded in \(stats.duration.fixed(2))s: \(stats.routes) routes, \(stats.trips) trips, \(stats.shapes) shapes (\(stats.shapePoints) points)")
            print("    \(stats.stops) stops grouped into \(stats.stations) stations")
            print("    \(stats.shapesWithStops) of \(stats.shapes) shapes have a stop list")

            // The whole point: can we join live vehicles to the timetable?
            let client = VehicleFeedClient()
            guard case .snapshot(let snapshot) = try await client.poll() else {
                print("  live poll failed"); return
            }
            await client.stop()

            let inService = snapshot.vehicles.filter(\.isInService)
            let joined = inService.filter { catalog.route(forVehicle: $0) != nil }
            let withShape = inService.filter {
                $0.gtfsTripID.flatMap { catalog.shape(forTrip: $0) } != nil
            }
            print("\n  Live join against \(snapshot.vehicles.count) vehicles:")
            print("    in service          \(inService.count)")
            print("    matched a GTFS trip \(joined.count)")
            print("    have a route shape  \(withShape.count)")

            if let sample = withShape.first,
               let tripID = sample.gtfsTripID,
               let route = catalog.route(forTrip: tripID),
               let shape = catalog.shape(forTrip: tripID) {
                print("\n  Example — \(sample.mode.displayName) \(sample.id):")
                print("    feed says route   \(sample.route), towards \(sample.headsign)")
                print("    GTFS says         \(route.shortName) — \(route.longName)")
                print("    route_type        \(route.routeType)   colour #\(route.color) on #\(route.textColor)")
                print("    shape             \(shape.count) points")
                let calls = catalog.stations(forTrip: tripID)
                print("    calls at          \(calls.count) stations")
                print("      " + calls.prefix(4).map(\.name).joined(separator: " -> ") + " -> …")
            }

            // Does the feed's own route label agree with the timetable's?
            let disagreeing = joined.filter { vehicle in
                catalog.route(forVehicle: vehicle)?.shortName != vehicle.route
            }
            print("\n    route label disagreements: \(disagreeing.count)")
            for vehicle in disagreeing.prefix(5) {
                print("      fleet \(vehicle.id): feed \"\(vehicle.route)\" vs GTFS \"\(catalog.route(forVehicle: vehicle)?.shortName ?? "?")\"")
            }
        } catch {
            print("  FAILED: \(error.localizedDescription)")
            exit(1)
        }
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

private extension Double {
    /// Fixed decimal places via FormatStyle rather than C-style `String(format:)`.
    func fixed(_ places: Int) -> String {
        formatted(.number.precision(.fractionLength(places)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
