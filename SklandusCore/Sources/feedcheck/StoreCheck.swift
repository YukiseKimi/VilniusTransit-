import Foundation
import SwiftData
import SklandusKit

/// Measures the SwiftData store against the real archive and the real fleet.
///
/// The figures to weigh it against, from the in-memory spike: 0.75 s to decode
/// everything, ~55 MB resident, nothing persisted.
enum StoreCheck {
    static func run() async {
        let directory = URL.temporaryDirectory.appending(path: "sklandus-storecheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appending(path: "timetable.store")

            print("Fetching the archive")
            let (data, response) = try await URLSession.shared.data(from: .vilniusGTFS)
            let http = response as? HTTPURLResponse
            let archive = try GTFSArchive(data: data)
            print("  \((Double(data.count) / 1_048_576).fixed(1)) MB")

            let store = try makeStore(at: storeURL)

            var mark = Date()
            try await store.importCatalog(
                from: archive,
                lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
                etag: http?.value(forHTTPHeaderField: "ETag")
            )
            let importTime = Date().timeIntervalSince(mark)
            let afterImport = try await store.counts()
            print("\n  Import (routes + stations): \(importTime.fixed(2))s")
            print("    \(afterImport.routes) routes, \(afterImport.stations) stations")
            print("    store on disk: \(sizeOnDisk(storeURL))")

            // A cold start: every trip the fleet is running now.
            let client = VehicleFeedClient()
            guard case .snapshot(let snapshot) = try await client.poll() else { return }
            await client.stop()
            let wanted = Set(snapshot.vehicles.compactMap(\.gtfsTripID))

            mark = Date()
            let hydrated = try await store.hydrate(trips: wanted, from: archive)
            let hydrateTime = Date().timeIntervalSince(mark)
            let afterHydration = try await store.counts()
            print("\n  Cold hydration of \(wanted.count) trips: \(hydrateTime.fixed(2))s")
            print("    stored \(hydrated) trips, \(afterHydration.shapes) shapes")
            print("    store on disk: \(sizeOnDisk(storeURL))")

            mark = Date()
            var resolved = 0
            for tripID in wanted where try await store.resolved(tripID: tripID) != nil { resolved += 1 }
            let readTime = Date().timeIntervalSince(mark)
            print("\n  Reading all \(resolved) back: \(readTime.fixed(2))s "
                  + "(\((readTime / Double(max(resolved, 1)) * 1000).fixed(2))ms each)")

            // Relaunch: a new store on the same file, with nothing warm.
            let reopened = try makeStore(at: storeURL)
            mark = Date()
            _ = try await reopened.isCatalogLoaded()
            if let first = wanted.first { _ = try await reopened.resolved(tripID: first) }
            print("\n  Reopening the store and reading one trip: "
                  + "\(Date().timeIntervalSince(mark).fixed(2))s")
            print("    (no archive parsed, no network)")
        } catch {
            print("  FAILED: \(error.localizedDescription)")
        }
    }

    private static func makeStore(at url: URL) throws -> TimetableStore {
        let schema = Schema([
            StoredRoute.self, StoredStation.self, StoredTrip.self,
            StoredShape.self, StoredCatalogMeta.self
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
        return TimetableStore(modelContainer: container)
    }

    /// The store plus its write-ahead log and external blobs, which is what the
    /// user's disk actually gives up.
    private static func sizeOnDisk(_ storeURL: URL) -> String {
        let directory = storeURL.deletingLastPathComponent()
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path())) ?? []
        let bytes = files.reduce(0) { total, name in
            let path = directory.appending(path: name).path()
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return total + (size ?? 0)
        }
        return "\((Double(bytes) / 1_048_576).fixed(1)) MB"
    }
}
