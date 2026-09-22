import Testing
import Foundation
import CoreLocation
@testable import SklandusKit

@Suite("Route path cache")
struct RoutePathCacheTests {
    private let points = [
        CLLocationCoordinate2D(latitude: 54.68, longitude: 25.27),
        CLLocationCoordinate2D(latitude: 54.69, longitude: 25.28)
    ]

    @Test("a shape is prepared once and reused")
    func buildsOnce() {
        let cache = RoutePathCache()
        var builds = 0
        let first = cache.path(for: "T1") { builds += 1; return points }
        let second = cache.path(for: "T1") { builds += 1; return points }
        #expect(builds == 1)
        #expect(first === second)
    }

    @Test("a trip with no shape yet produces no path")
    func withoutShape() {
        let cache = RoutePathCache()
        #expect(cache.path(for: "T1") { [] } == nil)
        #expect(cache.isEmpty)
    }

    @Test("paths for trips that have left the feed are dropped")
    func prunes() {
        let cache = RoutePathCache()
        _ = cache.path(for: "T1") { points }
        _ = cache.path(for: "T2") { points }
        cache.keep(only: ["T2"])
        #expect(cache.count == 1)
        #expect(cache.path(for: "T2") { [] } != nil)
    }
}
