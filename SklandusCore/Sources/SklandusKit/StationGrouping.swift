import Foundation
import CoreLocation

/// Merges same-named stops that stand within walking distance of each other.
///
/// Vilnius lists every direction as its own stop: 1,424 of 1,553 stops share a name
/// with at least one other, usually a pair about 26 m apart across a road. Drawn
/// raw that is twin dots on every corner, so they are grouped into stations.
public enum StationGrouping {
    /// Two stops with the same name this close together are one place. 150 m covers
    /// a pair either side of a road (median spread 78 m) without merging same-named
    /// stops that are a real walk apart.
    public static let radius: CLLocationDistance = 150

    public static func stations(from stops: [GTFSStop]) -> [GTFSStation] {
        var byName: [String: [GTFSStop]] = [:]
        for stop in stops {
            byName[stop.name, default: []].append(stop)
        }

        var stations: [GTFSStation] = []
        stations.reserveCapacity(byName.count)

        for (name, group) in byName {
            // Single-link clustering within each name. Groups are tiny — a pair, or
            // a handful at an interchange — so the quadratic inner loop never bites.
            var remaining = group.sorted { $0.id < $1.id }
            while !remaining.isEmpty {
                var cluster = [remaining.removeFirst()]
                var grew = true
                while grew {
                    grew = false
                    for candidate in remaining where cluster.contains(where: {
                        distance($0.coordinate, candidate.coordinate) < radius
                    }) {
                        cluster.append(candidate)
                        remaining.removeAll { $0.id == candidate.id }
                        grew = true
                    }
                }
                stations.append(station(name: name, platforms: cluster))
            }
        }
        return stations.sorted { $0.id < $1.id }
    }

    private static func station(name: String, platforms: [GTFSStop]) -> GTFSStation {
        let ids = platforms.map(\.id).sorted()
        let latitude = platforms.reduce(0.0) { $0 + $1.coordinate.latitude } / Double(platforms.count)
        let longitude = platforms.reduce(0.0) { $0 + $1.coordinate.longitude } / Double(platforms.count)
        return GTFSStation(
            // The lowest-sorting platform, so the id is stable across rebuilds.
            id: ids[0],
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            platformIDs: ids
        )
    }

    private static func distance(
        _ first: CLLocationCoordinate2D,
        _ second: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let deltaLat = (second.latitude - first.latitude) * 111_320
        let deltaLon = (second.longitude - first.longitude) * 111_320 * cos(first.latitude * .pi / 180)
        return (deltaLat * deltaLat + deltaLon * deltaLon).squareRoot()
    }
}
