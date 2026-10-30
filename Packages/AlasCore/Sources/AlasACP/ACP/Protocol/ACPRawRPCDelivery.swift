import Foundation
import Synchronization
import AlasFoundation
import AlasPlatform
import AlasCode

/// Original response evidence and one explicit consumption handle. Parsing and
/// projected error fields do not replace the source frame or consume it.
public struct ACPRawRPCDelivery: Sendable {
    public enum Source: Equatable, Sendable {
        case stdio(requestID: JSONRPCID, method: String)
        case brokerOperation(operationKey: ACPBrokerOperationKey, requestID: ACPBrokerAdapterRequestID, method: String)
        case brokerSnapshotCache
        case diagnostic
    }

    public struct Decoded: Sendable {
        public let id: LSPJSONValue
        public let result: Data?
        public let error: JSONRPCError?
        public let rawError: LSPJSONValue?
    }

    public let receiptID = UUID()
    public let frame: Data
    public let connectionID: UUID
    public let source: Source
    public let brokerProvenance: ACPBrokerFrameProvenance?
    private let consumption: Consumption
    private let hasAcknowledgement: Bool

    public init(frame: Data, connectionID: UUID, source: Source, brokerProvenance: ACPBrokerFrameProvenance? = nil,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.frame = frame
        self.connectionID = connectionID
        self.source = source
        // Cached source is evidence only, never a new event receipt.
        self.brokerProvenance = source == .brokerSnapshotCache ? nil : brokerProvenance
        let callback = source == .brokerSnapshotCache ? nil : durableConsumptionAcknowledgement
        consumption = Consumption(callback)
        hasAcknowledgement = callback != nil
    }

    public func decode() throws -> Decoded {
        guard case .object(let fields) = try LSPJSONValue.decode(from: frame),
              fields["jsonrpc"] == .string("2.0"), fields["method"] == nil,
              let id = fields["id"], Self.isSupportedID(id),
              (fields["result"] == nil) != (fields["error"] == nil) else {
            throw ACPClientError.decoding("Malformed raw RPC response")
        }
        switch source {
        case .stdio(let expected, _):
            guard Self.stdioID(id) == expected else { throw ACPClientError.decoding("Misbound raw RPC response") }
        case .brokerOperation(_, let expected, _):
            guard ACPWireInteger.decode(id, as: UInt64.self) == expected.rawValue else {
                throw ACPClientError.decoding("Misbound raw broker response")
            }
        case .brokerSnapshotCache, .diagnostic: break
        }
        if let result = fields["result"] {
            return Decoded(id: id, result: try result.encodedData(), error: nil, rawError: nil)
        }
        guard let rawError = fields["error"], case .object(let failure) = rawError,
              let value = failure["code"], let code = ACPWireInteger.decode(value, as: Int.self),
              case .string(let message)? = failure["message"] else {
            throw ACPClientError.decoding("Invalid raw RPC error")
        }
        var data: AnyCodable?
        if case .object(let details)? = failure["data"], case .string(let kind)? = details["kind"] {
            data = AnyCodable(["kind": kind])
        }
        return Decoded(id: id, result: nil, error: JSONRPCError(code: code, message: message, data: data), rawError: rawError)
    }

    static func stdioID(_ value: LSPJSONValue) -> JSONRPCID? {
        if case .string(let id) = value { return .string(id) }
        return ACPWireInteger.decode(value, as: Int.self).map(JSONRPCID.number)
    }

    private static func isSupportedID(_ value: LSPJSONValue) -> Bool {
        stdioID(value) != nil || ACPWireInteger.decode(value, as: UInt64.self) != nil
    }

    var acknowledgement: ACPDurableConsumptionAcknowledgement? {
        guard hasAcknowledgement else { return nil }
        return { @Sendable in self.acknowledgeDurableConsumption() }
    }

    public func acknowledgeDurableConsumption() { consumption.acknowledge() }

    private final class Consumption: Sendable {
        private let callback: Mutex<ACPDurableConsumptionAcknowledgement?>
        init(_ callback: ACPDurableConsumptionAcknowledgement?) { self.callback = Mutex(callback) }
        func acknowledge() {
            let action = callback.withLock { callback in
                let action = callback
                callback = nil
                return action
            }
            action?()
        }
    }
}

public struct ACPRawRPCError: LocalizedError, Sendable {
    public let delivery: ACPRawRPCDelivery
    public let rpcError: JSONRPCError?
    public var errorDescription: String? { rpcError?.message ?? "Invalid raw ACP response" }

    public init(delivery: ACPRawRPCDelivery, rpcError: JSONRPCError?) {
        self.delivery = delivery
        self.rpcError = rpcError
    }

    public func acknowledgeDurableConsumption() { delivery.acknowledgeDurableConsumption() }
}
