/// What the map should do about a followed vehicle on this frame.
enum FollowDecision: Equatable {
    /// Comfortably in view: leave the map alone.
    case stay
    /// Drifting towards the edge: bring it back to the centre.
    case recenter
    /// Gone from view: the reader has moved the map elsewhere, so stop following.
    case release
}
