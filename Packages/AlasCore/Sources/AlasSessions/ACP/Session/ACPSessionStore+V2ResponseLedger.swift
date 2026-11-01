import Foundation
import CryptoKit
import AlasACP
import AlasPlatform

extension ACPSessionStore {
    func createV2ResponseLedgerSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_response_intents (
          id TEXT PRIMARY KEY, stream_id TEXT NOT NULL, origin_ordinal INTEGER NOT NULL,
          format_version INTEGER NOT NULL, frame BLOB NOT NULL, binding_digest BLOB NOT NULL,
          UNIQUE(stream_id, origin_ordinal),
          FOREIGN KEY(stream_id, origin_ordinal) REFERENCES acp_v2_inbound_records(stream_id, ordinal) ON DELETE CASCADE
        )
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_response_attempts (
          id TEXT PRIMARY KEY, intent_id TEXT NOT NULL REFERENCES acp_v2_response_intents(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL CHECK(sequence > 0), format_version INTEGER NOT NULL,
          namespace BLOB NOT NULL, operation_key BLOB NOT NULL,
          UNIQUE(intent_id, sequence), UNIQUE(namespace, operation_key)
        )
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_response_observations (
          id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL REFERENCES acp_v2_response_attempts(id) ON DELETE CASCADE,
          sequence INTEGER NOT NULL CHECK(sequence > 0), format_version INTEGER NOT NULL,
          kind INTEGER NOT NULL, status INTEGER, message BLOB, UNIQUE(attempt_id, sequence)
        )
        """)
    }

    public func registerV2ResponseIntent(id: UUID, request: ACPV2InboundLedgerRecord, in stream: ACPV2InboundLedgerStream,
        frame: Data, fence: ACPSessionLeaseFence) throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseIntent> {
        try responseMutation(sessionId: stream.sessionId, fence: fence) {
            try responseRequireStream(stream)
            _ = try requireCurrentInboundSource(stream.source, sessionId: stream.sessionId)
            guard request.streamID == stream.id,
                  let stored = try responseRequest(stream: stream, ordinal: request.ordinal), responseRequestsEqual(stored, request) else { throw ACPV2ResponseLedgerError.conflict }
            try validateResponseTarget(request, frame: frame)
            let value = ACPV2ResponseIntent(id: id, stream: stream, request: request, frame: frame)
            if let existing = try responseIntent(id: id) {
                guard existing == value else { throw ACPV2ResponseLedgerError.conflict }
                return .init(value: existing, wasInserted: false)
            }
            guard try db.query("SELECT 1 FROM acp_v2_response_intents WHERE stream_id = ? AND origin_ordinal = ?",
                bindings: [stream.id.uuidString, request.ordinal]).isEmpty else { throw ACPV2ResponseLedgerError.conflict }
            try db.exec("INSERT INTO acp_v2_response_intents (id,stream_id,origin_ordinal,format_version,frame,binding_digest) VALUES (?,?,?,1,?,?)",
                bindings: [id.uuidString, stream.id.uuidString, request.ordinal, frame, responseIntentDigest(value)])
            return .init(value: value, wasInserted: true)
        }
    }

    public func registerV2ResponseAttempt(id: UUID, for intent: ACPV2ResponseIntent, operationKey: ACPV2ReplyOperationKey,
        fence: ACPSessionLeaseFence) throws -> ACPV2ResponseLedgerReceipt<ACPV2ResponseAttempt> {
        try responseMutation(sessionId: intent.stream.sessionId, fence: fence) {
            guard try responseIntent(id: intent.id) == intent else { throw ACPV2ResponseLedgerError.conflict }
            _ = try requireCurrentInboundSource(intent.stream.source, sessionId: intent.stream.sessionId)
            guard !operationKey.rawValue.isEmpty, operationKey.rawValue.utf8.count <= Int32.max else { throw ACPV2ResponseLedgerError.invalidInput }
            if try responsePreflightAttempt(id: id), let row = try db.query("SELECT \(Self.responseAttemptColumns) FROM acp_v2_response_attempts WHERE id = ?", bindings: [id.uuidString]).first {
                guard responseUUID(row["intent_id"] ?? nil) == intent.id else { throw ACPV2ResponseLedgerError.conflict }
                let old = try decodeResponseAttempt(row, intent: intent)
                guard old.intentID == intent.id, old.operationKey == operationKey else { throw ACPV2ResponseLedgerError.conflict }
                return .init(value: old, wasInserted: false)
            }
            let namespace = responseNamespace(intent.stream)
            guard try db.query("SELECT 1 FROM acp_v2_response_attempts WHERE namespace = ? AND operation_key = ?",
                bindings: [namespace, Data(operationKey.rawValue.utf8)]).isEmpty else { throw ACPV2ResponseLedgerError.conflict }
            var sequence: Int64 = 1
            if let row = try db.query("SELECT substr(id,1,36) AS id, typeof(id) AS id_type, length(CAST(id AS BLOB)) AS id_bytes FROM acp_v2_response_attempts WHERE intent_id = ? ORDER BY sequence DESC LIMIT 1", bindings: [intent.id.uuidString]).first {
                guard row["id_type"] as? String == "text", row["id_bytes"] as? Int64 == 36,
                      let lastID = responseUUID(row["id"] ?? nil), let parents = try responseAttemptParents(id: lastID) else { throw ACPV2ResponseLedgerError.corruptRecord }
                let last = parents.1
                guard try responseAttemptRecovery(last, intent: intent) == .notWritten else { throw ACPV2ResponseLedgerError.conflict }
                guard last.sequence < Int64.max else { throw ACPV2ResponseLedgerError.sequenceExhausted }
                sequence = last.sequence + 1
            }
            let value = ACPV2ResponseAttempt(id: id, intentID: intent.id, sequence: sequence, operationKey: operationKey)
            try db.exec("INSERT INTO acp_v2_response_attempts (id,intent_id,sequence,format_version,namespace,operation_key) VALUES (?,?,?,1,?,?)",
                bindings: [id.uuidString, intent.id.uuidString, sequence, namespace, Data(operationKey.rawValue.utf8)])
            return .init(value: value, wasInserted: true)
        }
    }

    func responseMutation<T>(sessionId: String, fence: ACPSessionLeaseFence, _ body: () throws -> T) throws -> T {
        guard sessionId.utf8.elementsEqual(fence.sessionId.utf8) else { throw ACPV2ResponseLedgerError.invalidInput }
        do {
            guard let value = try withLeaseFence(fence, {
                guard let lease = try db.query("""
                SELECT CAST(owner_instance AS BLOB) AS owner, CAST(lease_token AS BLOB) AS token
                FROM session_leases WHERE session_id = ?
                """, bindings: [sessionId]).first, lease["owner"] as? Data == Data(fence.ownerInstance.utf8),
                      lease["token"] as? Data == Data(fence.token.utf8) else { throw ACPV2ResponseLedgerError.staleLease }
                return try body()
            }) else { throw ACPV2ResponseLedgerError.staleLease }
            return value
        } catch let error as ACPV2InboundLedgerError {
            switch error {
            case .corruptRecord: throw ACPV2ResponseLedgerError.corruptRecord
            case .unsupportedFormat: throw ACPV2ResponseLedgerError.unsupportedFormat
            default: throw ACPV2ResponseLedgerError.incompatibleSource
            }
        }
    }

    func responseRequest(stream: ACPV2InboundLedgerStream, ordinal: Int64) throws -> ACPV2InboundLedgerRecord? {
        guard try responsePreflightRequest(stream: stream, ordinal: ordinal) else { return nil }
        return try db.query("SELECT \(Self.responseRequestColumns) FROM acp_v2_inbound_records WHERE stream_id = ? AND ordinal = ?",
            bindings: [stream.id.uuidString, ordinal]).first.map { try decodeInboundRecord($0, stream: stream) }
    }

    func validateResponseTarget(_ request: ACPV2InboundLedgerRecord, frame: Data) throws {
        guard frame.count <= Int32.max else { throw ACPV2ResponseLedgerError.invalidInput }
        do {
            guard let id = try request.decodeHeader().id, responseIDsEqual(id, try ACPRawReply.validateFrame(frame)) else { throw ACPV2ResponseLedgerError.invalidInput }
            if case .broker(_, let pending) = request.source, pending == nil { throw ACPV2ResponseLedgerError.invalidInput }
        } catch { throw ACPV2ResponseLedgerError.invalidInput }
    }

    func responseNamespace(_ stream: ACPV2InboundLedgerStream) -> Data {
        switch stream.source {
        case .stdio(let connection): Data("stdio:\(connection.uuidString)".utf8)
        case .broker(let id, let generation): Data("broker:\(id.rawValue):\(generation.rawValue)".utf8)
        }
    }

    func responseIntent(id: UUID) throws -> ACPV2ResponseIntent? {
        guard try responsePreflightIntent(id: id), let row = try db.query("SELECT \(Self.responseIntentColumns) FROM acp_v2_response_intents WHERE id = ?", bindings: [id.uuidString]).first else { return nil }
        guard row["format_version"] as? Int64 == 1 else { throw ACPV2ResponseLedgerError.unsupportedFormat }
        guard responseUUID(row["id"] ?? nil) == id, let streamID = responseUUID(row["stream_id"] ?? nil),
              let ordinal = row["origin_ordinal"] as? Int64, ordinal > 0,
              let frame = row["frame"] as? Data, frame.count <= Int32.max,
              try responsePreflightStream(id: streamID),
              let streamRow = try db.query("SELECT \(Self.responseStreamColumns) FROM acp_v2_inbound_streams WHERE id = ?", bindings: [streamID.uuidString]).first else { throw ACPV2ResponseLedgerError.corruptRecord }
        let stream = try decodeInboundStream(streamRow)
        guard let request = try responseRequest(stream: stream, ordinal: ordinal) else { throw ACPV2ResponseLedgerError.corruptRecord }
        do { try validateResponseTarget(request, frame: frame) } catch { throw ACPV2ResponseLedgerError.corruptRecord }
        let value = ACPV2ResponseIntent(id: id, stream: stream, request: request, frame: frame)
        guard row["binding_digest"] as? Data == responseIntentDigest(value) else { throw ACPV2ResponseLedgerError.corruptRecord }
        return value
    }

    private func responseIntentDigest(_ intent: ACPV2ResponseIntent) -> Data {
        // Length prefixes preserve opaque text boundaries, including embedded
        // NUL. This checks retained binding consistency, not authorization.
        var hash = SHA256()
        func append(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        func text(_ value: String) { append(Data(value.utf8)) }
        text("alas.response-intent.v1")
        text(intent.id.uuidString)
        text(intent.stream.id.uuidString)
        text(intent.stream.sessionId)
        text(intent.stream.upstreamSessionId)
        append(responseNamespace(intent.stream))
        text(String(intent.stream.formatVersion))
        text(intent.stream.initialBrokerCursor.map { String($0.rawValue) } ?? "none")
        text(intent.request.streamID.uuidString)
        text(String(intent.request.ordinal))
        text(intent.request.receiptID.uuidString)
        text(intent.request.connectionID.uuidString)
        switch intent.request.source {
        case .stdio: text("stdio")
        case .broker(let provenance, let pending):
            text("broker")
            text(provenance.brokerID.rawValue)
            text(String(provenance.generation.rawValue))
            text(String(provenance.cursor.rawValue))
            text(provenance.origin.rawValue)
            text(pending == nil ? "absent" : "present")
            if let pending { text(pending) }
        }
        append(intent.request.frame)
        append(intent.frame)
        return Data(hash.finalize())
    }

    func decodeResponseAttempt(_ row: [String: Any?], intent: ACPV2ResponseIntent) throws -> ACPV2ResponseAttempt {
        guard row["format_version"] as? Int64 == 1 else { throw ACPV2ResponseLedgerError.unsupportedFormat }
        guard let id = responseUUID(row["id"] ?? nil), responseUUID(row["intent_id"] ?? nil) == intent.id,
              let sequence = row["sequence"] as? Int64, sequence > 0,
              row["namespace"] as? Data == responseNamespace(intent.stream),
              let key = responseText(row["operation_key"] ?? nil), !key.isEmpty else { throw ACPV2ResponseLedgerError.corruptRecord }
        return .init(id: id, intentID: intent.id, sequence: sequence, operationKey: .init(rawValue: key))
    }

    func responseUUID(_ value: Any?) -> UUID? {
        guard let text = value as? String, let id = UUID(uuidString: text), text == id.uuidString else { return nil }
        return id
    }

    func responseText(_ value: Any?) -> String? {
        guard let data = value as? Data, data.count <= Int32.max else { return nil }
        return String(validating: data, as: UTF8.self)
    }

    func responseAttemptRecovery(_ attempt: ACPV2ResponseAttempt, intent: ACPV2ResponseIntent) throws -> ACPV2ResponseAttemptRecord.Recovery {
        // Scalar aggregation never materializes the potentially unbounded diagnostic history.
        let sourceKind = { if case .stdio = intent.stream.source { return 0 }
        return 1 }()
        let row = try db.query("""
        SELECT COALESCE(SUM(CASE WHEN format_version = 1 AND typeof(sequence) = 'integer' AND sequence > 0 AND
          typeof(id) = 'text' AND length(CAST(id AS BLOB)) = 36 AND length(id) = 36 AND length(replace(id,'-','')) = 32 AND
          substr(id,9,1) = '-' AND substr(id,14,1) = '-' AND substr(id,19,1) = '-' AND substr(id,24,1) = '-' AND
          replace(id,'-','') NOT GLOB '*[^0-9A-F]*' AND
          ((kind = ? AND status IN (0,1,2,3,4) AND message IS NULL AND (? = 0 OR status IN (1,2,3))) OR
           (kind = 2 AND status IS NULL AND typeof(message) = 'blob' AND length(message) <= 2147483647))
          THEN 0 ELSE 1 END),0) AS bad,
          COALESCE(SUM(status = 2),0) AS written, COALESCE(SUM(status = 4),0) AS not_written
        FROM acp_v2_response_observations WHERE attempt_id = ?
        """, bindings: [sourceKind, sourceKind, attempt.id.uuidString]).first
        guard let row, row["bad"] as? Int64 == 0, let written = row["written"] as? Int64,
              let notWritten = row["not_written"] as? Int64, written == 0 || notWritten == 0 else { throw ACPV2ResponseLedgerError.corruptRecord }
        if written > 0 { return .written }
        if notWritten > 0 { return .notWritten }
        return .uncertain
    }
}
