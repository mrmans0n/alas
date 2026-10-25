import Foundation
import AlasCode

public enum ACPProtocolNegotiationError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(requested: Int, selected: Int, supported: [Int])
    case sessionSupportUnavailable(version: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(requested, selected, supported):
            let versions = supported.map(String.init).joined(separator: ", ")
            return "The agent selected ACP \(selected) after Alas requested ACP \(requested). "
                + "This connection supports ACP \(versions). Use an agent that supports a compatible version."
        case let .sessionSupportUnavailable(version):
            return "ACP \(version) initialization is available, but its session handlers are not ready. Use ACP 1."
        }
    }
}

/// V2 bootstrap only. This deliberately advertises no client capabilities by
/// default; v1 filesystem, terminal, and extension markers cannot be copied here.
public struct ACPV2InitializeParams: Encodable, Sendable {
    public let protocolVersion = ACPProtocolVersion.v2.rawValue
    public let info: ACPImplementationInfo
    public let capabilities: [String: [String: LSPJSONValue]]

    public init(info: ACPImplementationInfo, capabilities: [String: [String: LSPJSONValue]] = [:]) {
        self.info = info
        self.capabilities = capabilities
    }
}

/// The v2 bootstrap is kept separate from ACPInitializeResult. Capabilities,
/// authentication variants, metadata, and future fields remain raw until the
/// v2 handlers can interpret them; none become v1 session capabilities.
public struct ACPV2InitializeResult: Decodable, Equatable, Sendable {
    public let info: ACPImplementationInfo
    public let rawValue: LSPJSONValue

    private enum CodingKeys: String, CodingKey { case protocolVersion, info }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .protocolVersion)
        guard version == ACPProtocolVersion.v2.rawValue else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion, in: container, debugDescription: "Expected ACP 2 initialization")
        }
        info = try container.decode(ACPImplementationInfo.self, forKey: .info)
        rawValue = try LSPJSONValue(from: decoder)
    }

    /// Only objects advertise support. Omission, null, and malformed boolean
    /// markers do not. Unknown fields remain available in rawValue.
    public func capability(at path: [String]) -> [String: LSPJSONValue]? {
        guard case .object(let fields) = rawValue,
              case .object(let capabilities) = fields["capabilities"] else { return nil }
        var object = capabilities
        for key in path {
            guard case .object(let nested) = object[key] else { return nil }
            object = nested
        }
        return object
    }
}

public enum ACPInitializationResult: Equatable, Sendable {
    case v1(ACPInitializeResult)
    case v2(ACPV2InitializeResult)

    /// Inspect the selected version before attempting any version-specific
    /// capability decoding, including when the response came from a broker.
    public static func decode(
        from data: Data,
        requestedVersion: ACPProtocolVersion,
        supportedVersions: Set<ACPProtocolVersion>
    ) throws -> Self {
        struct Header: Decodable { let protocolVersion: Int }
        let decoder = JSONDecoder()
        let selected = try decoder.decode(Header.self, from: data).protocolVersion
        guard selected <= requestedVersion.rawValue,
              let version = ACPProtocolVersion(rawValue: selected),
              supportedVersions.contains(version) else {
            throw ACPProtocolNegotiationError.unsupportedVersion(
                requested: requestedVersion.rawValue,
                selected: selected,
                supported: supportedVersions.map(\.rawValue).sorted())
        }
        switch version {
        case .v1: return .v1(try decoder.decode(ACPInitializeResult.self, from: data))
        case .v2: return .v2(try decoder.decode(ACPV2InitializeResult.self, from: data))
        }
    }
}
