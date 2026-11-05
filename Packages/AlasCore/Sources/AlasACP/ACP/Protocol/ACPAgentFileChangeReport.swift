import AlasCode
import AlasFoundation
import Foundation

// The client-neutral `agentFileChangeReport` extension of our Claude and Codex
// adapter forks: after a turn, the adapter reports the files it changed, on a
// `session_info_update`, correlated to the prompt by a request id. Negotiated
// through top-level `_meta.agentFileChangeReport`, ACP v1 only. The
// `_meta.jetbrains` form is never sent or read.

/// `initialize.clientCapabilities._meta.agentFileChangeReport`.
public struct ACPAgentFileChangeReportDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// What the agent supports, from `InitializeResponse._meta.agentFileChangeReport`.
public struct ACPAgentFileChangeReportCapability: Equatable, Sendable {
    public init() {}
}

/// `InitializeResponse._meta.agentFileChangeReport`, as sent.
public struct ACPAgentFileChangeReportAdvertisement: Codable, Equatable, Sendable {
    public let version: Int?

    /// The only version this client speaks.
    public static let supportedVersion = 1

    /// Nil unless the advertisement is the version this client speaks.
    public var capability: ACPAgentFileChangeReportCapability? {
        guard version == Self.supportedVersion else { return nil }
        return .init()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }
}

/// `session/prompt._meta.agentFileChangeReportRequest`.
public struct ACPAgentFileChangeReportRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestId: String

    public init(requestId: String) {
        version = ACPAgentFileChangeReportAdvertisement.supportedVersion
        self.requestId = requestId
    }

    /// A fresh id the adapters' `^[A-Za-z0-9._:-]{1,128}$` accepts.
    public static func newRequestId() -> String {
        "alas-turn:" + UUID().uuidString.lowercased()
    }
}

/// One adapter-reported list of the files a turn changed. It is a hint, never a
/// verdict: `paths: []` is not "no changes", and the adapters always send
/// `declaredComplete: false`. Identity needs `version`, a valid `requestId`, a
/// known `status` and, for `reported`, well-formed `paths`; decoding throws
/// without them. Every other field decodes on its own.
public struct ACPAgentFileChangeReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case reported, unavailable }

    static let maxPaths = 1_024
    static let maxPathUTF16Length = 4_096
    static let maxUncertaintyUTF16Length = 2_000
    public static let maxSerializedBytes = 256 * 1_024

    public let requestId: String
    public let status: Status
    /// Empty when unavailable.
    public let paths: [String]
    /// Distinct `paths`, counted once on decoding: a row's title reads it on
    /// every transcript rebuild.
    public let uniquePathCount: Int
    public let declaredComplete: Bool
    public let truncated: Bool
    public let uncertainty: String?
    /// Why it is unavailable, as sent. Open: an unknown reason stays readable.
    public let reason: String?

    public static func isValidRequestId(_ id: String) -> Bool {
        let count = id.utf8.count
        guard (1...128).contains(count) else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x3A, 0x2D: true
            default: false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, requestId, status, paths, declaredComplete, truncated, uncertainty, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = ACPWireInteger.decode(try c.decode(LSPJSONValue.self, forKey: .version), as: Int.self),
              version == ACPAgentFileChangeReportAdvertisement.supportedVersion
        else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported version")
        }
        requestId = try c.decode(String.self, forKey: .requestId)
        guard Self.isValidRequestId(requestId) else {
            throw DecodingError.dataCorruptedError(forKey: .requestId, in: c, debugDescription: "Invalid request id")
        }
        status = try c.decode(Status.self, forKey: .status)
        let uncertainty = try? c.decodeIfPresent(String.self, forKey: .uncertainty)
        if let uncertainty, uncertainty.utf16.count > Self.maxUncertaintyUTF16Length {
            throw DecodingError.dataCorruptedError(forKey: .uncertainty, in: c, debugDescription: "Uncertainty too long")
        }
        self.uncertainty = uncertainty
        declaredComplete = (try? c.decodeIfPresent(Bool.self, forKey: .declaredComplete)) == true
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) == true
        switch status {
        case .reported:
            guard case .array(let values) = try c.decode(LSPJSONValue.self, forKey: .paths),
                  values.count <= Self.maxPaths
            else {
                throw DecodingError.dataCorruptedError(forKey: .paths, in: c, debugDescription: "Invalid paths")
            }
            paths = try values.map { value in
                guard case .string(let path) = value, path.utf16.count <= Self.maxPathUTF16Length else {
                    throw DecodingError.dataCorruptedError(forKey: .paths, in: c, debugDescription: "Invalid path")
                }
                return path
            }
            uniquePathCount = Set(paths).count
            reason = nil
        case .unavailable:
            paths = []
            uniquePathCount = 0
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ACPAgentFileChangeReportAdvertisement.supportedVersion, forKey: .version)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(status, forKey: .status)
        if status == .reported { try c.encode(paths, forKey: .paths) }
        try c.encode(declaredComplete, forKey: .declaredComplete)
        try c.encode(truncated, forKey: .truncated)
        try c.encodeIfPresent(uncertainty, forKey: .uncertainty)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

/// `_meta.agentFileChangeReport` as a client reads it. A present value that is
/// no readable report stays distinct from no value at all, so the caller can
/// acknowledge it without writing anything.
public enum ACPAgentFileChangeReportSignal: Equatable, Sendable {
    case absent
    case report(ACPAgentFileChangeReport)
    case malformed

    /// `_meta.agentFileChangeReport` of a `session_info_update`. Nil metadata, a
    /// missing key and a null value read as `.absent`; a report over
    /// `maxSerializedBytes` as compact JSON is `.malformed`.
    public static func from(metadata: AnyCodable?) -> ACPAgentFileChangeReportSignal {
        guard let metadata else { return .absent }
        struct Root: Decodable {
            let agentFileChangeReport: LSPJSONValue?
        }
        guard let data = try? JSONEncoder().encode(metadata),
              let value = (try? JSONDecoder().decode(Root.self, from: data))?.agentFileChangeReport,
              value != .null
        else { return .absent }
        guard case .object = value else { return .malformed }
        // Adapters shrink a report until compact `JSON.stringify` fits, so measure the same
        // bytes: unescaped slashes, no whitespace.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let compact = try? encoder.encode(value), compact.count <= ACPAgentFileChangeReport.maxSerializedBytes,
              let report = try? JSONDecoder().decode(ACPAgentFileChangeReport.self, from: compact)
        else { return .malformed }
        return .report(report)
    }
}
