import AlasCode
import AlasFoundation
import Foundation

// The client-neutral `sessionFailure` extension of our Claude and Codex adapter
// forks: a structured failure incident, on `session_info_update` and on the
// `session/prompt` response beside `quota`. Negotiated through top-level
// `_meta.sessionFailure`, ACP v1 only. The `_meta.jetbrains` form is not read.

/// `initialize.clientCapabilities._meta.sessionFailure`.
public struct ACPSessionFailureDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// What the agent supports, from `InitializeResponse._meta.sessionFailure`.
public struct ACPSessionFailureCapability: Equatable, Sendable {
    public init() {}
}

/// `InitializeResponse._meta.sessionFailure`, as sent.
public struct ACPSessionFailureAdvertisement: Codable, Equatable, Sendable {
    public let version: Int?

    /// The only version this client speaks.
    public static let supportedVersion = 1

    /// Nil unless the advertisement is the version this client speaks.
    public var capability: ACPSessionFailureCapability? {
        guard version == Self.supportedVersion else { return nil }
        return .init()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }
}

/// One failure incident, as sent. Identity needs `version`, `id`, `revision` and
/// `title`, and decoding throws without them, so a persisted row from a future
/// version falls back to its text. Every other field decodes on its own: a bad
/// one never costs the record. `category` and `actions` keep their raw strings.
public struct ACPSessionFailureRecord: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case warning, error }
    public enum Category: String, Sendable { case connection, access, limit, request, service, unknown }

    /// The `kind` of a usage limit.
    public static let quotaExhaustedKind = "quota_exhausted"

    public let version: Int
    public let id: String
    public let revision: Int
    public let category: String
    public let severity: Severity
    public let title: String
    public let details: String?
    public let reason: String?
    public let actions: [String]
    public let kind: String?

    /// An unrecognized category reads as `.unknown`.
    public var knownCategory: Category { Category(rawValue: category) ?? .unknown }

    public var isUsageLimit: Bool { severity == .error && kind == Self.quotaExhaustedKind }

    private enum CodingKeys: String, CodingKey {
        case version, id, revision, category, severity, title, details, reason, actions, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == ACPSessionFailureAdvertisement.supportedVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported version")
        }
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Empty id")
        }
        guard let revision = ACPWireInteger.decode(try c.decode(LSPJSONValue.self, forKey: .revision), as: Int.self),
              revision >= 1
        else {
            throw DecodingError.dataCorruptedError(forKey: .revision, in: c, debugDescription: "Invalid revision")
        }
        self.revision = revision
        title = try c.decode(String.self, forKey: .title)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "Blank title")
        }
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? Category.unknown.rawValue
        severity = (try? c.decodeIfPresent(Severity.self, forKey: .severity)) ?? .error
        let details = try? c.decodeIfPresent(String.self, forKey: .details)
        self.details = details?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? details : nil
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        if case .array(let values)? = try? c.decodeIfPresent(LSPJSONValue.self, forKey: .actions) {
            actions = values.compactMap { value -> String? in
                guard case .string(let action) = value else { return nil }
                return action
            }
        } else {
            actions = []
        }
    }

    private init(strippingActionsFrom record: ACPSessionFailureRecord) {
        version = record.version
        id = record.id
        revision = record.revision
        category = record.category
        severity = record.severity
        title = record.title
        details = record.details
        reason = record.reason
        actions = []
        kind = record.kind
    }

    /// This record for a surface that cannot act on it.
    public func strippingActions() -> ACPSessionFailureRecord {
        ACPSessionFailureRecord(strippingActionsFrom: self)
    }
}

/// `_meta.sessionFailure` as a client reads it. A present value that is no
/// readable record stays distinct from no value at all: it must not read as
/// a successful turn.
public enum ACPSessionFailureSignal: Equatable, Sendable {
    case absent
    case record(ACPSessionFailureRecord)
    case unreadable

    public static let unreadableMessage = "The agent reported a failure Alas could not read."

    /// `_meta.sessionFailure` of a `session_info_update`. A missing or null key
    /// reads as `.absent`.
    public static func from(metadata: AnyCodable?) -> ACPSessionFailureSignal {
        guard let metadata, let data = try? JSONEncoder().encode(metadata) else { return .absent }
        struct Root: Decodable {
            let sessionFailure: ACPSessionFailureSignal?
        }
        return (try? JSONDecoder().decode(Root.self, from: data))?.sessionFailure ?? .absent
    }

    public var isPresent: Bool {
        if case .absent = self { false } else { true }
    }
}

extension ACPSessionFailureSignal: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .absent
        } else if let record = try? container.decode(ACPSessionFailureRecord.self) {
            self = .record(record)
        } else {
            self = .unreadable
        }
    }
}

extension ACPStopReason {
    /// The result of a v1 prompt response. Only `end_turn` consults the signal:
    /// an error record or an unreadable signal means the turn did not succeed,
    /// and any other stop reason already says how the turn ended.
    public func v1Result(failure: ACPSessionFailureSignal) -> ACPTurnCompletion.Result {
        guard rawValue == .string("end_turn") else { return v1Result }
        switch failure {
        case .absent:
            return v1Result
        case .unreadable:
            return .failed(ACPSessionFailureSignal.unreadableMessage)
        case .record(let record):
            guard record.severity == .error else { return v1Result }
            return record.isUsageLimit ? .limited : .failed(record.title)
        }
    }
}
