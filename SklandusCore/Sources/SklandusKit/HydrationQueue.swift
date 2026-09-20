import Foundation
import OSLog

/// Collects missing trips and hydrates them in one pass.
///
/// Reading any trip out of the archive inflates a whole file, so one trip costs
/// what four hundred cost. Misses also arrive in bursts, as vehicles reach termini
/// and start new trips within seconds of each other. Both facts point the same way:
/// wait a moment, gather what is missing, then read once.
public actor HydrationQueue {

    /// How long to gather misses before reading. Long enough to catch a burst,
    /// short enough that a selected vehicle's route appears promptly.
    public static let coalescingWindow: Duration = .milliseconds(250)

    private let store: TimetableStore
    private let archives: ArchiveCache
    private let window: Duration
    private let log = Logger(subsystem: "com.yukisekimi.sklandus", category: "hydration")

    private var pending: Set<String> = []
    private var flushTask: Task<Void, Never>?
    /// Trips the archive does not contain — layover movements, mostly. Remembered
    /// so a vehicle running one does not re-trigger a scan on every poll.
    private var knownAbsent: Set<String> = []

    public init(
        store: TimetableStore,
        archives: ArchiveCache,
        window: Duration = HydrationQueue.coalescingWindow
    ) {
        self.store = store
        self.archives = archives
        self.window = window
    }

    /// Notes that these trips are wanted. Returns immediately; hydration happens
    /// after the coalescing window.
    public func request(trips wanted: Set<String>) async {
        let candidates = wanted.subtracting(knownAbsent)
        guard !candidates.isEmpty else { return }
        guard let missing = try? await store.missingTrips(from: candidates), !missing.isEmpty else { return }

        pending.formUnion(missing)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.window ?? Self.coalescingWindow)
            await self?.flush()
        }
    }

    /// Hydrates everything gathered so far. Exposed so a cold start can skip the
    /// wait, and so tests need no sleeping.
    public func flush() async {
        flushTask = nil
        let wanted = pending
        pending = []
        guard !wanted.isEmpty else { return }

        do {
            let archive = try GTFSArchive(data: try await archives.load().data)
            let hydrated = try await store.hydrate(trips: wanted, from: archive)
            // Whatever is still missing after a successful read is not in the
            // archive at all — a layover movement. Stop asking for it.
            knownAbsent.formUnion(try await store.missingTrips(from: wanted))
            log.info("Hydrated \(hydrated) of \(wanted.count) requested trips")
        } catch {
            // Put them back: a failed read is usually a missing archive on first
            // run, and the next request should try again.
            pending.formUnion(wanted)
            log.error("Hydration failed: \(error.localizedDescription)")
        }
    }

    public var pendingCount: Int { pending.count }
    public var absentCount: Int { knownAbsent.count }
}
