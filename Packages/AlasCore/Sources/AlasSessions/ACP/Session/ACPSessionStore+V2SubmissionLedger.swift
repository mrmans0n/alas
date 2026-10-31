import Foundation
import AlasACP
import AlasPlatform

extension ACPSessionStore {
    func createV2SubmissionLedgerSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_submissions (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          upstream_session_id TEXT NOT NULL,
          local_row_id TEXT NOT NULL,
          sequence INTEGER NOT NULL CHECK(sequence > 0),
          source_key TEXT NOT NULL,
          binding_key TEXT NOT NULL,
          format_version INTEGER NOT NULL,
          wire_context TEXT NOT NULL,
          UNIQUE(session_id, sequence),
          UNIQUE(binding_key),
          UNIQUE(session_id, upstream_session_id, source_key, local_row_id)
        )
        """)
        try db.exec("""
        CREATE INDEX IF NOT EXISTS acp_v2_submissions_filter
          ON acp_v2_submissions(session_id, upstream_session_id, source_key, sequence)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_submission_outcomes (
          submission_id TEXT PRIMARY KEY REFERENCES acp_v2_submissions(id) ON DELETE CASCADE,
          receipt_key TEXT NOT NULL UNIQUE,
          receipt_id TEXT NOT NULL,
          connection_id TEXT NOT NULL,
          broker_request_id TEXT,
          broker_cursor INTEGER,
          broker_origin TEXT,
          frame BLOB NOT NULL,
          interpretation TEXT NOT NULL,
          message_id TEXT
        )
        """)
    }

    public func registerV2Submission(id: UUID, sessionId: String, upstreamSessionId: String,
        localRowID: UUID, binding: ACPV2SubmissionBinding, fence: ACPSessionLeaseFence) throws -> ACPV2SubmissionRegistration {
        guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, fence.sessionId == sessionId else {
            throw ACPV2SubmissionLedgerError.invalidInput
        }
        try validateSubmissionBinding(binding)
        let bindingKey = try submissionStorageJSON(binding)
        let sourceKey = try submissionStorageJSON(binding.source)
        guard let registration = try withLeaseFence(fence, {
            try requireCurrentSubmissionSource(binding.source, sessionId: sessionId)
            if let row = try db.query("SELECT * FROM acp_v2_submissions WHERE id = ?", bindings: [id.uuidString]).first {
                let existing = try decodeSubmissionRegistration(row)
                guard existing.sessionId == sessionId, existing.upstreamSessionId == upstreamSessionId,
                      existing.localRowID == localRowID, existing.binding == binding else { throw ACPV2SubmissionLedgerError.conflict }
                return existing
            }
            guard try db.query("""
            SELECT id FROM acp_v2_submissions WHERE binding_key = ? OR
              (session_id = ? AND upstream_session_id = ? AND source_key = ? AND local_row_id = ?) LIMIT 1
            """, bindings: [bindingKey, sessionId, upstreamSessionId, sourceKey, localRowID.uuidString]).isEmpty else {
                throw ACPV2SubmissionLedgerError.conflict
            }
            guard let last = try db.query("SELECT COALESCE(MAX(sequence), 0) AS last FROM acp_v2_submissions WHERE session_id = ?",
                bindings: [sessionId]).first?["last"] as? Int64, last >= 0,
                last < Int64.max, let sequence = Int(exactly: last + 1) else { throw ACPV2SubmissionLedgerError.sequenceExhausted }
            try db.exec("""
            INSERT INTO acp_v2_submissions
              (id, session_id, upstream_session_id, local_row_id, sequence, source_key, binding_key, format_version, wire_context)
            VALUES (?,?,?,?,?,?,?,1,?)
            """, bindings: [id.uuidString, sessionId, upstreamSessionId, localRowID.uuidString, sequence, sourceKey, bindingKey,
                try ACPBrokerWireContext.rawV2.persistedJSON()])
            return ACPV2SubmissionRegistration(id: id, sessionId: sessionId, upstreamSessionId: upstreamSessionId,
                localRowID: localRowID, sequence: sequence, binding: binding)
        }) else { throw ACPV2SubmissionLedgerError.staleLease }
        return registration
    }

    public func retainV2SubmissionOutcome(_ delivery: ACPRawRPCDelivery, for registration: ACPV2SubmissionRegistration,
        fence: ACPSessionLeaseFence) throws -> ACPV2SubmissionReceipt {
        guard fence.sessionId == registration.sessionId, delivery.frame.count <= Int32.max else {
            throw ACPV2SubmissionLedgerError.invalidInput
        }
        guard let receipt = try withLeaseFence(fence, {
            guard let row = try db.query("SELECT * FROM acp_v2_submissions WHERE id = ?", bindings: [registration.id.uuidString]).first,
                  try decodeSubmissionRegistration(row) == registration else { throw ACPV2SubmissionLedgerError.conflict }
            try requireCurrentSubmissionSource(registration.binding.source, sessionId: registration.sessionId)
            let key = try submissionReceiptKey(delivery, registration: registration)
            if let existing = try loadSubmissionOutcome(registration) {
                let original = ACPRawRPCDelivery(frame: existing.frame, connectionID: existing.connectionID,
                    source: existing.source, brokerProvenance: existing.brokerProvenance)
                guard try submissionReceiptKey(original, registration: registration, receiptID: existing.receiptID) == key,
                      existing.source == delivery.source, existing.frame == delivery.frame else { throw ACPV2SubmissionLedgerError.conflict }
                return ACPV2SubmissionReceipt(record: .init(registration: registration, outcome: existing), wasInserted: false)
            }
            guard try db.query("SELECT submission_id FROM acp_v2_submission_outcomes WHERE receipt_key = ?", bindings: [key]).isEmpty else {
                throw ACPV2SubmissionLedgerError.conflict
            }
            let interpretation = submissionInterpretation(delivery)
            let fields = submissionInterpretationFields(interpretation)
            let requestID: String?
            if case .brokerOperation(_, let id, _) = delivery.source { requestID = String(id.rawValue) } else { requestID = nil }
            try db.exec("""
            INSERT INTO acp_v2_submission_outcomes
              (submission_id, receipt_key, receipt_id, connection_id, broker_request_id, broker_cursor, broker_origin,
               frame, interpretation, message_id) VALUES (?,?,?,?,?,?,?,?,?,?)
            """, bindings: [registration.id.uuidString, key, delivery.receiptID.uuidString, delivery.connectionID.uuidString,
                requestID, delivery.brokerProvenance.map { Int64($0.cursor.rawValue) }, delivery.brokerProvenance?.origin.rawValue,
                delivery.frame, fields.kind, fields.messageID])
            let outcome = ACPV2SubmissionOutcome(frame: delivery.frame, receiptID: delivery.receiptID, connectionID: delivery.connectionID,
                source: delivery.source, brokerProvenance: delivery.brokerProvenance, interpretation: interpretation)
            return ACPV2SubmissionReceipt(record: .init(registration: registration, outcome: outcome), wasInserted: true)
        }) else { throw ACPV2SubmissionLedgerError.staleLease }
        return receipt
    }

    public func loadV2Submission(id: UUID) throws -> ACPV2SubmissionRecord? {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM acp_v2_submissions WHERE id = ?", bindings: [id.uuidString]).first else { return nil }
            return try decodeSubmissionRecord(row)
        }
    }

    func decodeSubmissionRecord(_ row: [String: Any?]) throws -> ACPV2SubmissionRecord {
        let registration = try decodeSubmissionRegistration(row)
        return try .init(registration: registration, outcome: loadSubmissionOutcome(registration))
    }

    private func submissionReceiptKey(_ delivery: ACPRawRPCDelivery, registration: ACPV2SubmissionRegistration,
        receiptID: UUID? = nil) throws -> String {
        switch (registration.binding, delivery.source) {
        case (.stdio(let connection, let request), .stdio(let actual, let method)):
            guard connection == delivery.connectionID, request == actual, method == "session/prompt", delivery.brokerProvenance == nil else {
                throw ACPV2SubmissionLedgerError.incompatibleSource
            }
            return "stdio:" + (receiptID ?? delivery.receiptID).uuidString
        case (.broker(let id, let generation, let key), .brokerOperation(let actual, _, let method)):
            guard actual == key, method == "session/prompt", let provenance = delivery.brokerProvenance,
                  provenance.brokerID == id, provenance.generation == generation,
                  let cursor = Int64(exactly: provenance.cursor.rawValue), cursor > 0 else { throw ACPV2SubmissionLedgerError.incompatibleSource }
            return try submissionStorageJSON([submissionStorageJSON(registration.binding.source), String(cursor)])
        default: throw ACPV2SubmissionLedgerError.incompatibleSource
        }
    }

    private func loadSubmissionOutcome(_ registration: ACPV2SubmissionRegistration) throws -> ACPV2SubmissionOutcome? {
        guard let row = try db.query("SELECT * FROM acp_v2_submission_outcomes WHERE submission_id = ?",
            bindings: [registration.id.uuidString]).first else { return nil }
        guard let rawReceipt = row["receipt_id"] as? String, let receipt = UUID(uuidString: rawReceipt), rawReceipt == receipt.uuidString,
              let rawConnection = row["connection_id"] as? String, let connection = UUID(uuidString: rawConnection), rawConnection == connection.uuidString,
              let frame = row["frame"] as? Data, frame.count <= Int32.max else { throw ACPV2SubmissionLedgerError.corruptRecord }
        let source: ACPRawRPCDelivery.Source
        let provenance: ACPBrokerFrameProvenance?
        switch registration.binding {
        case .stdio(let expected, let request):
            guard connection == expected, row["broker_request_id"] == nil, row["broker_cursor"] == nil,
                  row["broker_origin"] == nil else { throw ACPV2SubmissionLedgerError.corruptRecord }
            source = .stdio(requestID: request, method: "session/prompt")
            provenance = nil
        case .broker(let id, let generation, let key):
            guard let rawRequest = row["broker_request_id"] as? String, let request = UInt64(rawRequest), String(request) == rawRequest,
                  let cursor = row["broker_cursor"] as? Int64, cursor > 0,
                  let rawOrigin = row["broker_origin"] as? String, let origin = ACPBrokerFrameProvenance.Origin(rawValue: rawOrigin) else {
                throw ACPV2SubmissionLedgerError.corruptRecord
            }
            source = .brokerOperation(operationKey: key, requestID: .init(rawValue: request), method: "session/prompt")
            provenance = .init(brokerID: id, generation: generation, cursor: .init(rawValue: UInt64(cursor)), origin: origin)
        }
        let delivery = ACPRawRPCDelivery(frame: frame, connectionID: connection, source: source, brokerProvenance: provenance)
        let interpretation = submissionInterpretation(delivery)
        let fields = submissionInterpretationFields(interpretation)
        guard (try? submissionReceiptKey(delivery, registration: registration, receiptID: receipt)) == row["receipt_key"] as? String,
              fields.kind == row["interpretation"] as? String, fields.messageID == row["message_id"] as? String else {
            throw ACPV2SubmissionLedgerError.corruptRecord
        }
        return .init(frame: frame, receiptID: receipt, connectionID: connection, source: source,
            brokerProvenance: provenance, interpretation: interpretation)
    }

    func requireCurrentSubmissionSource(_ source: ACPV2SubmissionSource, sessionId: String) throws {
        guard let row = try loadSession(id: sessionId) else { throw ACPV2SubmissionLedgerError.incompatibleSource }
        if case .broker(let id, let generation) = source {
            guard let descriptor = try? ACPBrokerRestorePolicy.resolve(row: row, supportedVersions: [.v2]),
                  descriptor.brokerId == id, descriptor.generation == generation, descriptor.wireContext == .rawV2 else {
                throw ACPV2SubmissionLedgerError.incompatibleSource
            }
        }
    }

    func decodeSubmissionRegistration(_ row: [String: Any?]) throws -> ACPV2SubmissionRegistration {
        guard row["format_version"] as? Int64 == 1,
              let context = row["wire_context"] as? String,
              (try? ACPBrokerRestorePolicy.context(from: context)) == .rawV2 else { throw ACPV2SubmissionLedgerError.unsupportedFormat }
        guard let rawID = row["id"] as? String, let id = UUID(uuidString: rawID), rawID == id.uuidString,
              let session = row["session_id"] as? String, !session.isEmpty,
              let upstream = row["upstream_session_id"] as? String, !upstream.isEmpty,
              let rawRow = row["local_row_id"] as? String, let localRow = UUID(uuidString: rawRow), rawRow == localRow.uuidString,
              let rawSequence = row["sequence"] as? Int64, rawSequence > 0, let sequence = Int(exactly: rawSequence),
              let key = row["binding_key"] as? String,
              let binding = try? JSONDecoder().decode(ACPV2SubmissionBinding.self, from: Data(key.utf8)),
              (try? submissionStorageJSON(binding)) == key,
              (try? submissionStorageJSON(binding.source)) == row["source_key"] as? String else { throw ACPV2SubmissionLedgerError.corruptRecord }
        do { try validateSubmissionBinding(binding) } catch { throw ACPV2SubmissionLedgerError.corruptRecord }
        return .init(id: id, sessionId: session, upstreamSessionId: upstream, localRowID: localRow, sequence: sequence, binding: binding)
    }
}
