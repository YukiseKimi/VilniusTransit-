import Foundation
import SwiftData

/// What the store knows about the archive it was built from.
///
/// A single row. When the city publishes a new archive the trips and shapes
/// hydrated from the old one are dropped, because trip ids embed a schedule
/// version and stale ones would silently stop matching.
@Model
public final class StoredCatalogMeta {
    @Attribute(.unique) public var id: String
    /// The archive's `Last-Modified`, replayed on the next conditional request.
    public var lastModified: String?
    public var etag: String?
    public var importedAt: Date

    public init(id: String = "catalog", lastModified: String?, etag: String?, importedAt: Date = Date()) {
        self.id = id
        self.lastModified = lastModified
        self.etag = etag
        self.importedAt = importedAt
    }
}
