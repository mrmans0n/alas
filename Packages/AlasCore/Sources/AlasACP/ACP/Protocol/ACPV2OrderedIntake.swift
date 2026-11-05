import Foundation
import Synchronization

public enum ACPV2OrderedIntakeEvent: Sendable {
    case update(ACPV2SessionUpdateDelivery)
    case inbound(ACPV2InboundDelivery)
    case diagnostic(ACPRawRPCDelivery)
}

/// One client's original method captures, in transport order. RPC responses
/// resolve independently. This claim grants neither reply nor ACK authority.
public final class ACPV2OrderedIntake: Sendable {
    public let connectionID: UUID
    public let events: AsyncStream<ACPV2OrderedIntakeEvent>
    let continuation: AsyncStream<ACPV2OrderedIntakeEvent>.Continuation
    public enum Control: Sendable {
        case durableState(ACPBrokerDurableState)
        case invalidated(message: String)
    }
    public let controls: AsyncStream<Control>
    public let invalidations: AsyncStream<String>
    private let controlContinuation: AsyncStream<Control>.Continuation
    private let invalidationContinuation: AsyncStream<String>.Continuation
    private let valid = Mutex(true)
    public var isValid: Bool { valid.withLock { $0 } }
    private let installed = Mutex(false)

    func publishDurableState(_ state: ACPBrokerDurableState) {
        guard isValid else { return }
        controlContinuation.yield(.durableState(state))
    }

    func invalidate(message: String) {
        let first = valid.withLock { value in
            guard value else { return false }
            value = false
            return true
        }
        guard first else { return }
        controlContinuation.yield(.invalidated(message: message))
        invalidationContinuation.yield(message)
        invalidationContinuation.finish()
        controlContinuation.finish()
        continuation.finish()
    }

    /// Install exactly one runtime. Copying an attachment cannot create a
    /// second consumer of its original method captures.
    public func claimConsumer() throws {
        try installed.withLock { value in
            guard !value else { throw ACPV2BootstrapClaimError.used }
            value = true
        }
    }

    init(connectionID: UUID) {
        self.connectionID = connectionID
        let control = AsyncStream<Control>.makeStream()
        controls = control.stream
        controlContinuation = control.continuation
        let terminal = AsyncStream<String>.makeStream()
        invalidations = terminal.stream
        invalidationContinuation = terminal.continuation
        let stream = AsyncStream<ACPV2OrderedIntakeEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
}
