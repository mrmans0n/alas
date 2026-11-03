import Foundation

// The client-neutral `diffPatch` extension of our Claude and Codex adapter
// forks: file-edit tool calls and approvals can carry the exact git patch of
// the change. Negotiated through top-level `_meta.diffPatch`.

/// `initialize.clientCapabilities._meta.diffPatch`.
public struct ACPDiffPatchDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// What the agent supports, from `InitializeResponse._meta.diffPatch`. Today
/// only the `git_patch` format at version 1.
public struct ACPDiffPatchCapability: Equatable, Sendable {
    public init() {}
}

/// `InitializeResponse._meta.diffPatch`, as sent.
public struct ACPDiffPatchAdvertisement: Codable, Equatable, Sendable {
    public let version: Int?
    public let format: String?

    /// The only version this client speaks.
    public static let supportedVersion = 1
    /// The only patch format this client reads.
    public static let supportedFormat = "git_patch"

    /// Nil unless the advertisement is the version and format this client speaks.
    public var capability: ACPDiffPatchCapability? {
        guard version == Self.supportedVersion, format == Self.supportedFormat else { return nil }
        return .init()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
    }
}

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
