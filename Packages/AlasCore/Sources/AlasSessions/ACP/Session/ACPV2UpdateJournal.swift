import Foundation
import AlasACP
import AlasPlatform

public enum ACPV2UpdateJournalSource: Equatable, Sendable {
    case stdio(connectionID: UUID)
    case broker(id: ACPBrokerID, generation: ACPBrokerGeneration)
}

public struct ACPV2UpdateJournalStream: Equatable, Sendable {
    public let id: UUID
    public let sessionId: String
    public let upstreamSessionId: String
    public let source: ACPV2UpdateJournalSource
    public let initialBrokerCursor: ACPBrokerEventCursor?
    public var wireContext: ACPBrokerWireContext { .rawV2 }
}

public struct ACPV2UpdateJournalRecord: Equatable, Sendable {
    public let streamID: UUID
    public let ordinal: Int64
    public let receiptID: UUID
    public let connectionID: UUID
    public let brokerProvenance: ACPBrokerFrameProvenance?
    public let frame: Data
}

/// Created only after a successful journal transaction. Contains no transport
/// callback and is never returned by passive replay.
public struct ACPV2UpdateJournalReceipt: Equatable, Sendable {
    public let record: ACPV2UpdateJournalRecord
    public let wasInserted: Bool
}

public enum ACPV2UpdateJournalError: Error, Equatable, Sendable {
    case invalidInput
    case staleLease
    case incompatibleStream
    case conflictingReceipt
    case unsupportedFormat
    case corruptRecord
}

public struct ACPV2UpdateJournalContinuation: Equatable, Sendable {
    public let streamID: UUID
    public let afterOrdinal: Int64

    public init(streamID: UUID, afterOrdinal: Int64) {
        self.streamID = streamID
        self.afterOrdinal = afterOrdinal
    }
}

/// End-of-journal is a point-in-time local observation, not upstream history
/// completeness or foreground completion. Records carry no consumption handle.
public struct ACPV2UpdateJournalPage: Equatable, Sendable {
    public let records: [ACPV2UpdateJournalRecord]
    public let next: ACPV2UpdateJournalContinuation?
    public let isAtEnd: Bool
    public let hasKnownMissingPrefix: Bool
    public let containsOversizedRecord: Bool
}
