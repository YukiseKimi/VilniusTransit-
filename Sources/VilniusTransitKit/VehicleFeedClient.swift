import Foundation
import Network

/// Polls the Vilnius live vehicle feed and publishes decoded snapshots.
///
/// Two things keep this polite to a city-run server, which matters when a 5-second
/// interval works out to ~17k requests a day:
///
/// 1. `If-Modified-Since` is replayed from the previous response's `Last-Modified`,
///    so an unchanged feed costs a 304 with no body and no parse.
/// 2. Failures back off exponentially instead of hammering.
public actor VehicleFeedClient {

    public struct Snapshot: Sendable {
        public let vehicles: [Vehicle]
        public let receivedAt: Date
        public let skippedRows: Int
        /// Wire bytes for this poll; 0 when the server answered 304.
        public let byteCount: Int
    }

    public enum Event: Sendable {
        case snapshot(Snapshot)
        /// Server answered 304 — the previous snapshot is still current.
        case unchanged
        case failure(String)
        case offline
    }

    public enum FeedError: Error, LocalizedError {
        case badStatus(Int)
        public var errorDescription: String? {
            switch self {
            case .badStatus(let code): "Feed returned HTTP \(code)"
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private let pollInterval: Duration
    private let maxBackoff: Duration = .seconds(60)

    private var lastModified: String?
    private var consecutiveFailures = 0
    private var isOnline = true
    private var pathTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    public init(
        url: URL = .vilniusLiveFeed,
        pollInterval: Duration = .seconds(5),
        session: URLSession? = nil
    ) {
        self.url = url
        self.pollInterval = pollInterval
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.waitsForConnectivity = false
            // Identify ourselves; an anonymous 17k/day poller is the kind of thing
            // that gets an IP blocked.
            config.httpAdditionalHeaders = [
                "User-Agent": "VilniusTransit/0.1 (macOS; spike build)"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Streaming

    /// Begins polling and yields every event until the returned stream is cancelled.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(4))

        startPathMonitor()

        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                if await self.isOnline == false {
                    continuation.yield(.offline)
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }

                let event: Event
                do {
                    event = try await self.poll()
                    await self.resetBackoff()
                } catch is CancellationError {
                    break
                } catch {
                    await self.recordFailure()
                    event = .failure(error.localizedDescription)
                }
                continuation.yield(event)

                let delay = await self.currentDelay()
                do { try await Task.sleep(for: delay) } catch { break }
            }
            continuation.finish()
        }

        pollTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        pathTask?.cancel()
        pathTask = nil
    }

    // MARK: - One poll

    /// Fetches once. Exposed so the parser and transport can be exercised without
    /// standing up the whole polling loop.
    public func poll() async throws -> Event {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedError.badStatus(0)
        }

        if http.statusCode == 304 { return .unchanged }
        guard http.statusCode == 200 else { throw FeedError.badStatus(http.statusCode) }

        if let modified = http.value(forHTTPHeaderField: "Last-Modified") {
            lastModified = modified
        }

        let result = VehicleFeedParser.parse(data)
        return .snapshot(
            Snapshot(
                vehicles: result.vehicles,
                receivedAt: Date(),
                skippedRows: result.skippedRows,
                byteCount: data.count
            )
        )
    }

    // MARK: - Backoff & reachability

    private func resetBackoff() { consecutiveFailures = 0 }
    private func recordFailure() { consecutiveFailures = min(consecutiveFailures + 1, 8) }

    private func currentDelay() -> Duration {
        guard consecutiveFailures > 0 else { return pollInterval }
        let scaled = pollInterval * Double(1 << min(consecutiveFailures, 5))
        return min(scaled, maxBackoff)
    }

    private func setOnline(_ online: Bool) { isOnline = online }

    /// Pausing on a dead link avoids burning the backoff budget on requests that
    /// cannot succeed, and makes the app resume instantly when Wi-Fi returns.
    private func startPathMonitor() {
        guard pathTask == nil else { return }
        // NWPathMonitor is an AsyncSequence on macOS 14 / iOS 17, so no dispatch
        // queue or callback is needed; cancelling the task stops the monitor.
        pathTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                await self?.setOnline(path.status == .satisfied)
            }
        }
    }
}
