import Foundation
import Synchronization
import AlasFoundation
import AlasPlatform

public enum ACPV2PromptEndpoint: Equatable, Sendable {
    case stdio(connectionID: UUID)
    case broker(connectionID: UUID, id: ACPBrokerID, generation: ACPBrokerGeneration)

    public var connectionID: UUID {
        switch self {
        case .stdio(let connection), .broker(let connection, _, _): connection
        }
    }
}

public struct ACPV2PreparedPrompt: Equatable, Sendable {
    public enum Binding: Equatable, Sendable {
        case stdio(requestID: JSONRPCID)
        case broker(operationKey: ACPBrokerOperationKey)
    }

    public let endpoint: ACPV2PromptEndpoint
    public let binding: Binding
    public var method: String { "session/prompt" }

    public init(endpoint: ACPV2PromptEndpoint, binding: Binding) {
        self.endpoint = endpoint
        self.binding = binding
    }
}

public enum ACPV2PromptDispatchError: Error, Equatable, Sendable {
    case unsupported, missingOperationKey, invalidated
}

/// Claim authorizes one local dispatch. It does not prove bytes were sent.
/// Invalidating after claim cannot establish that upstream insertion failed.
public final class ACPV2PromptHandoffGate: Sendable {
    private struct State { var valid = true
    var claimed = false }
    private let state = Mutex(State())

    public init() {}
    public var isValid: Bool { state.withLock { $0.valid } }
    public func invalidate() { state.withLock { $0.valid = false } }
    public func claim() throws {
        try state.withLock {
            guard $0.valid, !$0.claimed else { throw ACPV2PromptDispatchError.invalidated }
            $0.claimed = true
        }
    }
}

/// Concrete v2 preparation only; deliberately has no generic send fallback.
public protocol ACPV2PromptSending: AnyObject, Sendable {
    var v2PromptEndpoint: ACPV2PromptEndpoint? { get }
    func sendV2Prompt(_ params: ACPSessionPromptParams, operationKey: ACPBrokerOperationKey?,
        gate: ACPV2PromptHandoffGate,
        prepare: @escaping @Sendable (ACPV2PreparedPrompt) async throws -> Void) async throws -> ACPResponse
}
