import Foundation
import OSLog

/// Keeps the timetable archive on disk and refreshes it only when the city
/// publishes a new one.
///
/// The archive is the source every later hydration reads from, so it is kept even
/// after import: a vehicle starting an unseen trip needs to go back to it.
public actor ArchiveCache {

    public struct Fetched: Sendable {
        public let data: Data
        public let lastModified: String?
        public let etag: String?
        /// True when this came off disk rather than the network.
        public let fromCache: Bool
    }

    private let url: URL
    private let session: URLSession
    private let directory: URL
    private let log = Logger(subsystem: "com.yukisekimi.sklandus", category: "archive")

    private var archiveURL: URL { directory.appending(path: "timetable.zip") }
    private var metaURL: URL { directory.appending(path: "timetable-meta.json") }

    private struct Meta: Codable {
        var lastModified: String?
        var etag: String?
    }

    public init(url: URL = .vilniusGTFS, directory: URL? = nil, session: URLSession? = nil) {
        self.url = url
        self.directory = directory
            ?? URL.applicationSupportDirectory.appending(path: "Sklandus", directoryHint: .isDirectory)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.httpAdditionalHeaders = ["User-Agent": "Sklandus/0.1 (macOS; iPadOS)"]
            self.session = URLSession(configuration: config)
        }
    }

    /// The archive as it stands on disk, if it has ever been downloaded.
    public func cached() -> Fetched? {
        guard let data = try? Data(contentsOf: archiveURL) else { return nil }
        let meta = loadMeta()
        return Fetched(data: data, lastModified: meta.lastModified, etag: meta.etag, fromCache: true)
    }

    /// Downloads the archive if the server has a newer one. Nil means 304: what is
    /// on disk is current.
    public func refresh() async throws -> Fetched? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let meta = loadMeta()
        if cached() != nil {
            if let lastModified = meta.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
            if let etag = meta.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 304 {
            log.info("Timetable unchanged (304)")
            return nil
        }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        // Validate before overwriting: a server that hands us something unreadable
        // must not replace an archive that currently works.
        _ = try GTFSArchive(data: data)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: archiveURL, options: .atomic)
        let fresh = Meta(
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            etag: http.value(forHTTPHeaderField: "ETag")
        )
        save(fresh)
        log.info("Downloaded timetable archive, \(data.count) bytes")
        return Fetched(data: data, lastModified: fresh.lastModified, etag: fresh.etag, fromCache: false)
    }

    /// Disk first so the app is usable immediately, network second.
    public func load() async throws -> Fetched {
        if let cached = cached() { return cached }
        guard let fresh = try await refresh() else {
            // A 304 with nothing on disk should be impossible; treat it as failure
            // rather than returning an empty archive that looks like success.
            throw URLError(.resourceUnavailable)
        }
        return fresh
    }

    public func clear() {
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    private func loadMeta() -> Meta {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return Meta() }
        return meta
    }

    private func save(_ meta: Meta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
