import CryptoKit
import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// What a sent symbol mention looked like at send time. Stored on the
/// recorded attachment so the transcript can show it later.
public struct ACPSymbolSnapshot: Codable, Equatable, Hashable, Sendable {
    /// 0-based, inclusive, as sent.
    public let lineRange: ClosedRange<Int>
    /// SHA-256 (hex) of the declaration text as sent; empty when not found.
    public let contentHash: String
    /// The code sent to the agent, only when "Include code" was on.
    public let excerpt: String?
    public let truncated: Bool
    public let found: Bool

    public init(lineRange: ClosedRange<Int>, contentHash: String, excerpt: String?, truncated: Bool, found: Bool) {
        self.lineRange = lineRange
        self.contentHash = contentHash
        self.excerpt = excerpt
        self.truncated = truncated
        self.found = found
    }
}
