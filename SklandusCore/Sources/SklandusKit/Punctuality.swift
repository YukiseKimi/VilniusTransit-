import Foundation
import CoreLocation

/// How far a vehicle is from its timetable, bucketed for display.
public enum Punctuality: Sendable, Hashable {
    case early       // more than 60s ahead
    case onTime      // within +/- 60s
    case late        // 60s..300s behind
    case veryLate    // more than 300s behind
    case unknown     // vehicle is not on a scheduled trip

    init(deviationSeconds: Int?) {
        guard let deviation = deviationSeconds else { self = .unknown; return }
        switch deviation {
        case ..<(-60):   self = .early
        case -60...60:   self = .onTime
        case 61...300:   self = .late
        default:         self = .veryLate
        }
    }
}
