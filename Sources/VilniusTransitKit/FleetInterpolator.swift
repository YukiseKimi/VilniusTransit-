import Foundation
import CoreLocation

/// Holds one `VehicleTrack` per fleet number and turns each snapshot into a diff.
///
/// The map layer needs to know what to add, what to move and what to retire — not
/// to rebuild 385 annotations every five seconds.
public struct FleetInterpolator: Sendable {

    public struct Diff: Sendable {
        public var added: [String] = []
        public var updated: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty }
    }

    public private(set) var tracks: [String: VehicleTrack] = [:]

    public init() {}

    /// - Parameter glide: how long markers take to travel to the new fix. Matching
    ///   this to the poll interval keeps motion continuous; a little under it lets
    ///   each leg finish before the next arrives.
    @discardableResult
    public mutating func apply(_ vehicles: [Vehicle], now: Date = Date(), glide: TimeInterval) -> Diff {
        var diff = Diff()
        var seen = Set<String>(minimumCapacity: vehicles.count)

        for vehicle in vehicles {
            seen.insert(vehicle.id)
            if var existing = tracks[vehicle.id] {
                existing.update(with: vehicle, now: now, over: glide)
                tracks[vehicle.id] = existing
                diff.updated.append(vehicle.id)
            } else {
                tracks[vehicle.id] = VehicleTrack(vehicle: vehicle, now: now)
                diff.added.append(vehicle.id)
            }
        }

        for id in tracks.keys where !seen.contains(id) {
            tracks.removeValue(forKey: id)
            diff.removed.append(id)
        }

        return diff
    }

    public func track(_ id: String) -> VehicleTrack? { tracks[id] }
    public var vehicles: [Vehicle] { tracks.values.map(\.vehicle) }
}
