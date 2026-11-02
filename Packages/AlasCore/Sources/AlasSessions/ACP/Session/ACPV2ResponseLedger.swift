import Foundation
import AlasFoundation
import AlasACP
import AlasPlatform

/// A chosen answer to retained evidence, never current reply authority.
public struct ACPV2ResponseIntent: Equatable, Sendable {
    public let id: UUID
    public let stream: ACPV2InboundLedgerStream
    public let request: ACPV2InboundLedgerRecord
    public let frame: Data

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.stream == rhs.stream && responseRequestsEqual(lhs.request, rhs.request) && lhs.frame == rhs.frame
    }
}

/// COMMIT permits a future owner to consider handoff. Missing outcome after a
/// restart is uncertain, including a crash before the owner called the writer.
public struct ACPV2ResponseAttempt: Equatable, Sendable {
    public let id: UUID
    public let intentID: UUID
    public let sequence: Int64
    public let operationKey: ACPV2ReplyOperationKey
}

public struct ACPV2ResponseAttemptRecord: Equatable, Sendable {
    public enum Recovery: Equatable, Sendable { case uncertain, written, notWritten }
    public let attempt: ACPV2ResponseAttempt
    public let recovery: Recovery
}

public enum ACPV2ResponseEvidence: Sendable {
    case stdio(ACPV2StdioReplyResult)
    case broker(ACPBrokerRawReplyResult)
    case uncertain(message: String)
}

/// Identity is inherited from the immutable parent after input validation.
/// These historical facts cannot be used as transport delivery handles.
public enum ACPV2ResponseFact: Equatable, Sendable {
    case stdio(ACPV2StdioReplyStatus)
    case broker(ACPBrokerRawReplyStatus)
    case uncertain(message: String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.stdio(let a), .stdio(let b)): a == b
        case (.broker(let a), .broker(let b)): a == b
        case (.uncertain(let a), .uncertain(let b)): a.utf8.elementsEqual(b.utf8)
        default: false
        }
    }
}

public struct ACPV2ResponseObservation: Equatable, Sendable {
    public let id: UUID
    public let attemptID: UUID
    public let sequence: Int64
    public let fact: ACPV2ResponseFact
}

/// Mutation receipts exist only after COMMIT. Passive reads return values only.
public struct ACPV2ResponseLedgerReceipt<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let wasInserted: Bool
}

public enum ACPV2ResponseLedgerError: Error, Equatable, Sendable {
    case invalidInput, staleLease, incompatibleSource, conflict, unsupportedFormat, corruptRecord, sequenceExhausted
}

public struct ACPV2ResponseLedgerContinuation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case intents, attempts, observations }
    public let kind: Kind
    public let parentID: UUID
    public let afterSequence: Int64
    public init(kind: Kind, parentID: UUID, afterSequence: Int64) {
        self.kind = kind
        self.parentID = parentID
        self.afterSequence = afterSequence
    }
}

public struct ACPV2ResponseLedgerPage<Value: Equatable & Sendable>: Equatable, Sendable {
    public let records: [Value]
    public let next: ACPV2ResponseLedgerContinuation?
    public let isAtEnd: Bool
    /// Includes a parent validation record exceeding the budget, even when its
    /// child history is empty. Parents are validated before reporting local end.
    public let containsOversizedRecord: Bool
}

func responseIDsEqual(_ a: JSONRPCID, _ b: JSONRPCID) -> Bool {
    switch (a, b) {
    case (.number(let a), .number(let b)): a == b
    case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
    default: false
    }
}

func responseRequestsEqual(_ a: ACPV2InboundLedgerRecord, _ b: ACPV2InboundLedgerRecord) -> Bool {
    guard a.streamID == b.streamID, a.ordinal == b.ordinal, a.receiptID == b.receiptID,
          a.connectionID == b.connectionID, a.frame == b.frame else { return false }
    switch (a.source, b.source) {
    case (.stdio, .stdio): return true
    case (.broker(let a, let ap), .broker(let b, let bp)):
        return a.brokerID.rawValue.utf8.elementsEqual(b.brokerID.rawValue.utf8) && a.generation == b.generation
            && a.cursor == b.cursor && a.origin == b.origin && ap.map { Data($0.utf8) } == bp.map { Data($0.utf8) }
    default: return false
    }
}
