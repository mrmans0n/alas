import Foundation
import AlasFoundation
import AlasACP
import AlasPlatform

public enum ACPV2SubmissionSource: Codable, Equatable, Sendable {
    case stdio(connectionID: UUID)
    case broker(id: ACPBrokerID, generation: ACPBrokerGeneration)
}

/// Wire identity reserved for one prompt attempt. The canonical model's local
/// request sequence is a separate domain and must never be sent as this ID.
public enum ACPV2SubmissionBinding: Codable, Equatable, Sendable {
    case stdio(connectionID: UUID, requestID: JSONRPCID)
    case broker(id: ACPBrokerID, generation: ACPBrokerGeneration, operationKey: ACPBrokerOperationKey)

    public var source: ACPV2SubmissionSource {
        switch self {
        case .stdio(let connection, _): .stdio(connectionID: connection)
        case .broker(let id, let generation, _): .broker(id: id, generation: generation)
        }
    }
}

/// Committed intent only. It does not prove transport handoff or grant retry
/// authority. An attempt without an outcome remains uncertain after reopening.
public struct ACPV2SubmissionRegistration: Equatable, Sendable {
    public let id: UUID
    public let sessionId: String
    public let upstreamSessionId: String
    public let localRowID: UUID
    public let sequence: Int
    public let binding: ACPV2SubmissionBinding
    public var wireContext: ACPBrokerWireContext { .rawV2 }
}

public enum ACPV2SubmissionLedgerError: Error, Equatable, Sendable {
    case invalidInput, staleLease, incompatibleSource, conflict, sequenceExhausted
    case unsupportedFormat, corruptRecord
}

// These are versioned local storage keys, not an adapter wire format.
func submissionStorageJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func validateSubmissionSource(_ source: ACPV2SubmissionSource) throws {
    if case .broker(let id, let generation) = source {
        guard let value = Int64(exactly: generation.rawValue), value > 0,
              !id.rawValue.isEmpty, id.rawValue.utf8.count <= 160,
              id.rawValue.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ACPV2SubmissionLedgerError.invalidInput
        }
    }
}

func validateSubmissionBinding(_ binding: ACPV2SubmissionBinding) throws {
    try validateSubmissionSource(binding.source)
    if case .broker(_, _, let key) = binding, key.rawValue.isEmpty {
        throw ACPV2SubmissionLedgerError.invalidInput
    }
}

public struct ACPV2SubmissionOutcome: Equatable, Sendable {
    public let frame: Data
    public let receiptID: UUID
    public let connectionID: UUID
    public let source: ACPRawRPCDelivery.Source
    public let brokerProvenance: ACPBrokerFrameProvenance?
    public let interpretation: ACPV2SubmissionRecord.Recovery
}

public struct ACPV2SubmissionRecord: Equatable, Sendable {
    public enum Recovery: Equatable, Sendable {
        case uncertain
        case accepted(ACPV2PromptAccepted)
        case rpcFailure
        case uninterpretable
    }

    public let registration: ACPV2SubmissionRegistration
    public let outcome: ACPV2SubmissionOutcome?
    public var recovery: Recovery { outcome?.interpretation ?? .uncertain }
}

/// Proof of a committed local record, never a reconstructed transport handle.
public struct ACPV2SubmissionReceipt: Equatable, Sendable {
    public let record: ACPV2SubmissionRecord
    public let wasInserted: Bool
}

func submissionInterpretation(_ delivery: ACPRawRPCDelivery) -> ACPV2SubmissionRecord.Recovery {
    do {
        let decoded = try delivery.decode()
        if decoded.error != nil { return .rpcFailure }
        guard let result = decoded.result else { return .uninterpretable }
        return .accepted(try ACPV2PromptAccepted.decode(from: result))
    } catch { return .uninterpretable }
}

func submissionInterpretationFields(_ recovery: ACPV2SubmissionRecord.Recovery) -> (kind: String, messageID: String?) {
    switch recovery {
    case .accepted(let accepted): ("accepted", accepted.messageID)
    case .rpcFailure: ("rpc_failure", nil)
    case .uninterpretable: ("uninterpretable", nil)
    case .uncertain: ("uncertain", nil)
    }
}

public struct ACPV2SubmissionContinuation: Equatable, Sendable {
    public let sessionId: String
    public let upstreamSessionId: String
    public let source: ACPV2SubmissionSource
    public let afterSequence: Int

    public init(sessionId: String, upstreamSessionId: String, source: ACPV2SubmissionSource, afterSequence: Int) {
        self.sessionId = sessionId
        self.upstreamSessionId = upstreamSessionId
        self.source = source
        self.afterSequence = afterSequence
    }
}

/// A bounded historical view. End means local end at this read snapshot, not
/// upstream completeness. None of these values carries consumption authority.
public struct ACPV2SubmissionPage: Equatable, Sendable {
    public let records: [ACPV2SubmissionRecord]
    public let next: ACPV2SubmissionContinuation?
    public let isAtEnd: Bool
    public let containsOversizedRecord: Bool
}
