import Foundation
import Synchronization
import AlasCode

/// An unconsumed frame from one immutable stdio connection. Decoding and model
/// application do not prove durability; only the owner may consume the handle.
public struct ACPV2SessionUpdateDelivery: Sendable {
    public let frame: Data
    public let connectionID: UUID
    private let consumption: Consumption

    public init(frame: Data, connectionID: UUID,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        self.frame = frame
        self.connectionID = connectionID
        self.consumption = Consumption(durableConsumptionAcknowledgement)
    }

    public func decode() throws -> ACPV2SessionUpdateEnvelope {
        guard case .object(let fields) = try LSPJSONValue.decode(from: frame),
              fields["jsonrpc"] == .string("2.0"), fields["method"] == .string("session/update"),
              fields["id"] == nil, case .object? = fields["params"], let params = fields["params"] else {
            throw ACPV2SessionUpdateEnvelope.invalid("expected a JSON-RPC session/update notification")
        }
        return try ACPV2SessionUpdateEnvelope(rawValue: params)
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
