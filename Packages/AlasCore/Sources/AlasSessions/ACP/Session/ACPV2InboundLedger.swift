import Foundation
import AlasACP
import AlasPlatform

public enum ACPV2InboundLedgerSource: Equatable, Sendable {
    case stdio(connectionID: UUID)
    case broker(id: ACPBrokerID, generation: ACPBrokerGeneration)
}

/// Historical attribution only, not an active attachment or ACK owner.
public struct ACPV2InboundLedgerStream: Equatable, Sendable {
    public let id: UUID
    public let sessionId: String
    public let upstreamSessionId: String
    public let source: ACPV2InboundLedgerSource
    public let formatVersion: Int
    public let initialBrokerCursor: ACPBrokerEventCursor?
    public var wireContext: ACPBrokerWireContext { .rawV2 }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.sessionId.utf8.elementsEqual(rhs.sessionId.utf8)
            && lhs.upstreamSessionId.utf8.elementsEqual(rhs.upstreamSessionId.utf8)
            && lhs.source == rhs.source && lhs.formatVersion == rhs.formatVersion
            && lhs.initialBrokerCursor == rhs.initialBrokerCursor
    }
}

/// Pending metadata records what the source supplied at capture time. It does
/// not establish current request liveness or authority to send a response.
public struct ACPV2InboundLedgerRecord: Equatable, Sendable {
    public let streamID: UUID
    public let ordinal: Int64
    public let receiptID: UUID
    public let connectionID: UUID
    public let source: ACPV2InboundDelivery.Source
    public let frame: Data

    public func decodeHeader() throws -> ACPV2InboundDelivery.Header {
        try ACPV2InboundDelivery.decodeHeader(from: frame)
    }
}

/// Constructed only after COMMIT; never returned by passive recovery.
public struct ACPV2InboundLedgerReceipt: Equatable, Sendable {
    public let record: ACPV2InboundLedgerRecord
    public let wasInserted: Bool
}

public enum ACPV2InboundLedgerError: Error, Equatable, Sendable {
    case invalidInput, staleLease, incompatibleStream, conflictingReceipt
    case unsupportedFormat, corruptRecord
}

public struct ACPV2InboundLedgerContinuation: Equatable, Sendable {
    public let streamID: UUID
    public let afterOrdinal: Int64

    public init(streamID: UUID, afterOrdinal: Int64) {
        self.streamID = streamID
        self.afterOrdinal = afterOrdinal
    }
}

/// End is local end at this snapshot, not completeness or current pending state.
public struct ACPV2InboundLedgerPage: Equatable, Sendable {
    public let records: [ACPV2InboundLedgerRecord]
    public let next: ACPV2InboundLedgerContinuation?
    public let isAtEnd: Bool
    public let hasKnownMissingPrefix: Bool
    public let containsOversizedRecord: Bool
}
