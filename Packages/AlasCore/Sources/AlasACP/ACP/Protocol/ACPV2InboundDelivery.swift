import Foundation
import Synchronization
import AlasFoundation
import AlasCode

/// Original inbound evidence. Consumption acknowledges receipt only, never a
/// permission decision, response delivery, or helper pending-request resolution.
public struct ACPV2InboundDelivery: Sendable {
    public enum Source: Equatable, Sendable {
        case stdio
        case broker(provenance: ACPBrokerFrameProvenance, pendingRequestID: String?)
    }

    public struct Header: Equatable, Sendable {
        public let method: String
        public let id: JSONRPCID?
        public let params: LSPJSONValue?
        public let rawValue: LSPJSONValue
    }

    public let receiptID = UUID()
    public let frame: Data
    public let connectionID: UUID
    public let source: Source
    private let consumption: Consumption

    public init(frame: Data, connectionID: UUID, source: Source,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.frame = frame
        self.connectionID = connectionID
        self.source = source
        consumption = Consumption(durableConsumptionAcknowledgement)
    }

    /// Interprets the header without granting method-specific payload validity.
    /// Params remain opaque, including omission versus explicit null.
    public func decodeHeader() throws -> Header {
        let raw = try LSPJSONValue.decode(from: frame)
        guard case .object(let fields) = raw, fields["jsonrpc"] == .string("2.0"),
              case .string(let method)? = fields["method"], fields["result"] == nil, fields["error"] == nil else {
            throw ACPClientError.decoding("Expected a JSON-RPC inbound method envelope")
        }
        let id: JSONRPCID?
        if let value = fields["id"] {
            guard let supported = ACPRawRPCDelivery.stdioID(value) else { throw ACPClientError.decoding("Unsupported inbound request ID") }
            id = supported
        } else { id = nil }
        return Header(method: method, id: id, params: fields["params"], rawValue: raw)
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
