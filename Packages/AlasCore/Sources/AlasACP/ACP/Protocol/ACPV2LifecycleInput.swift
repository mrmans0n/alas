import Foundation
import AlasCode
import AlasFoundation

/// V2 insertion response for one exact request. Use the explicit wire codec to
/// preserve arbitrary numeric tokens; generic Decodable is Foundation-limited.
public struct ACPV2PromptAccepted: Decodable, Equatable, Sendable {
    public let messageID: String
    public let rawValue: LSPJSONValue

    public static func decode(from data: Data) throws -> Self {
        try Self(rawValue: LSPJSONValue.decode(from: data))
    }

    public func encodedData() throws -> Data { try rawValue.encodedData() }

    public init(rawValue: LSPJSONValue) throws {
        guard case .object(let fields) = rawValue, case .string(let id)? = fields["messageId"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a v2 messageId string"))
        }
        _ = try ACPV2SessionUpdateEnvelope.metadata(fields["_meta"])
        self.messageID = id
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: LSPJSONValue(from: decoder))
    }
}

/// Foreground observation, separate from insertion and v1 completion. Explicit
/// wire entry points preserve opaque numbers; generic Decodable may canonicalize.
public struct ACPV2StateUpdate: Decodable, Equatable, Sendable {
    public struct FailureDetails: Equatable, Sendable {
        public let code: Int32
        public let message: String
        public let data: LSPJSONValue?
        public let rawValue: LSPJSONValue
    }

    public let state: ACPForegroundState
    public let stopReason: ACPStopReason
    public let failure: FailureDetails?
    public let rawValue: LSPJSONValue

    /// Foundation-compatible convenience. Use failure/rawValue for exact data.
    public var error: JSONRPCError? {
        guard let raw = failure?.rawValue, let data = try? raw.encodedData() else { return nil }
        return try? JSONDecoder().decode(JSONRPCError.self, from: data)
    }

    public var result: ACPTurnCompletion.Result {
        if stopReason.rawValue == .string("error") {
            return .failed(failure?.message ?? "Agent foreground work failed.")
        }
        return stopReason.v1Result
    }

    public static func decode(from data: Data) throws -> Self {
        try Self(rawValue: LSPJSONValue.decode(from: data))
    }

    public func encodedData() throws -> Data { try rawValue.encodedData() }

    public init(rawValue: LSPJSONValue) throws {
        guard case .object(let fields) = rawValue,
              fields["sessionUpdate"] == .string("state_update"),
              case .string(let state)? = fields["state"] else {
            throw ACPV2SessionUpdateEnvelope.invalid("expected state_update with a state string")
        }
        _ = try ACPV2SessionUpdateEnvelope.metadata(fields["_meta"])
        switch state {
        case "idle": self.state = .idle
        case "running": self.state = .running
        case "requires_action": self.state = .requiresAction
        default: self.state = .unrecognized(state)
        }
        self.stopReason = ACPStopReason(rawValue: fields["stopReason"])
        if case .object(let error)? = fields["error"],
           let rawCode = error["code"], let code = ACPWireInteger.decode(rawCode, as: Int32.self),
           case .string(let message)? = error["message"], let rawError = fields["error"] {
            self.failure = FailureDetails(code: code, message: message, data: error["data"], rawValue: rawError)
        } else { self.failure = nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: LSPJSONValue(from: decoder))
    }
}
