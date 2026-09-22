import Testing
import MapKit
@testable import SklandusUI

@Suite("Following a vehicle")
struct FollowPolicyTests {
    private let visible = MKMapRect(x: 0, y: 0, width: 1000, height: 800)

    @Test("inside the dead zone the map stays put")
    func deadZone() {
        for point in [MKMapPoint(x: 500, y: 400), MKMapPoint(x: 260, y: 210), MKMapPoint(x: 740, y: 590)] {
            #expect(FollowPolicy.decide(for: point, in: visible, settling: false) == .stay)
        }
    }

    @Test("reaching the outer band recentres")
    func outerBand() {
        for point in [MKMapPoint(x: 200, y: 400), MKMapPoint(x: 500, y: 790), MKMapPoint(x: 990, y: 10)] {
            #expect(FollowPolicy.decide(for: point, in: visible, settling: false) == .recenter)
        }
    }

    @Test("out of view means the map was moved away, so following stops")
    func release() {
        let away = MKMapPoint(x: 1500, y: 400)
        #expect(FollowPolicy.decide(for: away, in: visible, settling: false) == .release)
    }

    @Test("just after selecting, an out-of-view vehicle is brought back instead")
    func settling() {
        let away = MKMapPoint(x: 1500, y: 400)
        #expect(FollowPolicy.decide(for: away, in: visible, settling: true) == .recenter)
    }
}
