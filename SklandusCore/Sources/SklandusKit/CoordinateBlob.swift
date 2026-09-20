import Foundation
import CoreLocation

/// Packs a path of coordinates into one binary blob, and back.
///
/// A route shape averages 215 points and the archive holds 945 shapes. Stored as
/// individual rows that would be ~170,000 objects, which is where SwiftData is at
/// its slowest. As blobs it is one row per shape, and a path costs 16 bytes a point.
enum CoordinateBlob {
    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> Data {
        var data = Data(capacity: coordinates.count * 16)
        for coordinate in coordinates {
            withUnsafeBytes(of: coordinate.latitude.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: coordinate.longitude.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [CLLocationCoordinate2D] {
        let count = data.count / 16
        guard count > 0 else { return [] }
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let offset = index * 16
                let latitude = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                    fromByteOffset: offset, as: UInt64.self
                )))
                let longitude = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                    fromByteOffset: offset + 8, as: UInt64.self
                )))
                coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
        }
        return coordinates
    }
}
