import Foundation
import SwiftData
import CoreLocation
import OSLog

/// The stored timetable: routes and stations in full, trips and shapes on demand.
///
/// Reading anything out of the archive means inflating a whole file, so this never
/// hydrates a single trip on its own — callers hand it the set of trips they are
/// missing and it serves them all in one pass. `HydrationQueue` is what gathers
/// those misses.
@ModelActor
public actor TimetableStore {
    private static let log = Logger(subsystem: "com.yukisekimi.sklandus", category: "timetable")

    /// Shapes untouched for this long are dropped, keeping the store proportional
    /// to the routes actually watched rather than to the whole city.
    public static let shapeLifetime: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Import

    /// Replaces routes and stations, and records which archive they came from.
    ///
    /// Trip ids embed a schedule version, so when the archive changes, everything
    /// hydrated from the old one is dropped rather than left to stop matching
    /// silently.
    public func importCatalog(from archive: GTFSArchive, lastModified: String?, etag: String?) throws {
        let existing = try currentMeta()
        let archiveChanged = existing?.lastModified != lastModified || existing?.etag != etag

        if archiveChanged {
            try modelContext.delete(model: StoredRoute.self)
            try modelContext.delete(model: StoredStation.self)
            try modelContext.delete(model: StoredTrip.self)
            try modelContext.delete(model: StoredShape.self)
        }

        for route in try archive.routes() {
            modelContext.insert(StoredRoute(
                id: route.id,
                shortName: route.shortName,
                longName: route.longName,
                routeType: route.routeType,
                color: route.color,
                textColor: route.textColor
            ))
        }
        for station in try archive.stations() {
            modelContext.insert(StoredStation(
                id: station.id,
                name: station.name,
                coordinate: station.coordinate,
                platformIDs: station.platformIDs
            ))
        }

        if let existing { modelContext.delete(existing) }
        modelContext.insert(StoredCatalogMeta(lastModified: lastModified, etag: etag))
        try modelContext.save()
        Self.log.info("Imported catalog; archive changed: \(archiveChanged)")
    }

    public func isCatalogLoaded() throws -> Bool {
        try modelContext.fetchCount(FetchDescriptor<StoredRoute>()) > 0
    }

    public func archiveIdentity() throws -> (lastModified: String?, etag: String?)? {
        guard let meta = try currentMeta() else { return nil }
        return (meta.lastModified, meta.etag)
    }

    // MARK: - Hydration

    /// Of these trips, the ones not yet stored.
    public func missingTrips(from wanted: Set<String>) throws -> Set<String> {
        guard !wanted.isEmpty else { return [] }
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredTrip>(predicate: #Predicate { wanted.contains($0.id) })
        )
        return wanted.subtracting(stored.map(\.id))
    }

    /// Reads these trips out of the archive and stores them, along with any shapes
    /// and stop lists they need that are not stored yet.
    @discardableResult
    public func hydrate(trips wanted: Set<String>, from archive: GTFSArchive) throws -> Int {
        guard !wanted.isEmpty else { return 0 }

        let trips = try archive.trips(ids: wanted)
        for trip in trips {
            modelContext.insert(StoredTrip(
                id: trip.id,
                routeID: trip.routeID,
                headsign: trip.headsign,
                directionID: trip.directionID,
                shapeID: trip.shapeID
            ))
        }

        let needed = Set(trips.compactMap(\.shapeID))
        let missingShapes = try missingShapes(from: needed)
        if !missingShapes.isEmpty {
            let stations = try storedStations()
            let paths = try archive.shapes(ids: missingShapes)
            let stopLists = try archive.stopLists(forShapes: missingShapes, stations: stations)
            for (id, path) in paths {
                modelContext.insert(StoredShape(
                    id: id,
                    path: path,
                    stationIDs: stopLists[id] ?? []
                ))
            }
        }

        try modelContext.save()
        Self.log.info("Hydrated \(trips.count) trips, \(missingShapes.count) shapes")
        return trips.count
    }

    private func missingShapes(from wanted: Set<String>) throws -> Set<String> {
        guard !wanted.isEmpty else { return [] }
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredShape>(predicate: #Predicate { wanted.contains($0.id) })
        )
        return wanted.subtracting(stored.map(\.id))
    }

    // MARK: - Reading

    /// Everything the UI needs about one running vehicle's trip, or nil when the
    /// trip is not stored — which is normal both before hydration and for the 1–3%
    /// of layover movements the timetable never contains.
    public func resolved(tripID: String) throws -> ResolvedTrip? {
        var descriptor = FetchDescriptor<StoredTrip>(predicate: #Predicate { $0.id == tripID })
        descriptor.fetchLimit = 1
        guard let trip = try modelContext.fetch(descriptor).first else { return nil }

        let routeID = trip.routeID
        var routeDescriptor = FetchDescriptor<StoredRoute>(predicate: #Predicate { $0.id == routeID })
        routeDescriptor.fetchLimit = 1
        let route = try modelContext.fetch(routeDescriptor).first

        var path: [CLLocationCoordinate2D] = []
        var stationIDs: [String] = []
        if let shapeID = trip.shapeID {
            var shapeDescriptor = FetchDescriptor<StoredShape>(predicate: #Predicate { $0.id == shapeID })
            shapeDescriptor.fetchLimit = 1
            if let shape = try modelContext.fetch(shapeDescriptor).first {
                path = shape.path
                stationIDs = shape.stationIDs
                // Touched, so eviction keeps what is in use.
                shape.lastUsed = Date()
            }
        }

        return ResolvedTrip(
            tripID: trip.id,
            headsign: trip.headsign,
            routeShortName: route?.shortName ?? "",
            routeLongName: route?.longName ?? "",
            routeColor: route?.color,
            routeType: route?.routeType,
            path: path,
            stationIDs: stationIDs
        )
    }

    public func stations(ids: [String]) throws -> [GTFSStation] {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        let stored = try modelContext.fetch(
            FetchDescriptor<StoredStation>(predicate: #Predicate { wanted.contains($0.id) })
        )
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        // Call order matters, so follow the ids given rather than the fetch order.
        return ids.compactMap { id in
            guard let station = byID[id] else { return nil }
            return GTFSStation(
                id: station.id,
                name: station.name,
                coordinate: station.coordinate,
                platformIDs: station.platformIDs
            )
        }
    }

    public func counts() throws -> StoredCounts {
        StoredCounts(
            routes: try modelContext.fetchCount(FetchDescriptor<StoredRoute>()),
            stations: try modelContext.fetchCount(FetchDescriptor<StoredStation>()),
            trips: try modelContext.fetchCount(FetchDescriptor<StoredTrip>()),
            shapes: try modelContext.fetchCount(FetchDescriptor<StoredShape>())
        )
    }

    // MARK: - Eviction

    /// Drops shapes unused for longer than `shapeLifetime`, and any trip left
    /// pointing at one.
    @discardableResult
    public func evictStaleShapes(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.shapeLifetime)
        let stale = try modelContext.fetch(
            FetchDescriptor<StoredShape>(predicate: #Predicate { $0.lastUsed < cutoff })
        )
        guard !stale.isEmpty else { return 0 }

        let staleIDs = Set(stale.map(\.id))
        for shape in stale { modelContext.delete(shape) }
        let orphans = try modelContext.fetch(
            FetchDescriptor<StoredTrip>(predicate: #Predicate { trip in
                if let shapeID = trip.shapeID { return staleIDs.contains(shapeID) } else { return false }
            })
        )
        for trip in orphans { modelContext.delete(trip) }

        try modelContext.save()
        Self.log.info("Evicted \(stale.count) shapes and \(orphans.count) trips")
        return stale.count
    }

    private func currentMeta() throws -> StoredCatalogMeta? {
        var descriptor = FetchDescriptor<StoredCatalogMeta>()
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedStations() throws -> [GTFSStation] {
        try modelContext.fetch(FetchDescriptor<StoredStation>()).map { station in
            GTFSStation(
                id: station.id,
                name: station.name,
                coordinate: station.coordinate,
                platformIDs: station.platformIDs
            )
        }
    }
}
