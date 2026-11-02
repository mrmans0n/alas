import CryptoKit
import Foundation
import AlasCode
import AlasFoundation
import AlasPlatform

// The client-neutral `forkPoint` extension of our Claude and Codex adapter
// forks: `session/fork` can cut the source session at one historical message
// instead of at its tip. Negotiated through top-level `_meta.forkPoint`.

/// `initialize.clientCapabilities._meta.forkPoint`.
public struct ACPForkPointDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// Where the adapter can cut: at the chosen message, or at the end of its turn.
public enum ACPForkPointBoundary: String, Codable, Equatable, Sendable {
    case message
    case turn
}

/// What the agent supports, from `InitializeResponse._meta.forkPoint`.
public struct ACPForkPointCapability: Equatable, Sendable {
    public let boundary: ACPForkPointBoundary

    public init(boundary: ACPForkPointBoundary) {
        self.boundary = boundary
    }
}

/// `InitializeResponse._meta.forkPoint`, as sent.
public struct ACPForkPointAdvertisement: Codable, Equatable, Sendable {
    public let version: Int?
    public let boundary: String?

    /// The only version this client speaks.
    public static let supportedVersion = 1

    /// Nil unless the advertisement is the version this client speaks with a
    /// boundary it knows.
    public var capability: ACPForkPointCapability? {
        guard version == Self.supportedVersion,
              let boundary = boundary.flatMap(ACPForkPointBoundary.init(rawValue:))
        else { return nil }
        return .init(boundary: boundary)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        boundary = try? c.decodeIfPresent(String.self, forKey: .boundary)
    }
}

/// `_meta.forkPoint` of `session/fork`: the message to cut at.
public struct ACPForkPointTarget: Codable, Equatable, Sendable {
    public let messageId: String
    public let messageFingerprint: String
    /// Which of the messages sharing this fingerprint is meant, counting from 1.
    public let messageOccurrence: Int

    public init(messageId: String, messageFingerprint: String, messageOccurrence: Int) {
        self.messageId = messageId
        self.messageFingerprint = messageFingerprint
        self.messageOccurrence = messageOccurrence
    }

    /// `sha256:` and the lowercase hex digest of the text's UTF-8 bytes, with
    /// no normalization.
    public static func fingerprint(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ACPForkPointMatchedBy: String, Codable, Equatable, Sendable {
    case id
    case fingerprint
}

/// `_meta.forkPoint` of a `session/fork` result: where the adapter cut.
public struct ACPForkPointEcho: Codable, Equatable, Sendable {
    public let boundary: ACPForkPointBoundary
    public let messageId: String
    public let turnId: String?
    public let lastItemId: String?
    public let matchedBy: ACPForkPointMatchedBy

    public init(
        boundary: ACPForkPointBoundary,
        messageId: String,
        turnId: String? = nil,
        lastItemId: String? = nil,
        matchedBy: ACPForkPointMatchedBy
    ) {
        self.boundary = boundary
        self.messageId = messageId
        self.turnId = turnId
        self.lastItemId = lastItemId
        self.matchedBy = matchedBy
    }
}

public enum ACPForkPointFailure: String, Codable, Equatable, Error, Sendable {
    case notFound
    case malformed
    case unsupported
    case sourceChanged
    case missingEcho
    case mismatchedEcho
    /// The fork couldn't be attempted or settled natively for a reason that
    /// isn't about the message: the connection, the source, or a failure.
    case unavailable

    /// The adapter's own refusal of a fork target: `-32602` with
    /// `data.forkPoint`, `reason: notFound` for a message it cannot locate,
    /// `reason: notNegotiated` when it doesn't take targets from this client,
    /// and `field` for a malformed target. Any other error is not a refusal.
    public static func rejection(from error: any Error) -> ACPForkPointFailure? {
        let rpc: JSONRPCError
        switch error {
        case ACPClientError.jsonrpc(let e): rpc = e
        case RemoteHelperClientError.jsonrpc(let e): rpc = e
        case let e as JSONRPCError: rpc = e
        // A raw response's projected error keeps only `data.kind`; the
        // refusal is read from the adapter's frame it retains.
        case let e as ACPBrokerRawRPCError where e.rpcError != nil: return rejection(fromFrame: e.frame.bytes)
        case let e as ACPRawRPCError where e.rpcError != nil: return rejection(fromFrame: e.delivery.frame)
        default: return nil
        }
        guard rpc.code == -32602,
              let data = object(rpc.data?.value),
              let forkPoint = object(data["forkPoint"])
        else { return nil }
        return refusal(reason: forkPoint["reason"] as? String, hasField: forkPoint["field"] != nil)
    }

    private static func rejection(fromFrame frame: Data) -> ACPForkPointFailure? {
        guard case .object(let response)? = try? LSPJSONValue.decode(from: frame),
              case .object(let error)? = response["error"],
              let code = error["code"], ACPWireInteger.decode(code, as: Int.self) == -32602,
              case .object(let data)? = error["data"],
              case .object(let forkPoint)? = data["forkPoint"]
        else { return nil }
        let reason: String? = if case .string(let reason)? = forkPoint["reason"] { reason } else { nil }
        return refusal(reason: reason, hasField: forkPoint["field"] != nil)
    }

    private static func refusal(reason: String?, hasField: Bool) -> ACPForkPointFailure? {
        switch reason {
        case "notFound": return .notFound
        case "notNegotiated": return .unsupported
        default: return hasField ? .malformed : nil
        }
    }

    private static func object(_ value: Any?) -> [String: Any]? {
        // Decoded JSON nests `AnyCodable`, which `as? [String: Any]` would
        // accept with its values still boxed.
        if let value = value as? [String: AnyCodable] { return value.mapValues(\.value) }
        if let value = value as? [String: Any] { return value }
        if let value = value as? AnyCodable { return object(value.value) }
        return nil
    }
}
