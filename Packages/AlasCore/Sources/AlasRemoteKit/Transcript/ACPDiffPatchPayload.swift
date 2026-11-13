import Foundation

/// `_meta.diffPatch` on a `diff` content block, as sent. Each field decodes
/// on its own, so a bad field reads as nil and fails validation later
/// instead of dropping the block.
public struct ACPDiffPatchPayload: Codable, Equatable, Hashable, Sendable {
    public let version: Int?
    public let format: String?
    public let text: String?
    /// False after the runner saw the block on a connection that did not
    /// negotiate `diffPatch`. Runtime only: never encoded.
    public var negotiated: Bool = true

    private enum CodingKeys: String, CodingKey {
        case version, format, text
    }

    public init(version: Int?, format: String?, text: String?, negotiated: Bool = true) {
        self.version = version
        self.format = format
        self.text = text
        self.negotiated = negotiated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(text, forKey: .text)
    }
}
