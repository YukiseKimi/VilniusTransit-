import Foundation

/// What the stored timetable is doing.
public enum TimetableStatus: Sendable, Equatable {
    case loading
    /// Routes and stations are in place; trips arrive as vehicles need them.
    case ready(routes: Int, stations: Int)
    /// The map still works from the feed's own labels.
    case failed(String)
}
