import AlasFoundation
import Foundation

// The client-neutral `planFile` extension of our Claude adapter fork: the
// ExitPlanMode tool call and its permission request can name the plan file
// the plan was written to, with the digest of the exact plan text. Negotiated
// through top-level `_meta.planFile`.

/// `initialize.clientCapabilities._meta.planFile`.
public struct ACPPlanFileDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// What the agent supports, from `InitializeResponse._meta.planFile`.
public struct ACPPlanFileCapability: Equatable, Sendable {
    public init() {}
}

/// `InitializeResponse._meta.planFile`, as sent.
public struct ACPPlanFileAdvertisement: Codable, Equatable, Sendable {
    public let version: Int?

    /// The only version this client speaks.
    public static let supportedVersion = 1

    /// Nil unless the advertisement is the version this client speaks.
    public var capability: ACPPlanFileCapability? {
        guard version == Self.supportedVersion else { return nil }
        return .init()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }
}

/// `_meta.planFile` on an ExitPlanMode tool call or permission request, as
/// sent. Each field decodes on its own, so a bad field reads as nil and fails
/// `isWellFormed` instead of dropping the payload.
public struct ACPPlanFilePayload: Codable, Equatable, Hashable, Sendable {
    public let version: Int?
    public let planId: String?
    public let path: String?
    public let sha256: String?

    /// The plan id prefix of an approved plan under `planFile`.
    public static let planIdPrefix = "plan-mode:"

    private enum CodingKeys: String, CodingKey {
        case version, planId, path, sha256
    }

    public init(version: Int?, planId: String?, path: String?, sha256: String?) {
        self.version = version
        self.planId = planId
        self.path = path
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        planId = try? c.decodeIfPresent(String.self, forKey: .planId)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
    }

    /// `_meta.planFile` of a tool call or permission toolCall; nil when
    /// `metadata` has no such object.
    public static func from(metadata: AnyCodable?) -> ACPPlanFilePayload? {
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else { return nil }
        struct Root: Decodable {
            let planFile: ACPPlanFilePayload?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                planFile = try? c.decodeIfPresent(ACPPlanFilePayload.self, forKey: .planFile)
            }

            enum CodingKeys: String, CodingKey { case planFile }
        }
        return (try? JSONDecoder().decode(Root.self, from: data))?.planFile
    }

    /// Version 1, a `plan-mode:` plan id, a lowercase hex SHA-256 digest and,
    /// when present, an absolute path.
    public var isWellFormed: Bool {
        guard version == ACPPlanFileAdvertisement.supportedVersion,
              let planId, planId.hasPrefix(Self.planIdPrefix), planId.count > Self.planIdPrefix.count,
              let sha256, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return false }
        if let path, !path.hasPrefix("/") { return false }
        return true
    }
}
