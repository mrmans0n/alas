import Foundation
import AlasFoundation
import AlasPlatform
import AlasCode

public struct ACPBrokerRawResponse: Sendable {
    public let result: Data?
    public let error: JSONRPCError?

    public static func decode(_ frame: ACPBrokerRawJSONPayload, expectedID: UInt64? = nil,
                              projectedError: JSONRPCError? = nil) throws -> Self {
        guard case .object(let fields) = try LSPJSONValue.decode(from: frame.bytes),
              fields["jsonrpc"] == .string("2.0"), fields["method"] == nil,
              let id = fields["id"],
              expectedID == nil || ACPWireInteger.decode(id, as: UInt64.self) == expectedID,
              (fields["result"] == nil) != (fields["error"] == nil) else {
            throw ACPClientError.decoding("Malformed or misbound raw broker response")
        }
        if let result = fields["result"] {
            guard projectedError == nil else { throw ACPClientError.decoding("Contradictory raw result/error projection") }
            return Self(result: try result.encodedData(), error: nil)
        }
        guard case .object(let failure)? = fields["error"],
              let codeValue = failure["code"], let code = ACPWireInteger.decode(codeValue, as: Int.self),
              case .string(let message)? = failure["message"] else {
            throw ACPClientError.decoding("Invalid raw broker error")
        }
        var data: AnyCodable?
        if case .object(let details)? = failure["data"], case .string(let kind)? = details["kind"] {
            data = AnyCodable(["kind": kind])
        }
        let error = JSONRPCError(code: code, message: message, data: data)
        guard projectedError == nil || projectedError == error else {
            throw ACPClientError.decoding("Contradictory raw error projection")
        }
        return Self(result: nil, error: error)
    }
}

/// Retains the full source error and its explicit durable-consumption authority.
public struct ACPBrokerRawRPCError: LocalizedError, Sendable {
    public let frame: ACPBrokerRawJSONPayload
    public let rpcError: JSONRPCError?
    private let acknowledgement: ACPDurableConsumptionAcknowledgement?
    public var errorDescription: String? { rpcError?.message ?? "Invalid raw ACP broker response" }

    public init(frame: ACPBrokerRawJSONPayload, rpcError: JSONRPCError?,
                acknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.frame = frame
        self.rpcError = rpcError
        self.acknowledgement = acknowledgement
    }

    public func acknowledgeDurableConsumption() { acknowledgement?() }
}
