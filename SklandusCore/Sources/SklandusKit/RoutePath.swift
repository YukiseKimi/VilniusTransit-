import Foundation
import CoreLocation

/// A trip's shape, prepared for matching vehicles onto it.
///
/// The feed's positions are a few metres out, which at street zoom puts a bus in
/// the buildings beside its road. The city publishes the exact path each trip
/// follows, so a vehicle can be placed on that path instead of where its GPS
/// claims — and moved *along* it between fixes, through bends rather than across
/// them.
///
/// Distances use a flat local approximation rather than great-circle maths: over a
/// city the error is under a metre, and matching walks thousands of segments a
/// second.
public final class RoutePath: Sendable {
    public let coordinates: [CLLocationCoordinate2D]
    /// Metres from the start of the path to each point. One entry per coordinate.
    private let travelled: [CLLocationDistance]
    private let metresPerDegreeLatitude: Double = 111_320
    private let metresPerDegreeLongitude: Double

    public var length: CLLocationDistance { travelled.last ?? 0 }
    public var isUsable: Bool { coordinates.count > 1 }

    public init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        let referenceLatitude = coordinates.first?.latitude ?? 0
        let metresPerLongitude = 111_320 * cos(referenceLatitude * .pi / 180)
        self.metresPerDegreeLongitude = metresPerLongitude

        var running: [CLLocationDistance] = []
        running.reserveCapacity(coordinates.count)
        var total: CLLocationDistance = 0
        var previous: CLLocationCoordinate2D?
        for coordinate in coordinates {
            if let previous {
                let dx = (coordinate.longitude - previous.longitude) * metresPerLongitude
                let dy = (coordinate.latitude - previous.latitude) * 111_320
                total += (dx * dx + dy * dy).squareRoot()
            }
            running.append(total)
            previous = coordinate
        }
        self.travelled = running
    }

    /// The closest point on the path to a reported position.
    ///
    /// - Parameter near: where the vehicle was last matched, if it was. Routes
    ///   double back on themselves and run both ways along one street, so
    ///   searching the whole path every time would let a bus jump to the opposite
    ///   carriageway. Searching around the last match keeps it on its own side.
    /// - Parameter window: how far either side of `near` to search, in metres.
    public func match(
        _ coordinate: CLLocationCoordinate2D,
        near: CLLocationDistance? = nil,
        window: CLLocationDistance = 400
    ) -> PathMatch? {
        guard isUsable else { return nil }
        let targetX = coordinate.longitude * metresPerDegreeLongitude
        let targetY = coordinate.latitude * metresPerDegreeLatitude

        var lower = 0
        var upper = coordinates.count - 2
        if let near {
            lower = segmentIndex(before: near - window)
            upper = min(segmentIndex(before: near + window), coordinates.count - 2)
        }
        guard lower <= upper else { return nil }

        var best: PathMatch?
        for index in lower...upper {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let startX = start.longitude * metresPerDegreeLongitude
            let startY = start.latitude * metresPerDegreeLatitude
            let spanX = end.longitude * metresPerDegreeLongitude - startX
            let spanY = end.latitude * metresPerDegreeLatitude - startY
            let spanLength = spanX * spanX + spanY * spanY

            // How far along this segment the perpendicular from the position falls,
            // clamped so it cannot run off either end.
            var fraction = 0.0
            if spanLength > 0 {
                fraction = ((targetX - startX) * spanX + (targetY - startY) * spanY) / spanLength
                fraction = min(max(fraction, 0), 1)
            }
            let offsetX = targetX - (startX + spanX * fraction)
            let offsetY = targetY - (startY + spanY * fraction)
            let offset = (offsetX * offsetX + offsetY * offsetY).squareRoot()
            guard offset < (best?.offset ?? .greatestFiniteMagnitude) else { continue }

            let segmentLength = travelled[index + 1] - travelled[index]
            best = PathMatch(
                distanceAlong: travelled[index] + segmentLength * fraction,
                offset: offset,
                coordinate: CLLocationCoordinate2D(
                    latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                    longitude: start.longitude + (end.longitude - start.longitude) * fraction
                )
            )
        }
        return best
    }

    /// Where a vehicle that has travelled this far along the path is, and which
    /// way the road points there.
    public func position(
        at distance: CLLocationDistance
    ) -> (coordinate: CLLocationCoordinate2D, bearing: Double)? {
        guard isUsable else { return nil }
        let clamped = min(max(distance, 0), length)
        let index = segmentIndex(before: clamped)
        let start = coordinates[index]
        let end = coordinates[index + 1]
        let segmentLength = travelled[index + 1] - travelled[index]
        let fraction = segmentLength > 0 ? (clamped - travelled[index]) / segmentLength : 0
        let coordinate = CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
        let spanX = (end.longitude - start.longitude) * metresPerDegreeLongitude
        let spanY = (end.latitude - start.latitude) * metresPerDegreeLatitude
        let bearing = (atan2(spanX, spanY) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (coordinate, bearing)
    }

    /// Index of the segment containing a distance along the path.
    private func segmentIndex(before distance: CLLocationDistance) -> Int {
        guard distance > 0 else { return 0 }
        let lastSegment = coordinates.count - 2
        guard distance < length else { return lastSegment }
        var low = 0
        var high = lastSegment
        while low < high {
            let middle = (low + high + 1) / 2
            if travelled[middle] <= distance { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
