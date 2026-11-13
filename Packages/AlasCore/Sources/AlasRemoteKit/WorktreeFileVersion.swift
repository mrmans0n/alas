import CryptoKit
import Foundation

/// The version of a file's bytes, so an edit can tell whether the file
/// changed since it was read.
public struct WorktreeFileVersion: Codable, Hashable, Sendable {
    /// SHA-256 of the bytes, lowercase hex: two versions differ when this does.
    public var contentHash: String
    /// When the bytes were read; never compared on the host.
    public var modified: Date

    public init(contentHash: String, modified: Date) {
        self.contentHash = contentHash
        self.modified = modified
    }

    public static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
