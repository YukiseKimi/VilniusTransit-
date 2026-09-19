import Foundation
import OSLog

/// Downloads, caches and decodes the static GTFS archive.
///
/// The archive changes when schedules change — roughly weekly — so it is cached on
/// disk and re-fetched conditionally. Two consequences shape the API: the app can
/// show a fully joined map instantly from cache while a refresh runs behind it, and
/// it still works offline after the first successful download.
public actor GTFSStore {

    public struct Loaded: Sendable {
        public let catalog: GTFSCatalog
        public let stats: GTFSDecoder.Stats
        /// True when this came off disk rather than the network.
        public let fromCache: Bool
    }

    private let url: URL
    private let session: URLSession
    private let directory: URL
    private let log = Logger(subsystem: "lt.vilnius.transit", category: "gtfs")

    private var archiveURL: URL { directory.appending(path: "gtfs.zip") }
    private var metaURL: URL { directory.appending(path: "gtfs-meta.json") }

    private struct Meta: Codable {
        var lastModified: String?
        var etag: String?
    }

    public init(url: URL = .vilniusGTFS, cacheDirectory: URL? = nil, session: URLSession? = nil) {
        self.url = url
        if let cacheDirectory {
            self.directory = cacheDirectory
        } else {
            self.directory = URL.applicationSupportDirectory.appending(path: "VilniusTransit", directoryHint: .isDirectory)
        }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.httpAdditionalHeaders = ["User-Agent": "VilniusTransit/0.1 (macOS; spike build)"]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Loading

    /// Decodes the cached archive, if one has been downloaded before.
    ///
    /// Kept separate from `refresh()` so the UI can join vehicles to routes on the
    /// very first frame instead of waiting on the network.
    public func cached() -> Loaded? {
        guard FileManager.default.fileExists(atPath: archiveURL.path(percentEncoded: false)) else { return nil }
        do {
            let data = try Data(contentsOf: archiveURL)
            let modified = (try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let (catalog, stats) = try GTFSDecoder.decode(archive: data, publishedAt: modified)
            log.info("Loaded cached GTFS: \(stats.trips) trips, \(stats.shapes) shapes")
            return Loaded(catalog: catalog, stats: stats, fromCache: true)
        } catch {
            // A truncated or half-written archive must not wedge the app forever.
            log.error("Cached GTFS unreadable, discarding: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: metaURL)
            return nil
        }
    }

    /// Fetches the archive if the server has a newer one. Returns nil on 304.
    @discardableResult
    public func refresh() async throws -> Loaded? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let meta = loadMeta()
        if let lastModified = meta.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        if let etag = meta.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 304 {
            log.info("GTFS unchanged (304)")
            return nil
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let published = http.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
        // Decode before writing: a server that hands us something unreadable must
        // not replace a cache that currently works.
        let (catalog, stats) = try GTFSDecoder.decode(archive: data, publishedAt: published)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: archiveURL, options: .atomic)
        save(Meta(
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            etag: http.value(forHTTPHeaderField: "ETag")
        ))

        log.info("Downloaded GTFS: \(stats.trips) trips, \(stats.shapes) shapes, \(data.count) bytes")
        return Loaded(catalog: catalog, stats: stats, fromCache: false)
    }

    /// Cache first, network second — the ordering the UI wants.
    public func load() async throws -> Loaded {
        if let cached = cached() { return cached }
        guard let fresh = try await refresh() else {
            // 304 with no cache on disk should be impossible; treat it as a failure
            // rather than returning an empty catalog that looks like success.
            throw URLError(.resourceUnavailable)
        }
        return fresh
    }

    public func clearCache() {
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    // MARK: - Metadata

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

    /// RFC 1123, which is what `Last-Modified` uses. Locale and zone are pinned
    /// because the format is fixed by the spec, not by the user's settings.
    static func httpDate(_ string: String) -> Date? {
        let strategy = Date.ParseStrategy(
            format: "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: .gmt
        )
        return try? Date(string, strategy: strategy)
    }
}
