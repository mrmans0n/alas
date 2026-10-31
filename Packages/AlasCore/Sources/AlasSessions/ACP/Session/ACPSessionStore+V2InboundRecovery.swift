import Foundation

extension ACPSessionStore {
    /// Discovers historical streams without requiring current writer/source authority.
    public func loadV2InboundLedgerStream(sessionId: String, beforeStreamID: UUID? = nil) throws -> ACPV2InboundLedgerStream? {
        guard !sessionId.isEmpty, sessionId.utf8.count <= Int32.max else { throw ACPV2InboundLedgerError.invalidInput }
        return try db.transaction {
            var sql = "SELECT \(Self.inboundStreamColumns) FROM acp_v2_inbound_streams WHERE session_id = ?"
            var bindings: [Any?] = [sessionId]
            if let beforeStreamID {
                guard let row = try db.query("SELECT rowid AS position FROM acp_v2_inbound_streams WHERE session_id = ? AND id = ?",
                    bindings: [sessionId, beforeStreamID.uuidString]).first,
                    let position = row["position"] as? Int64, position > 0 else { throw ACPV2InboundLedgerError.invalidInput }
                sql += " AND rowid < ?"
                bindings.append(position)
            }
            sql += " ORDER BY rowid DESC LIMIT 1"
            return try db.query(sql, bindings: bindings).first.map { try decodeInboundStream($0) }
        }
    }

    public func loadV2InboundLedgerPage(stream: ACPV2InboundLedgerStream,
        after: ACPV2InboundLedgerContinuation? = nil, maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2InboundLedgerPage {
        guard (1...1000).contains(maxRecords), maxBytes > 0, maxBytes <= Int32.max else { throw ACPV2InboundLedgerError.invalidInput }
        if let after {
            guard after.streamID == stream.id, after.afterOrdinal > 0 else { throw ACPV2InboundLedgerError.invalidInput }
        }
        return try db.transaction {
            try requireInboundStream(stream)
            let start = after?.afterOrdinal ?? 0
            if after != nil {
                guard try !db.query("SELECT 1 FROM acp_v2_inbound_records WHERE stream_id = ? AND ordinal = ?",
                    bindings: [stream.id.uuidString, start]).isEmpty else { throw ACPV2InboundLedgerError.invalidInput }
            }
            // Bound the metadata query before selecting which BLOBs to load.
            let candidates = try db.query("""
            SELECT ordinal, length(frame) AS bytes FROM acp_v2_inbound_records
            WHERE stream_id = ? AND ordinal > ? ORDER BY ordinal LIMIT ?
            """, bindings: [stream.id.uuidString, start, maxRecords + 1])
            var count = 0
            var end = start
            var total: Int64 = 0
            var oversized = false
            for row in candidates {
                guard let ordinal = row["ordinal"] as? Int64, ordinal > start,
                      let bytes = row["bytes"] as? Int64, bytes >= 0, bytes <= Int32.max else { throw ACPV2InboundLedgerError.corruptRecord }
                guard count < maxRecords else { break }
                if bytes > Int64(maxBytes) - total {
                    if count == 0 { count = 1
                    end = ordinal
                    oversized = true }
                    break
                }
                count += 1
                end = ordinal
                total += bytes
            }
            let records = try db.query("""
            SELECT \(Self.inboundRecordColumns) FROM acp_v2_inbound_records WHERE stream_id = ? AND ordinal > ? AND ordinal <= ? ORDER BY ordinal
            """, bindings: [stream.id.uuidString, start, end]).map { try decodeInboundRecord($0, stream: stream) }
            guard records.count == count else { throw ACPV2InboundLedgerError.corruptRecord }
            let atEnd = count == candidates.count
            let next = atEnd ? nil : ACPV2InboundLedgerContinuation(streamID: stream.id, afterOrdinal: end)
            return .init(records: records, next: next, isAtEnd: atEnd,
                hasKnownMissingPrefix: (stream.initialBrokerCursor?.rawValue ?? 0) > 0, containsOversizedRecord: oversized)
        }
    }
}
