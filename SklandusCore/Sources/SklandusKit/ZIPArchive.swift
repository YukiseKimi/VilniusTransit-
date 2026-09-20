import Foundation
import Compression

/// Minimal read-only ZIP reader built on the Compression framework.
///
/// Foundation has no unzip API and the obvious packages are third-party, but the
/// format is simple enough to read directly — and doing so buys something a
/// convenience API would not: entries are decompressed **selectively**. The Vilnius
/// GTFS archive is 39 MB unpacked, 27 MB of which is `stop_times.txt` that a live
/// map never reads. Parsing the central directory lets us skip it entirely rather
/// than inflate it and throw it away.
public struct ZIPArchive: Sendable {

    public struct Entry: Sendable {
        public let name: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        /// 0 = stored, 8 = deflate. Nothing else appears in GTFS archives.
        let method: UInt16
        let localHeaderOffset: Int
    }

    public enum ZIPError: Error, LocalizedError {
        case notAZIP
        case unsupportedZIP64
        case unsupportedCompression(UInt16)
        case corruptEntry(String)
        case inflateFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAZIP:                      "Not a ZIP archive (no end-of-central-directory record)"
            case .unsupportedZIP64:             "ZIP64 archives are not supported"
            case .unsupportedCompression(let method): "Unsupported ZIP compression method \(method)"
            case .corruptEntry(let name):       "Corrupt ZIP entry: \(name)"
            case .inflateFailed(let name):      "Failed to inflate: \(name)"
            }
        }
    }

    private let data: Data
    public let entries: [Entry]

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Inflates one entry. Returns nil if the archive has no such file, so a feed
    /// that drops an optional GTFS file does not become a crash.
    public func contents(of name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry)
    }

    public func contents(of entry: Entry) throws -> Data {
        // The central directory's copy of the extra-field length is allowed to
        // differ from the local header's, so the payload offset must be computed
        // from the local header.
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.u32(data, header) == 0x04034b50 else {
            throw ZIPError.corruptEntry(entry.name)
        }
        let nameLength = Int(Self.u16(data, header + 26))
        let extraLength = Int(Self.u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= data.count else { throw ZIPError.corruptEntry(entry.name) }

        let payload = data[start..<end]

        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(payload, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZIPError.unsupportedCompression(entry.method)
        }
    }

    // MARK: - Inflate

    private func inflate(_ payload: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                // Apple's COMPRESSION_ZLIB consumes *raw* DEFLATE (RFC 1951) with no
                // zlib wrapper, which is exactly what ZIP stores.
                return compression_decode_buffer(
                    dstBase, expectedSize,
                    srcBase, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZIPError.inflateFailed(name) }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        guard let eocd = findEOCD(data) else { throw ZIPError.notAZIP }

        let entryCount = Int(u16(data, eocd + 10))
        var offset = Int(u32(data, eocd + 16))
        // 0xFFFF / 0xFFFFFFFF sentinels mean the real values live in a ZIP64 record.
        guard entryCount != 0xFFFF, offset != 0xFFFF_FFFF else { throw ZIPError.unsupportedZIP64 }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x02014b50 else {
                throw ZIPError.notAZIP
            }
            let method = u16(data, offset + 10)
            let compressed = Int(u32(data, offset + 20))
            let uncompressed = Int(u32(data, offset + 24))
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let localOffset = Int(u32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw ZIPError.notAZIP }
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)

            entries.append(Entry(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                method: method,
                localHeaderOffset: localOffset
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The end-of-central-directory record sits at the very end, unless a trailing
    /// comment pushes it back — so scan the last 64 KB plus the record itself.
    private static func findEOCD(_ data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let limit = max(0, data.count - minimum - 0xFFFF)
        var index = data.count - minimum
        while index >= limit {
            if u32(data, index) == 0x06054b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Little-endian scalars

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}
