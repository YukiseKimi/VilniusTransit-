import Foundation
import CoreLocation

/// Parser for `https://stops.lt/vilnius/gps_full.txt`.
///
/// The feed is a flat comma-separated table with no quoting and no escaping — every
/// row observed carries exactly 17 fields plus a trailing comma. That lets us scan
/// the raw bytes directly instead of building a `String` and slicing it, which keeps
/// a poll allocation-light: one pass, one `String` per text field we actually keep.
///
/// The parser never throws on a malformed row. A single bad line must not cost you
/// the other 384 vehicles, so rows that fail validation are counted and dropped.
public enum VehicleFeedParser {

    /// Column order of `gps_full.txt`, as published.
    private enum Column {
        static let transportas = 0          // vehicle class
        static let marsrutas = 1            // route short name
        static let masinosNumeris = 3       // fleet number
        static let ilguma = 4               // longitude x 1e6
        static let platuma = 5              // latitude x 1e6
        static let greitis = 6              // km/h
        static let azimutas = 7             // degrees from north
        static let nuokrypisSekundemis = 9  // schedule deviation, seconds
        static let matavimoLaikas = 10      // seconds since local midnight
        static let masinosTipas = 11        // opaque vehicle attribute code
        static let krypciesPavadinimas = 13 // headsign
        static let reisoIdGTFS = 14         // joins trips.trip_id
        static let required = 15            // we need indices 0...14 to exist
    }

    public struct Result: Sendable {
        public var vehicles: [Vehicle]
        /// Data rows the parser rejected. Persistently non-zero means the feed
        /// format moved and the column map above needs revisiting.
        public var skippedRows: Int
    }

    public static func parse(_ data: Data) -> Result {
        var vehicles: [Vehicle] = []
        vehicles.reserveCapacity(512)
        var skipped = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buffer = UnsafeBufferPointer(start: base, count: raw.count)

            var lineStart = 0
            var index = 0
            var isFirstLine = true

            while index <= buffer.count {
                let atEnd = index == buffer.count
                guard atEnd || buffer[index] == 0x0A else { index += 1; continue }

                var lineEnd = index
                // Tolerate CRLF even though the live feed uses bare LF.
                if lineEnd > lineStart, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }

                if lineEnd > lineStart {
                    let line = UnsafeBufferPointer(
                        start: base + lineStart,
                        count: lineEnd - lineStart
                    )
                    // The header repeats the literal column names; skip it rather
                    // than counting it as a malformed row.
                    let isHeader = isFirstLine && startsWith(line, "Transportas")
                    if !isHeader {
                        if let vehicle = parseRow(line) {
                            vehicles.append(vehicle)
                        } else {
                            skipped += 1
                        }
                    }
                    isFirstLine = false
                }

                lineStart = index + 1
                index += 1
                if atEnd { break }
            }
        }

        return Result(vehicles: vehicles, skippedRows: skipped)
    }

    /// Convenience for tests and fixtures.
    public static func parse(text: String) -> Result {
        parse(Data(text.utf8))
    }

    // MARK: - Row

    private static func parseRow(_ line: UnsafeBufferPointer<UInt8>) -> Vehicle? {
        // Field boundaries as (start, end) offsets into `line`.
        var fields = [(Int, Int)]()
        fields.reserveCapacity(18)
        var start = 0
        for offset in 0..<line.count where line[offset] == 0x2C {  // ','
            fields.append((start, offset))
            start = offset + 1
        }
        fields.append((start, line.count))

        guard fields.count >= Column.required else { return nil }

        guard let lineBase = line.baseAddress else { return nil }
        func slice(_ column: Int) -> UnsafeBufferPointer<UInt8> {
            let (start, end) = fields[column]
            return UnsafeBufferPointer(start: lineBase + start, count: end - start)
        }
        func string(_ column: Int) -> String {
            String(decoding: slice(column), as: UTF8.self)
        }
        /// Empty fields are meaningful in this feed (a deadheading vehicle has no
        /// trip ID and no schedule deviation), so absent and zero stay distinct.
        func optionalInt(_ column: Int) -> Int? { asciiInt(slice(column)) }

        guard let mode = TransitMode(feedValue: string(Column.transportas)) else { return nil }
        guard let lonRaw = optionalInt(Column.ilguma),
              let latRaw = optionalInt(Column.platuma),
              let measuredAt = optionalInt(Column.matavimoLaikas)
        else { return nil }

        // Coordinates arrive as integers scaled by 1e6: 25292878 -> 25.292878 E.
        let coordinate = CLLocationCoordinate2D(
            latitude: Double(latRaw) / 1e6,
            longitude: Double(lonRaw) / 1e6
        )
        guard CLLocationCoordinate2DIsValid(coordinate), latRaw != 0, lonRaw != 0 else { return nil }

        let fleetNumber = string(Column.masinosNumeris)
        guard !fleetNumber.isEmpty else { return nil }

        let tripID = string(Column.reisoIdGTFS)

        return Vehicle(
            id: fleetNumber,
            mode: mode,
            route: string(Column.marsrutas),
            coordinate: coordinate,
            speed: Double(optionalInt(Column.greitis) ?? 0),
            heading: Double(optionalInt(Column.azimutas) ?? 0),
            deviationSeconds: optionalInt(Column.nuokrypisSekundemis),
            measuredAtSecondsSinceMidnight: measuredAt,
            headsign: string(Column.krypciesPavadinimas),
            gtfsTripID: tripID.isEmpty ? nil : tripID,
            vehicleTypeCode: string(Column.masinosTipas)
        )
    }

    // MARK: - Scalars

    /// Signed base-10 integer straight off the bytes. Returns nil for empty or
    /// non-numeric fields, which the feed uses to mean "not applicable".
    private static func asciiInt(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        var index = 0
        var negative = false
        if bytes[0] == 0x2D { negative = true; index = 1 }       // '-'
        else if bytes[0] == 0x2B { index = 1 }                   // '+'
        guard index < bytes.count else { return nil }
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
            index += 1
        }
        return negative ? -value : value
    }

    private static func startsWith(_ bytes: UnsafeBufferPointer<UInt8>, _ prefix: String) -> Bool {
        let prefixBytes = Array(prefix.utf8)
        guard bytes.count >= prefixBytes.count else { return false }
        for offset in 0..<prefixBytes.count where bytes[offset] != prefixBytes[offset] {
            return false
        }
        return true
    }
}
