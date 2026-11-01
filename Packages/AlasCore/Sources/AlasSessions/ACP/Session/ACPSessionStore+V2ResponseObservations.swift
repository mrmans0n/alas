import Foundation
import AlasACP
import AlasPlatform

extension ACPSessionStore {
    public func retainV2ResponseObservation(id: UUID, for attempt: ACPV2ResponseAttempt, evidence: ACPV2ResponseEvidence,
        fence: ACPSessionLeaseFence) throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseObservation> {
        guard let intent = try responseIntent(id: attempt.intentID) else { throw ACPV2ResponseLedgerError.conflict }
        return try responseMutation(sessionId: intent.stream.sessionId, fence: fence) {
            guard let parents = try responseAttemptParents(id: attempt.id), parents.1 == attempt,
                  parents.0 == intent else { throw ACPV2ResponseLedgerError.conflict }
            _ = try requireCurrentInboundSource(intent.stream.source, sessionId: intent.stream.sessionId)
            let fact = try validateResponseEvidence(evidence, attempt: attempt, intent: intent)
            if try responsePreflightObservation(id: id), let row = try db.query("SELECT \(Self.responseObservationColumns) FROM acp_v2_response_observations WHERE id = ?", bindings: [id.uuidString]).first {
                guard responseUUID(row["attempt_id"] ?? nil) == attempt.id else { throw ACPV2ResponseLedgerError.conflict }
                let old = try decodeResponseObservation(row, attempt: attempt, intent: intent)
                guard old.fact == fact else { throw ACPV2ResponseLedgerError.conflict }
                return .init(value: old, wasInserted: false)
            }
            let previous = try responseAttemptRecovery(attempt, intent: intent)
            let fields = responseFactFields(fact)
            if (previous == .written && fields.status == 4) || (previous == .notWritten && fields.status == 2) { throw ACPV2ResponseLedgerError.conflict }
            guard let last = try db.query("SELECT COALESCE(MAX(sequence),0) AS last FROM acp_v2_response_observations WHERE attempt_id = ?",
                bindings: [attempt.id.uuidString]).first?["last"] as? Int64, last >= 0, last < Int64.max else { throw ACPV2ResponseLedgerError.sequenceExhausted }
            let value = ACPV2ResponseObservation(id: id, attemptID: attempt.id, sequence: last + 1, fact: fact)
            try db.exec("INSERT INTO acp_v2_response_observations (id,attempt_id,sequence,format_version,kind,status,message) VALUES (?,?,?,1,?,?,?)",
                bindings: [id.uuidString, attempt.id.uuidString, value.sequence, fields.kind, fields.status, fields.message])
            return .init(value: value, wasInserted: true)
        }
    }

    public func loadV2ResponseAttempt(id: UUID) throws -> ACPV2ResponseAttemptRecord? {
        try db.transaction {
            guard let (intent, attempt) = try responseAttemptParents(id: id) else { return nil }
            return try .init(attempt: attempt, recovery: responseAttemptRecovery(attempt, intent: intent))
        }
    }

    func responseAttemptParents(id: UUID) throws -> (ACPV2ResponseIntent, ACPV2ResponseAttempt)? {
        guard try responsePreflightAttempt(id: id), let row = try db.query("SELECT \(Self.responseAttemptColumns) FROM acp_v2_response_attempts WHERE id = ?", bindings: [id.uuidString]).first else { return nil }
        guard let intentID = responseUUID(row["intent_id"] ?? nil), let intent = try responseIntent(id: intentID) else { throw ACPV2ResponseLedgerError.corruptRecord }
        return try (intent, decodeResponseAttempt(row, intent: intent))
    }

    func validateResponseEvidence(_ evidence: ACPV2ResponseEvidence, attempt: ACPV2ResponseAttempt, intent: ACPV2ResponseIntent) throws -> ACPV2ResponseFact {
        switch evidence {
        case .uncertain(let message):
            guard message.utf8.count <= Int32.max else { throw ACPV2ResponseLedgerError.invalidInput }
            return .uncertain(message: message)
        case .stdio(let result):
            guard case .stdio = intent.request.source, result.connectionID == intent.request.connectionID,
                  result.receiptID == intent.request.receiptID, let requestID = try intent.request.decodeHeader().id,
                  responseIDsEqual(result.requestID, requestID), result.operationKey == attempt.operationKey else { throw ACPV2ResponseLedgerError.incompatibleSource }
            return .stdio(result.status)
        case .broker(let result):
            guard case .broker(let provenance, let pending) = intent.request.source,
                  result.brokerId.rawValue.utf8.elementsEqual(provenance.brokerID.rawValue.utf8), result.generation == provenance.generation,
                  pending.map({ Data($0.utf8) }) == Data(result.pendingRequestId.utf8), result.originCursor == provenance.cursor,
                  result.operationKey.rawValue.utf8.elementsEqual(attempt.operationKey.rawValue.utf8) else { throw ACPV2ResponseLedgerError.incompatibleSource }
            return .broker(result.status)
        }
    }

    func responseFactFields(_ fact: ACPV2ResponseFact) -> (kind: Int64, status: Int64?, message: Data?) {
        switch fact {
        case .uncertain(let message): (2, nil, Data(message.utf8))
        case .broker(let status):
            switch status {
            case .inFlight: (1, 1, nil)
            case .written: (1, 2, nil)
            case .writeUncertain: (1, 3, nil)
            }
        case .stdio(let status):
            switch status {
            case .queued: (0, 0, nil)
            case .inFlight: (0, 1, nil)
            case .written: (0, 2, nil)
            case .writeUncertain: (0, 3, nil)
            case .notWritten: (0, 4, nil)
            }
        }
    }

    func decodeResponseObservation(_ row: [String: Any?], attempt: ACPV2ResponseAttempt, intent: ACPV2ResponseIntent) throws -> ACPV2ResponseObservation {
        guard row["format_version"] as? Int64 == 1 else { throw ACPV2ResponseLedgerError.unsupportedFormat }
        guard let id = responseUUID(row["id"] ?? nil), responseUUID(row["attempt_id"] ?? nil) == attempt.id,
              let sequence = row["sequence"] as? Int64, sequence > 0 else { throw ACPV2ResponseLedgerError.corruptRecord }
        let fact: ACPV2ResponseFact
        switch row["kind"] as? Int64 {
        case 0:
            guard case .stdio = intent.stream.source, row["message"] == nil, let status = row["status"] as? Int64 else { throw ACPV2ResponseLedgerError.corruptRecord }
            switch status {
            case 0: fact = .stdio(.queued)
            case 1: fact = .stdio(.inFlight)
            case 2: fact = .stdio(.written)
            case 3: fact = .stdio(.writeUncertain)
            case 4: fact = .stdio(.notWritten)
            default: throw ACPV2ResponseLedgerError.corruptRecord
            }
        case 1:
            guard case .broker = intent.stream.source, row["message"] == nil, let status = row["status"] as? Int64 else { throw ACPV2ResponseLedgerError.corruptRecord }
            switch status {
            case 1: fact = .broker(.inFlight)
            case 2: fact = .broker(.written)
            case 3: fact = .broker(.writeUncertain)
            default: throw ACPV2ResponseLedgerError.corruptRecord
            }
        case 2:
            guard row["status"] == nil, let message = responseText(row["message"] ?? nil) else { throw ACPV2ResponseLedgerError.corruptRecord }
            fact = .uncertain(message: message)
        default: throw ACPV2ResponseLedgerError.corruptRecord
        }
        return .init(id: id, attemptID: attempt.id, sequence: sequence, fact: fact)
    }
}
