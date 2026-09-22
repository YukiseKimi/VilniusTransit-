import SklandusKit

/// What the inspector can say about a vehicle's stops.
enum StopListState: Equatable {
    /// Between scheduled runs, so there are no stops to call at.
    case notInService
    /// Running a trip whose stops have not been read from the timetable yet.
    case loading
    case stops([GTFSStation])
}
