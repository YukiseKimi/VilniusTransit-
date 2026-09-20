import Foundation
import Network

/// Whether the network is usable, as a stream of states.
///
/// Split out of the feed client so that polling logic and reachability can be
/// tested and reasoned about separately; the client only asks "should I poll?".
public actor NetworkReachability {
    private var monitorTask: Task<Void, Never>?
    private(set) var isOnline = true

    public init() {}

    deinit { monitorTask?.cancel() }

    /// Starts watching the network path. Safe to call more than once.
    public func start() {
        guard monitorTask == nil else { return }
        // NWPathMonitor is an AsyncSequence from macOS 14 / iOS 17, so this needs
        // no dispatch queue or callback; cancelling the task stops the monitor.
        monitorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                await self?.update(isOnline: path.status == .satisfied)
            }
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func update(isOnline: Bool) {
        self.isOnline = isOnline
    }
}
