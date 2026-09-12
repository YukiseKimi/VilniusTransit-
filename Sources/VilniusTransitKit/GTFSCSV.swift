import Foundation

/// RFC 4180 CSV reader for the static GTFS files.
///
/// Deliberately separate from `VehicleFeedParser`: the live feed is a flat table
/// with no quoting, so it gets a scanner that assumes that. The GTFS files really
/// do quote — `stops.txt` carries both embedded commas ("visos kryptys,
/// troleibusai") and doubled-quote escapes (`"""D"" stotelė"` for `"D" stotelė`) —
/// and they open with a UTF-8 BOM. Handing either file to the other's parser
/// produces silently wrong data rather than an error.
///
/// Rows are visited through byte ranges so the caller decodes only the columns it
/// wants. `shapes.txt` is 170k rows; materialising every field as a `String` would
/// cost far more than the four values actually needed.
public struct GTFSCSV {

    public enum CSVError: Error, LocalizedError {
        case empty
        case missingColumns([String], available: [String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                "CSV file is empty"
            case .missingColumns(let wanted, let available):
                "Missing column(s) \(wanted.joined(separator: ", ")); file has \(available.joined(separator: ", "))"
            }
        }
    }

    fileprivate struct Field {
        let start: Int
        let end: Int
        /// A quoted field containing `""`, which must be collapsed on decode.
        let hasEscapes: Bool
    }

    /// One row, valid only for the duration of the `forEachRow` callback.
    public struct Row {
        fileprivate let bytes: UnsafeBufferPointer<UInt8>
        fileprivate let fields: UnsafeBufferPointer<Field>

        public var count: Int { fields.count }

        public func string(_ index: Int) -> String {
            guard index >= 0, index < fields.count else { return "" }
            let field = fields[index]
            guard field.end > field.start else { return "" }
            let slice = UnsafeBufferPointer(
                start: bytes.baseAddress! + field.start,
                count: field.end - field.start
            )
            let raw = String(decoding: slice, as: UTF8.self)
            return field.hasEscapes ? raw.replacingOccurrences(of: "\"\"", with: "\"") : raw
        }

        public func isEmpty(_ index: Int) -> Bool {
            guard index >= 0, index < fields.count else { return true }
            return fields[index].end <= fields[index].start
        }

        public func double(_ index: Int) -> Double? {
            guard !isEmpty(index) else { return nil }
            return Double(string(index))
        }

        public func int(_ index: Int) -> Int? {
            guard index >= 0, index < fields.count else { return nil }
            let field = fields[index]
            guard field.end > field.start else { return nil }
            var value = 0
            var i = field.start
            var negative = false
            if bytes[i] == 0x2D { negative = true; i += 1 }
            guard i < field.end else { return nil }
            while i < field.end {
                let byte = bytes[i]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
                i += 1
            }
            return negative ? -value : value
        }
    }

    private let data: Data
    /// Column names in file order, BOM stripped.
    public let columns: [String]
    private let bodyStart: Int

    public init(_ data: Data) throws {
        self.data = data

        var header: [String] = []
        var start = 0
        // A UTF-8 BOM would otherwise become part of the first column's name, so
        // "route_id" would never match.
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            start = 3
        }

        var end = start
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)
            var fields: [Field] = []
            end = Self.scanRow(buffer, from: start, into: &fields)
            header = fields.map { field -> String in
                let slice = UnsafeBufferPointer(
                    start: buffer.baseAddress! + field.start,
                    count: max(0, field.end - field.start)
                )
                return String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        guard !header.isEmpty else { throw CSVError.empty }
        self.columns = header
        self.bodyStart = end
    }

    public func index(of column: String) -> Int? {
        columns.firstIndex(of: column)
    }

    /// Resolves several columns at once so a caller can fail loudly and early when
    /// the feed's shape changes, rather than reading empty strings forever.
    public func indices(of wanted: [String]) throws -> [Int] {
        let resolved = wanted.map { index(of: $0) }
        let missing = zip(wanted, resolved).filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            throw CSVError.missingColumns(missing, available: columns)
        }
        return resolved.compactMap { $0 }
    }

    public func forEachRow(_ body: (Row) throws -> Void) rethrows {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)

            var fields: [Field] = []
            fields.reserveCapacity(columns.count)
            var offset = bodyStart

            while offset < buffer.count {
                fields.removeAll(keepingCapacity: true)
                offset = Self.scanRow(buffer, from: offset, into: &fields)
                // A trailing newline yields one empty field; that is not a row.
                if fields.count == 1, fields[0].end <= fields[0].start { continue }
                guard !fields.isEmpty else { continue }
                try fields.withUnsafeBufferPointer { pointer in
                    try body(Row(bytes: buffer, fields: pointer))
                }
            }
        }
    }

    // MARK: - Scanner

    /// Reads one record starting at `offset`, appending its fields. Returns the
    /// offset of the next record.
    private static func scanRow(
        _ buffer: UnsafeBufferPointer<UInt8>,
        from offset: Int,
        into fields: inout [Field]
    ) -> Int {
        var i = offset

        while true {
            guard i <= buffer.count else { break }

            if i < buffer.count, buffer[i] == 0x22 {  // '"'
                i += 1
                let contentStart = i
                var hasEscapes = false
                while i < buffer.count {
                    if buffer[i] == 0x22 {
                        // A doubled quote is a literal quote, not the end of the field.
                        if i + 1 < buffer.count, buffer[i + 1] == 0x22 {
                            hasEscapes = true
                            i += 2
                            continue
                        }
                        break
                    }
                    i += 1
                }
                fields.append(Field(start: contentStart, end: min(i, buffer.count), hasEscapes: hasEscapes))
                if i < buffer.count { i += 1 }  // closing quote
                // Anything between the closing quote and the delimiter is malformed;
                // skip it rather than swallowing the rest of the file.
                while i < buffer.count, buffer[i] != 0x2C, buffer[i] != 0x0A, buffer[i] != 0x0D {
                    i += 1
                }
            } else {
                let contentStart = i
                while i < buffer.count, buffer[i] != 0x2C, buffer[i] != 0x0A, buffer[i] != 0x0D {
                    i += 1
                }
                fields.append(Field(start: contentStart, end: i, hasEscapes: false))
            }

            if i >= buffer.count { return buffer.count }
            if buffer[i] == 0x2C { i += 1; continue }        // ',' -> next field
            if buffer[i] == 0x0D { i += 1 }                  // CR of a CRLF
            if i < buffer.count, buffer[i] == 0x0A { i += 1 }
            return i
        }
        return buffer.count
    }
}
