import Foundation

extension ACPSessionStore {
    public func loadV2ResponseIntent(id: UUID) throws -> ACPV2ResponseIntent? {
        try db.transaction { try responseIntent(id: id) }
    }

    // Include parent payload needed for validation before loading it. Child
    // pages conservatively count this cost per record, even though it is cached
    // only for the duration of one read transaction.
    private static let responsePayloadSizeSQL = """
    SELECT i.id, i.stream_id, i.format_version,
      length(i.frame) + length(i.binding_digest) + length(r.frame) + length(CAST(s.session_id AS BLOB)) +
      length(CAST(s.upstream_session_id AS BLOB)) + length(CAST(s.wire_context AS BLOB)) +
      length(CAST(s.source_key AS BLOB)) + COALESCE(length(CAST(r.pending_request_id AS BLOB)),0) AS bytes
    FROM acp_v2_response_intents i
    LEFT JOIN acp_v2_inbound_records r ON r.stream_id = i.stream_id AND r.ordinal = i.origin_ordinal
    LEFT JOIN acp_v2_inbound_streams s ON s.id = i.stream_id
    """

    public func loadV2ResponseIntentPage(stream: ACPV2InboundLedgerStream, after: ACPV2ResponseLedgerContinuation? = nil,
        maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2ResponseLedgerPage<ACPV2ResponseIntent> {
        try db.transaction {
            try responseRequireStream(stream)
            let sizeSQL = "(SELECT bytes FROM (\(Self.responsePayloadSizeSQL)) WHERE id = v.id)"
            return try responsePage(kind: .intents, parentID: stream.id, table: "acp_v2_response_intents", parentColumn: "stream_id",
                sequenceColumn: "origin_ordinal", sizeSQL: sizeSQL, after: after, maxRecords: maxRecords, maxBytes: maxBytes) { id in
                guard let intent = try self.responseIntent(id: id), intent.stream == stream else { throw ACPV2ResponseLedgerError.corruptRecord }
                return intent
            }
        }
    }

    public func loadV2ResponseAttemptPage(intentID: UUID, after: ACPV2ResponseLedgerContinuation? = nil,
        maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2ResponseLedgerPage<ACPV2ResponseAttemptRecord> {
        try db.transaction {
            let parentBytes = try responseIntentPayloadSize(id: intentID)
            var cached: ACPV2ResponseIntent?
            return try responsePage(kind: .attempts, parentID: intentID, table: "acp_v2_response_attempts", parentColumn: "intent_id",
                sequenceColumn: "sequence", sizeSQL: "length(v.operation_key) + length(v.namespace) + \(parentBytes)", after: after, maxRecords: maxRecords, maxBytes: maxBytes,
                contextBytes: parentBytes, validateContext: { cached = try self.responseIntent(id: intentID) }) { id in
                guard try self.responsePreflightAttempt(id: id) else { throw ACPV2ResponseLedgerError.corruptRecord }
                guard let intent = cached,
                      let row = try self.db.query("SELECT \(Self.responseAttemptColumns) FROM acp_v2_response_attempts WHERE id = ?", bindings: [id.uuidString]).first else { throw ACPV2ResponseLedgerError.corruptRecord }
                let attempt = try self.decodeResponseAttempt(row, intent: intent)
                return try .init(attempt: attempt, recovery: self.responseAttemptRecovery(attempt, intent: intent))
            }
        }
    }

    public func loadV2ResponseObservationPage(attemptID: UUID, after: ACPV2ResponseLedgerContinuation? = nil,
        maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2ResponseLedgerPage<ACPV2ResponseObservation> {
        try db.transaction {
            guard try responsePreflightAttempt(id: attemptID), let row = try db.query("SELECT intent_id, length(operation_key) + length(namespace) AS bytes, format_version FROM acp_v2_response_attempts WHERE id = ?",
                bindings: [attemptID.uuidString]).first else { throw ACPV2ResponseLedgerError.invalidInput }
            guard row["format_version"] as? Int64 == 1 else { throw ACPV2ResponseLedgerError.unsupportedFormat }
            guard let intentID = responseUUID(row["intent_id"] ?? nil), let keyBytes = row["bytes"] as? Int64,
                  keyBytes >= 0, keyBytes <= Int64(Int32.max) * 2 else { throw ACPV2ResponseLedgerError.corruptRecord }
            let parentBytes = try responseIntentPayloadSize(id: intentID) + keyBytes
            var cached: (ACPV2ResponseIntent, ACPV2ResponseAttempt)?
            return try responsePage(kind: .observations, parentID: attemptID, table: "acp_v2_response_observations", parentColumn: "attempt_id",
                sequenceColumn: "sequence", sizeSQL: "COALESCE(length(v.message),0) + \(parentBytes)", after: after, maxRecords: maxRecords, maxBytes: maxBytes,
                contextBytes: parentBytes, validateContext: {
                    cached = try self.responseAttemptParents(id: attemptID)
                    if let (intent, attempt) = cached { _ = try self.responseAttemptRecovery(attempt, intent: intent) }
                }) { id in
                guard try self.responsePreflightObservation(id: id) else { throw ACPV2ResponseLedgerError.corruptRecord }
                guard let (intent, attempt) = cached,
                      let row = try self.db.query("SELECT \(Self.responseObservationColumns) FROM acp_v2_response_observations WHERE id = ?", bindings: [id.uuidString]).first else { throw ACPV2ResponseLedgerError.corruptRecord }
                return try self.decodeResponseObservation(row, attempt: attempt, intent: intent)
            }
        }
    }

    private func responseIntentPayloadSize(id: UUID) throws -> Int64 {
        guard try responsePreflightIntent(id: id) else { throw ACPV2ResponseLedgerError.invalidInput }
        guard let row = try db.query("\(Self.responsePayloadSizeSQL) WHERE i.id = ?", bindings: [id.uuidString]).first else { throw ACPV2ResponseLedgerError.invalidInput }
        guard row["format_version"] as? Int64 == 1 else { throw ACPV2ResponseLedgerError.unsupportedFormat }
        guard responseUUID(row["id"] ?? nil) == id, responseUUID(row["stream_id"] ?? nil) != nil,
              let bytes = row["bytes"] as? Int64, bytes >= 0, bytes <= Int64(Int32.max) * 8 else { throw ACPV2ResponseLedgerError.corruptRecord }
        return bytes
    }

    private func responsePage<Value: Equatable & Sendable>(kind: ACPV2ResponseLedgerContinuation.Kind, parentID: UUID,
        table: String, parentColumn: String, sequenceColumn: String, sizeSQL: String,
        after: ACPV2ResponseLedgerContinuation?, maxRecords: Int, maxBytes: Int,
        contextBytes: Int64 = 0, validateContext: () throws -> Void = {}, decode: (UUID) throws -> Value) throws -> ACPV2ResponseLedgerPage<Value> {
        guard (1...1000).contains(maxRecords), maxBytes > 0, maxBytes <= Int32.max else { throw ACPV2ResponseLedgerError.invalidInput }
        let start = after?.afterSequence ?? 0
        if let after {
            guard after.kind == kind, after.parentID == parentID, start > 0,
                  try !db.query("SELECT 1 FROM \(table) WHERE \(parentColumn) = ? AND \(sequenceColumn) = ?",
                    bindings: [parentID.uuidString, start]).isEmpty else { throw ACPV2ResponseLedgerError.invalidInput }
        }
        let candidates = try db.query("""
        SELECT substr(v.id,1,36) AS id, typeof(v.id) AS id_type, length(CAST(v.id AS BLOB)) AS id_bytes, v.\(sequenceColumn) AS position, \(sizeSQL) AS bytes FROM \(table) v
        WHERE v.\(parentColumn) = ? AND v.\(sequenceColumn) > ? ORDER BY v.\(sequenceColumn) LIMIT ?
        """, bindings: [parentID.uuidString, start, maxRecords + 1])
        var selected: [(UUID, Int64)] = []
        var total: Int64 = 0
        var oversized = false
        for row in candidates {
            guard row["id_type"] as? String == "text", row["id_bytes"] as? Int64 == 36,
                  let id = responseUUID(row["id"] ?? nil), let position = row["position"] as? Int64, position > start,
                  let bytes = row["bytes"] as? Int64, bytes >= 0 else { throw ACPV2ResponseLedgerError.corruptRecord }
            guard selected.count < maxRecords else { break }
            if bytes > Int64(maxBytes) - total {
                if selected.isEmpty { selected.append((id, position))
                oversized = true }
                break
            }
            selected.append((id, position))
            total += bytes
        }
        try validateContext()
        if selected.isEmpty, contextBytes > Int64(maxBytes) { oversized = true }
        let records = try selected.map { try decode($0.0) }
        let atEnd = selected.count == candidates.count
        let next = atEnd ? nil : ACPV2ResponseLedgerContinuation(kind: kind, parentID: parentID, afterSequence: selected.last?.1 ?? start)
        return .init(records: records, next: next, isAtEnd: atEnd, containsOversizedRecord: oversized)
    }
}
