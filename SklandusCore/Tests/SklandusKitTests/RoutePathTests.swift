import Testing
import Foundation
import CoreLocation
@testable import SklandusKit

@Suite("Route paths")
struct RoutePathTests {
    /// Degrees of latitude in a metre at any latitude, and of longitude only near
    /// Vilnius — enough to write test positions in metres.
    private static let metre = 1.0 / 111_320
    private static let eastMetre = 1.0 / (111_320 * cos(54.68 * .pi / 180))

    /// A kilometre due east, then a kilometre due north: one square corner to
    /// check that matching follows the bend.
    private func corner() -> RoutePath {
        RoutePath(coordinates: [
            CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27 + 1000 * Self.eastMetre),
            CLLocationCoordinate2D(
                latitude: 54.68 + 1000 * Self.metre,
                longitude: 25.27 + 1000 * Self.eastMetre
            )
        ])
    }

    @Test("the path knows how long it is")
    func length() {
        #expect(abs(corner().length - 2000) < 5)
    }

    @Test("a position beside the road matches the point on it, and says how far off it was")
    func matchesNearby() throws {
        let match = try #require(corner().match(
            CLLocationCoordinate2D(latitude: 54.68 + 20 * Self.metre, longitude: 25.27 + 500 * Self.eastMetre)
        ))
        #expect(abs(match.offset - 20) < 1)
        #expect(abs(match.distanceAlong - 500) < 2)
        #expect(abs(match.coordinate.latitude - 54.68) < 0.00001)
    }

    @Test("distance along the path places a vehicle on the road, pointing down it")
    func positionAlong() throws {
        let path = corner()
        let onFirstLeg = try #require(path.position(at: 500))
        #expect(abs(onFirstLeg.bearing - 90) < 0.5)
        let onSecondLeg = try #require(path.position(at: 1500))
        #expect(abs(onSecondLeg.bearing) < 0.5)
        #expect(abs(onSecondLeg.coordinate.latitude - (54.68 + 500 * Self.metre)) < 0.00001)
    }

    @Test("searching around the last match keeps a vehicle off the opposite carriageway")
    func windowedMatch() throws {
        // Out and back along the same street, 15 m apart.
        let path = RoutePath(coordinates: [
            CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
            CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27 + 1000 * Self.eastMetre),
            CLLocationCoordinate2D(
                latitude: 54.68 + 15 * Self.metre,
                longitude: 25.27 + 1000 * Self.eastMetre
            ),
            CLLocationCoordinate2D(latitude: 54.68 + 15 * Self.metre, longitude: 25.27)
        ])
        // Ten metres up: nearer the return leg, but driving the outbound one.
        let outbound = CLLocationCoordinate2D(
            latitude: 54.68 + 10 * Self.metre,
            longitude: 25.27 + 500 * Self.eastMetre
        )
        let unconstrained = try #require(path.match(outbound))
        #expect(unconstrained.distanceAlong > 1015)
        // Knowing where the vehicle was keeps it on the leg it is driving.
        let constrained = try #require(path.match(outbound, near: 400, window: 400))
        #expect(abs(constrained.distanceAlong - 500) < 2)
    }

    @Test("a path of one point cannot be matched against")
    func degenerate() {
        let path = RoutePath(coordinates: [CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27)])
        #expect(!path.isUsable)
        #expect(path.match(CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27)) == nil)
        #expect(path.position(at: 0) == nil)
    }
}
