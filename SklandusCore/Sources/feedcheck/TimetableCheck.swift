import Foundation
import SklandusKit

/// Measures the on-demand timetable plan against the real archive.
///
/// The question it answers: what does it cost to load only what the vehicles on
/// screen need, rather than the whole timetable?
enum TimetableCheck {
    static func run() async {
        print("Downloading \(URL.vilniusGTFS.absoluteString)")
        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(from: .vilniusGTFS) else {
            print("  download failed"); return
        }
        let modified = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Last-Modified") ?? "—"
        print("  \((Double(data.count) / 1_048_576).fixed(1)) MB in "
              + "\(Date().timeIntervalSince(started).fixed(1))s   Last-Modified: \(modified)")

        do {
            let archive = try GTFSArchive(data: data)
            let stations = try reportAlwaysLoaded(archive)
            try await reportHydration(archive, stations: stations)
        } catch {
            print("  FAILED: \(error.localizedDescription)")
        }
    }

    /// Routes and stations are small and every vehicle needs them, so they are
    /// stored in full rather than on demand.
    private static func reportAlwaysLoaded(_ archive: GTFSArchive) throws -> [GTFSStation] {
        var mark = Date()
        let routes = try archive.routes()
        let routesTime = Date().timeIntervalSince(mark)

        mark = Date()
        let stations = try archive.stations()
        let stationsTime = Date().timeIntervalSince(mark)

        print("\n  Always loaded:")
        print("    \(routes.count) routes in \(routesTime.fixed(2))s")
        print("    \(stations.count) stations in \(stationsTime.fixed(2))s")
        return stations
    }

    /// What a cold start faces: every trip the fleet is running right now.
    private static func reportHydration(_ archive: GTFSArchive, stations: [GTFSStation]) async throws {
        let client = VehicleFeedClient()
        guard case .snapshot(let snapshot) = try await client.poll() else {
            print("  live poll failed"); return
        }
        await client.stop()

        let wanted = Set(snapshot.vehicles.compactMap(\.gtfsTripID))
        print("\n  Live fleet: \(snapshot.vehicles.count) vehicles, \(wanted.count) distinct trips")

        var mark = Date()
        let trips = try archive.trips(ids: wanted)
        let tripsTime = Date().timeIntervalSince(mark)

        let shapeIDs = Set(trips.compactMap(\.shapeID))
        mark = Date()
        let shapes = try archive.shapes(ids: shapeIDs)
        let shapesTime = Date().timeIntervalSince(mark)

        mark = Date()
        let stopLists = try archive.stopLists(forShapes: shapeIDs, stations: stations)
        let stopsTime = Date().timeIntervalSince(mark)

        let points = shapes.values.reduce(0) { $0 + $1.count }
        print("\n  Hydrating that burst:")
        print("    \(trips.count) trips in \(tripsTime.fixed(2))s")
        print("    \(shapes.count) shapes, \(points) points, in \(shapesTime.fixed(2))s")
        print("    \(stopLists.count) stop lists in \(stopsTime.fixed(2))s")
        print("    total \((tripsTime + shapesTime + stopsTime).fixed(2))s")
        print("\n    joined \(trips.count)/\(wanted.count) trips "
              + "(\(wanted.count - trips.count) are layover movements, absent from the timetable)")

        // Steady state: a few vehicles reach termini and start new trips, so a
        // handful of misses arrive together.
        let sample = Set(wanted.prefix(5))
        guard !sample.isEmpty else { return }
        mark = Date()
        _ = try archive.trips(ids: sample)
        print("\n  A 5-trip miss costs \(Date().timeIntervalSince(mark).fixed(2))s "
              + "— the same scan, which is why misses are batched.")
    }
}
