import Foundation
import AlasPlatform

/// A validated pending snapshot from one live attachment. It is an observation,
/// not a promise that an origin will still be pending at the helper's write claim.
public struct ACPBrokerPendingView: Sendable {
    public let connectionID: UUID
    public let brokerID: ACPBrokerID
    public let generation: ACPBrokerGeneration
    public let journalTail: ACPBrokerEventCursor
    public let requests: [ACPBrokerPendingRequest]
}
