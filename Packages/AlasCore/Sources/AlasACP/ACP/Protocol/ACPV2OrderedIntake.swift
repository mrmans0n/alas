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
    private let installed = Mutex(false)

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
        let stream = AsyncStream<ACPV2OrderedIntakeEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
}
