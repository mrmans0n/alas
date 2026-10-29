import Foundation
import AlasACP
import AlasPlatform

extension ACPSessionStore {
    func createV2UpdateJournalSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_update_streams (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          upstream_session_id TEXT NOT NULL,
          source_key TEXT NOT NULL,
          format_version INTEGER NOT NULL,
          wire_context TEXT NOT NULL,
          source_kind TEXT NOT NULL,
          connection_id TEXT,
          broker_id TEXT,
          broker_generation INTEGER,
          initial_cursor INTEGER,
          UNIQUE(session_id, source_key)
        )
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS acp_v2_update_streams_session ON acp_v2_update_streams(session_id)")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_update_records (
          stream_id TEXT NOT NULL REFERENCES acp_v2_update_streams(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK(ordinal > 0),
          receipt_key TEXT NOT NULL,
          receipt_id TEXT NOT NULL,
          connection_id TEXT NOT NULL,
          broker_cursor INTEGER,
          broker_origin TEXT,
          frame BLOB NOT NULL,
          PRIMARY KEY(stream_id, ordinal),
          UNIQUE(stream_id, receipt_key)
        )
        """)
    }

    public func registerV2UpdateJournal(sessionId: String, upstreamSessionId: String,
        source: ACPV2UpdateJournalSource, fence: ACPSessionLeaseFence) throws -> ACPV2UpdateJournalStream {
        guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, fence.sessionId == sessionId else {
            throw ACPV2UpdateJournalError.invalidInput
        }
        guard let stream = try withLeaseFence(fence, {
            let baseline = try validateV2JournalSource(source, sessionId: sessionId)
            let key = try v2JournalSourceKey(source)
            if let row = try db.query("SELECT * FROM acp_v2_update_streams WHERE session_id = ? AND source_key = ?",
                bindings: [sessionId, key]).first {
                let existing = try decodeV2JournalStream(row)
                guard existing.upstreamSessionId == upstreamSessionId, existing.source == source else {
                    throw ACPV2UpdateJournalError.incompatibleStream
                }
                return existing
            }
            let stream = ACPV2UpdateJournalStream(id: UUID(), sessionId: sessionId,
                upstreamSessionId: upstreamSessionId, source: source, initialBrokerCursor: baseline)
            let connection: String?
            let broker: String?
            let generation: Int64?
            switch source {
            case .stdio(let id): connection = id.uuidString
            broker = nil
            generation = nil
            case .broker(let id, let value): connection = nil
            broker = id.rawValue
            generation = Int64(exactly: value.rawValue)
            }
            try db.exec("""
            INSERT INTO acp_v2_update_streams
              (id, session_id, upstream_session_id, source_key, format_version, wire_context,
               source_kind, connection_id, broker_id, broker_generation, initial_cursor)
            VALUES (?,?,?,?,1,?,?,?,?,?,?)
            """, bindings: [stream.id.uuidString, sessionId, upstreamSessionId, key,
                try ACPBrokerWireContext.rawV2.persistedJSON(), connection == nil ? "broker" : "stdio",
                connection, broker, generation, baseline.map { Int64($0.rawValue) }])
            return stream
        }) else { throw ACPV2UpdateJournalError.staleLease }
        return stream
    }

    public func appendV2Update(_ delivery: ACPV2SessionUpdateDelivery, to stream: ACPV2UpdateJournalStream,
        fence: ACPSessionLeaseFence) throws -> ACPV2UpdateJournalReceipt {
        guard fence.sessionId == stream.sessionId, delivery.frame.count <= Int32.max else {
            throw ACPV2UpdateJournalError.invalidInput
        }
        guard let receipt = try withLeaseFence(fence, {
            try requireV2JournalStream(stream)
            _ = try validateV2JournalSource(stream.source, sessionId: stream.sessionId)
            let key = try v2JournalReceiptKey(delivery, source: stream.source)
            if let row = try db.query("SELECT * FROM acp_v2_update_records WHERE stream_id = ? AND receipt_key = ?",
                bindings: [stream.id.uuidString, key]).first {
                let existing = try decodeV2JournalRecord(row, stream: stream)
                guard existing.frame == delivery.frame else { throw ACPV2UpdateJournalError.conflictingReceipt }
                return ACPV2UpdateJournalReceipt(record: existing, wasInserted: false)
            }
            let last = try db.query("SELECT COALESCE(MAX(ordinal), 0) AS last FROM acp_v2_update_records WHERE stream_id = ?",
                bindings: [stream.id.uuidString]).first?["last"] as? Int64
            guard let last, last >= 0, last < Int64.max else { throw ACPV2UpdateJournalError.corruptRecord }
            let record = ACPV2UpdateJournalRecord(streamID: stream.id, ordinal: last + 1, receiptID: delivery.receiptID,
                connectionID: delivery.connectionID, brokerProvenance: delivery.brokerProvenance, frame: delivery.frame)
            try db.exec("""
            INSERT INTO acp_v2_update_records
              (stream_id, ordinal, receipt_key, receipt_id, connection_id, broker_cursor, broker_origin, frame)
            VALUES (?,?,?,?,?,?,?,?)
            """, bindings: [stream.id.uuidString, record.ordinal, key, record.receiptID.uuidString,
                record.connectionID.uuidString, delivery.brokerProvenance.map { Int64($0.cursor.rawValue) },
                delivery.brokerProvenance?.origin.rawValue, record.frame])
            return ACPV2UpdateJournalReceipt(record: record, wasInserted: true)
        }) else { throw ACPV2UpdateJournalError.staleLease }
        return receipt
    }

    /// Discovers one historical stream at a time, newest first. Passing its ID
    /// returns the preceding stream without requiring current broker authority.
    public func loadV2UpdateJournalStream(sessionId: String, beforeStreamID: UUID? = nil) throws -> ACPV2UpdateJournalStream? {
        guard !sessionId.isEmpty else { throw ACPV2UpdateJournalError.invalidInput }
        return try db.transaction {
            var sql = "SELECT * FROM acp_v2_update_streams WHERE session_id = ?"
            var bindings: [Any?] = [sessionId]
            if let beforeStreamID {
                guard let row = try db.query("SELECT rowid AS position FROM acp_v2_update_streams WHERE session_id = ? AND id = ?",
                    bindings: [sessionId, beforeStreamID.uuidString]).first,
                    let position = row["position"] as? Int64, position > 0 else { throw ACPV2UpdateJournalError.invalidInput }
                sql += " AND rowid < ?"
                bindings.append(position)
            }
            sql += " ORDER BY rowid DESC LIMIT 1"
            return try db.query(sql, bindings: bindings).first.map { try decodeV2JournalStream($0) }
        }
    }

    public func loadV2UpdateJournalPage(stream: ACPV2UpdateJournalStream,
        after: ACPV2UpdateJournalContinuation? = nil, maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2UpdateJournalPage {
        guard (1...1000).contains(maxRecords), maxBytes > 0, maxBytes <= Int32.max else {
            throw ACPV2UpdateJournalError.invalidInput
        }
        if let after {
            guard after.streamID == stream.id, after.afterOrdinal > 0 else { throw ACPV2UpdateJournalError.invalidInput }
        }
        return try db.transaction {
            try requireV2JournalStream(stream)
            let start = after?.afterOrdinal ?? 0
            if after != nil {
                guard try !db.query("SELECT 1 FROM acp_v2_update_records WHERE stream_id = ? AND ordinal = ?",
                    bindings: [stream.id.uuidString, start]).isEmpty else { throw ACPV2UpdateJournalError.invalidInput }
            }
            // Inspect lengths first, so a count-bounded query cannot materialize
            // many large blobs before applying the byte budget.
            let candidates = try db.query("""
            SELECT ordinal, length(frame) AS bytes FROM acp_v2_update_records
            WHERE stream_id = ? AND ordinal > ? ORDER BY ordinal LIMIT ?
            """, bindings: [stream.id.uuidString, start, maxRecords + 1])
            var selected: [(ordinal: Int64, bytes: Int64)] = []
            var total: Int64 = 0
            let budget = Int64(maxBytes)
            var oversized = false
            for row in candidates {
                guard let ordinal = row["ordinal"] as? Int64, ordinal > start,
                      let bytes = row["bytes"] as? Int64, bytes >= 0, bytes <= Int32.max else {
                    throw ACPV2UpdateJournalError.corruptRecord
                }
                guard selected.count < maxRecords else { break }
                if bytes > budget - total {
                    if selected.isEmpty { selected.append((ordinal, bytes))
                    oversized = true }
                    break
                }
                selected.append((ordinal, bytes))
                total += bytes
            }
            let records: [ACPV2UpdateJournalRecord]
            if let end = selected.last?.ordinal {
                records = try db.query("""
                SELECT * FROM acp_v2_update_records WHERE stream_id = ? AND ordinal > ? AND ordinal <= ? ORDER BY ordinal
                """, bindings: [stream.id.uuidString, start, end]).map { try decodeV2JournalRecord($0, stream: stream) }
                guard records.count == selected.count else { throw ACPV2UpdateJournalError.corruptRecord }
            } else { records = [] }
            let atEnd = selected.count == candidates.count
            let next = !atEnd ? records.last.map { ACPV2UpdateJournalContinuation(streamID: stream.id, afterOrdinal: $0.ordinal) } : nil
            return ACPV2UpdateJournalPage(records: records, next: next, isAtEnd: atEnd,
                hasKnownMissingPrefix: (stream.initialBrokerCursor?.rawValue ?? 0) > 0, containsOversizedRecord: oversized)
        }
    }

    private func validateV2JournalSource(_ source: ACPV2UpdateJournalSource, sessionId: String) throws -> ACPBrokerEventCursor? {
        guard let row = try loadSession(id: sessionId) else { throw ACPV2UpdateJournalError.incompatibleStream }
        switch source {
        case .stdio: return nil
        case .broker(let id, let generation):
            _ = try v2JournalSourceKey(source)
            guard let stored = try ACPBrokerRestorePolicy.resolve(row: row, supportedVersions: [.v2]),
                  stored.brokerId == id, stored.generation == generation, stored.wireContext == .rawV2 else {
                throw ACPV2UpdateJournalError.incompatibleStream
            }
            return stored.acknowledgedCursor
        }
    }

    private func v2JournalSourceKey(_ source: ACPV2UpdateJournalSource) throws -> String {
        switch source {
        case .stdio(let id): return "stdio:\(id.uuidString)"
        case .broker(let id, let generation):
            guard let value = Int64(exactly: generation.rawValue), value > 0,
                  !id.rawValue.isEmpty, id.rawValue.utf8.count <= 160,
                  id.rawValue.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw ACPV2UpdateJournalError.invalidInput
            }
            return "broker:\(id.rawValue):\(value)"
        }
    }

    private func v2JournalReceiptKey(_ delivery: ACPV2SessionUpdateDelivery, source: ACPV2UpdateJournalSource) throws -> String {
        switch source {
        case .stdio(let connection):
            guard delivery.connectionID == connection, delivery.brokerProvenance == nil else {
                throw ACPV2UpdateJournalError.incompatibleStream
            }
            return "stdio:\(delivery.receiptID.uuidString)"
        case .broker(let id, let generation):
            guard let provenance = delivery.brokerProvenance,
                  provenance.brokerID == id, provenance.generation == generation,
                  let cursor = Int64(exactly: provenance.cursor.rawValue), cursor > 0 else {
                throw ACPV2UpdateJournalError.invalidInput
            }
            return "broker:\(cursor)"
        }
    }

    func requireV2JournalStream(_ stream: ACPV2UpdateJournalStream) throws {
        guard let row = try db.query("SELECT * FROM acp_v2_update_streams WHERE id = ?", bindings: [stream.id.uuidString]).first,
              try decodeV2JournalStream(row) == stream else { throw ACPV2UpdateJournalError.incompatibleStream }
    }

    private func decodeV2JournalStream(_ row: [String: Any?]) throws -> ACPV2UpdateJournalStream {
        guard row["format_version"] as? Int64 == 1, let json = row["wire_context"] as? String,
              (try? ACPBrokerRestorePolicy.context(from: json)) == .rawV2 else { throw ACPV2UpdateJournalError.unsupportedFormat }
        guard let rawID = row["id"] as? String, let id = UUID(uuidString: rawID),
              let session = row["session_id"] as? String, !session.isEmpty,
              let upstream = row["upstream_session_id"] as? String, !upstream.isEmpty else { throw ACPV2UpdateJournalError.corruptRecord }
        let source: ACPV2UpdateJournalSource
        let baseline: ACPBrokerEventCursor?
        switch row["source_kind"] as? String {
        case "stdio":
            guard let raw = row["connection_id"] as? String, let connection = UUID(uuidString: raw),
                  row["broker_id"] == nil, row["broker_generation"] == nil, row["initial_cursor"] == nil else {
                throw ACPV2UpdateJournalError.corruptRecord
            }
            source = .stdio(connectionID: connection)
            baseline = nil
        case "broker":
            guard row["connection_id"] == nil, let broker = row["broker_id"] as? String,
                  let gen = row["broker_generation"] as? Int64, gen > 0,
                  let cursor = row["initial_cursor"] as? Int64, cursor >= 0 else { throw ACPV2UpdateJournalError.corruptRecord }
            source = .broker(id: .init(rawValue: broker), generation: .init(rawValue: UInt64(gen)))
            baseline = .init(rawValue: UInt64(cursor))
        default: throw ACPV2UpdateJournalError.unsupportedFormat
        }
        guard try v2JournalSourceKey(source) == row["source_key"] as? String else { throw ACPV2UpdateJournalError.corruptRecord }
        return .init(id: id, sessionId: session, upstreamSessionId: upstream, source: source, initialBrokerCursor: baseline)
    }

    func decodeV2JournalRecord(_ row: [String: Any?], stream: ACPV2UpdateJournalStream) throws -> ACPV2UpdateJournalRecord {
        guard row["stream_id"] as? String == stream.id.uuidString,
              let ordinal = row["ordinal"] as? Int64, ordinal > 0,
              let rawReceipt = row["receipt_id"] as? String, let receipt = UUID(uuidString: rawReceipt),
              let rawConnection = row["connection_id"] as? String, let connection = UUID(uuidString: rawConnection),
              let frame = row["frame"] as? Data else { throw ACPV2UpdateJournalError.corruptRecord }
        let provenance: ACPBrokerFrameProvenance?
        let key: String
        switch stream.source {
        case .stdio(let expected):
            guard connection == expected, row["broker_cursor"] == nil, row["broker_origin"] == nil else { throw ACPV2UpdateJournalError.corruptRecord }
            provenance = nil
            key = "stdio:\(receipt.uuidString)"
        case .broker(let id, let generation):
            guard let cursor = row["broker_cursor"] as? Int64, cursor > 0,
                  let rawOrigin = row["broker_origin"] as? String,
                  let origin = ACPBrokerFrameProvenance.Origin(rawValue: rawOrigin) else { throw ACPV2UpdateJournalError.corruptRecord }
            provenance = .init(brokerID: id, generation: generation, cursor: .init(rawValue: UInt64(cursor)), origin: origin)
            key = "broker:\(cursor)"
        }
        guard row["receipt_key"] as? String == key else { throw ACPV2UpdateJournalError.corruptRecord }
        return .init(streamID: stream.id, ordinal: ordinal, receiptID: receipt, connectionID: connection, brokerProvenance: provenance, frame: frame)
    }
}
