import Foundation
import AlasACP
import AlasPlatform

extension ACPSessionStore {
    // Preserve the original text bytes alongside SQLiteKit's repairing String
    // projection so opaque identity cannot pass validation after lossy decoding.
    static let inboundStreamColumns = "*, CAST(session_id AS BLOB) AS session_bytes, CAST(upstream_session_id AS BLOB) AS upstream_bytes, CAST(wire_context AS BLOB) AS context_bytes"
    static let inboundRecordColumns = "*, CAST(pending_request_id AS BLOB) AS pending_bytes"

    func createV2InboundLedgerSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_inbound_streams (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          upstream_session_id TEXT NOT NULL,
          source_key TEXT NOT NULL UNIQUE,
          format_version INTEGER NOT NULL,
          wire_context TEXT NOT NULL,
          source_kind TEXT NOT NULL,
          connection_id TEXT,
          broker_id TEXT,
          broker_generation INTEGER,
          initial_cursor INTEGER
        )
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS acp_v2_inbound_streams_session ON acp_v2_inbound_streams(session_id)")
        try db.exec("CREATE INDEX IF NOT EXISTS acp_v2_inbound_streams_source ON acp_v2_inbound_streams(source_kind, connection_id, broker_id, broker_generation)")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS acp_v2_inbound_records (
          stream_id TEXT NOT NULL REFERENCES acp_v2_inbound_streams(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK(ordinal > 0),
          receipt_key TEXT NOT NULL,
          receipt_id TEXT NOT NULL,
          connection_id TEXT NOT NULL,
          broker_cursor INTEGER,
          broker_origin TEXT,
          pending_request_id TEXT,
          frame BLOB NOT NULL,
          PRIMARY KEY(stream_id, ordinal),
          UNIQUE(stream_id, receipt_key)
        )
        """)
    }

    public func registerV2InboundLedger(sessionId: String, upstreamSessionId: String,
        source: ACPV2InboundLedgerSource, fence: ACPSessionLeaseFence) throws -> ACPV2InboundLedgerStream {
        guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, sessionId.utf8.count <= Int32.max,
              upstreamSessionId.utf8.count <= Int32.max, fence.sessionId.utf8.elementsEqual(sessionId.utf8) else {
            throw ACPV2InboundLedgerError.invalidInput
        }
        let key = try inboundSourceKey(source)
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
        let kind = connection == nil ? "broker" : "stdio"
        guard let stream = try withLeaseFence(fence, {
            let baseline = try requireCurrentInboundSource(source, sessionId: sessionId)
            // Also find a source whose redundant canonical key was corrupted.
            // A failed key lookup must not allocate a second decoded owner.
            let existingRows = try db.query("""
            SELECT \(Self.inboundStreamColumns) FROM acp_v2_inbound_streams WHERE source_key = ? OR
              (source_kind = ? AND connection_id IS ? AND broker_id IS ? AND broker_generation IS ?) LIMIT 2
            """, bindings: [key, kind, connection, broker, generation])
            if let row = existingRows.first {
                guard existingRows.count == 1 else { throw ACPV2InboundLedgerError.corruptRecord }
                let existing = try decodeInboundStream(row)
                guard existing.sessionId.utf8.elementsEqual(sessionId.utf8),
                      existing.upstreamSessionId.utf8.elementsEqual(upstreamSessionId.utf8), existing.source == source else { throw ACPV2InboundLedgerError.incompatibleStream }
                return existing
            }
            let stream = ACPV2InboundLedgerStream(id: UUID(), sessionId: sessionId, upstreamSessionId: upstreamSessionId,
                source: source, formatVersion: 1, initialBrokerCursor: baseline)
            try db.exec("""
            INSERT INTO acp_v2_inbound_streams
              (id, session_id, upstream_session_id, source_key, format_version, wire_context,
               source_kind, connection_id, broker_id, broker_generation, initial_cursor)
            VALUES (?,?,?,?,1,?,?,?,?,?,?)
            """, bindings: [stream.id.uuidString, sessionId, upstreamSessionId, key,
                try ACPBrokerWireContext.rawV2.persistedJSON(), connection == nil ? "broker" : "stdio",
                connection, broker, generation, baseline.map { Int64($0.rawValue) }])
            return stream
        }) else { throw ACPV2InboundLedgerError.staleLease }
        return stream
    }

    public func retainV2Inbound(_ delivery: ACPV2InboundDelivery, to stream: ACPV2InboundLedgerStream,
        fence: ACPSessionLeaseFence) throws -> ACPV2InboundLedgerReceipt {
        guard fence.sessionId.utf8.elementsEqual(stream.sessionId.utf8), delivery.frame.count <= Int32.max else {
            throw ACPV2InboundLedgerError.invalidInput
        }
        guard let receipt = try withLeaseFence(fence, {
            try requireInboundStream(stream)
            _ = try requireCurrentInboundSource(stream.source, sessionId: stream.sessionId)
            let key = try inboundReceiptKey(delivery, source: stream.source)
            let cursor: Int64?
            let origin: String?
            let pending: String?
            switch delivery.source {
            case .stdio: cursor = nil
            origin = nil
            pending = nil
            case .broker(let provenance, let request):
                cursor = Int64(exactly: provenance.cursor.rawValue)
                origin = provenance.origin.rawValue
                pending = request
            }
            guard (pending?.utf8.count ?? 0) <= Int32.max else { throw ACPV2InboundLedgerError.invalidInput }
            if let row = try db.query("SELECT \(Self.inboundRecordColumns) FROM acp_v2_inbound_records WHERE stream_id = ? AND receipt_key = ?",
                bindings: [stream.id.uuidString, key]).first {
                let existing = try decodeInboundRecord(row, stream: stream)
                let originalPending: String?
                switch existing.source {
                case .stdio: originalPending = nil
                case .broker(_, let id): originalPending = id
                }
                guard existing.frame == delivery.frame,
                      originalPending.map({ Data($0.utf8) }) == pending.map({ Data($0.utf8) }) else { throw ACPV2InboundLedgerError.conflictingReceipt }
                return ACPV2InboundLedgerReceipt(record: existing, wasInserted: false)
            }
            guard let last = try db.query("SELECT COALESCE(MAX(ordinal), 0) AS last FROM acp_v2_inbound_records WHERE stream_id = ?",
                bindings: [stream.id.uuidString]).first?["last"] as? Int64, last >= 0, last < Int64.max else {
                throw ACPV2InboundLedgerError.corruptRecord
            }
            let record = ACPV2InboundLedgerRecord(streamID: stream.id, ordinal: last + 1, receiptID: delivery.receiptID,
                connectionID: delivery.connectionID, source: delivery.source, frame: delivery.frame)
            try db.exec("""
            INSERT INTO acp_v2_inbound_records
              (stream_id, ordinal, receipt_key, receipt_id, connection_id, broker_cursor, broker_origin, pending_request_id, frame)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, bindings: [stream.id.uuidString, record.ordinal, key, record.receiptID.uuidString,
                record.connectionID.uuidString, cursor, origin, pending, record.frame])
            return ACPV2InboundLedgerReceipt(record: record, wasInserted: true)
        }) else { throw ACPV2InboundLedgerError.staleLease }
        return receipt
    }

    private func inboundSourceKey(_ source: ACPV2InboundLedgerSource) throws -> String {
        switch source {
        case .stdio(let id): return "stdio:\(id.uuidString)"
        case .broker(let id, let generation):
            guard let value = Int64(exactly: generation.rawValue), value > 0,
                  !id.rawValue.isEmpty, id.rawValue.utf8.count <= 160,
                  id.rawValue.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw ACPV2InboundLedgerError.invalidInput
            }
            return "broker:\(id.rawValue):\(value)"
        }
    }

    private func requireCurrentInboundSource(_ source: ACPV2InboundLedgerSource, sessionId: String) throws -> ACPBrokerEventCursor? {
        guard let row = try db.query("""
        SELECT acp_broker_id, acp_broker_generation, acp_broker_wire_context, acp_broker_acknowledged_cursor,
          CAST(acp_broker_wire_context AS BLOB) AS context_bytes FROM sessions WHERE id = ?
        """, bindings: [sessionId]).first else { throw ACPV2InboundLedgerError.incompatibleStream }
        switch source {
        case .stdio: return nil
        case .broker(let id, let generation):
            _ = try inboundSourceKey(source)
            // Validate persisted types before the session projection can default
            // a malformed ACK to zero and erase the known-prefix boundary.
            guard let storedID = row["acp_broker_id"] as? String, storedID.utf8.elementsEqual(id.rawValue.utf8),
                  let storedGeneration = row["acp_broker_generation"] as? Int64, storedGeneration > 0,
                  UInt64(storedGeneration) == generation.rawValue,
                  let cursor = row["acp_broker_acknowledged_cursor"] as? Int64, cursor >= 0,
                  let json = strictInboundText(row, column: "acp_broker_wire_context", bytes: "context_bytes"),
                  (try? ACPBrokerRestorePolicy.context(from: json)) == .rawV2 else { throw ACPV2InboundLedgerError.incompatibleStream }
            return .init(rawValue: UInt64(cursor))
        }
    }

    private func inboundReceiptKey(_ delivery: ACPV2InboundDelivery, source: ACPV2InboundLedgerSource) throws -> String {
        switch (source, delivery.source) {
        case (.stdio(let connection), .stdio):
            guard delivery.connectionID == connection else { throw ACPV2InboundLedgerError.incompatibleStream }
            return "stdio:\(delivery.receiptID.uuidString)"
        case (.broker(let id, let generation), .broker(let provenance, _)):
            guard provenance.brokerID.rawValue.utf8.elementsEqual(id.rawValue.utf8), provenance.generation == generation else { throw ACPV2InboundLedgerError.incompatibleStream }
            guard let cursor = Int64(exactly: provenance.cursor.rawValue), cursor > 0 else { throw ACPV2InboundLedgerError.invalidInput }
            return "broker:\(cursor)"
        default: throw ACPV2InboundLedgerError.incompatibleStream
        }
    }

    func requireInboundStream(_ stream: ACPV2InboundLedgerStream) throws {
        guard let row = try db.query("SELECT \(Self.inboundStreamColumns) FROM acp_v2_inbound_streams WHERE id = ?", bindings: [stream.id.uuidString]).first,
              try decodeInboundStream(row) == stream else { throw ACPV2InboundLedgerError.incompatibleStream }
    }

    func decodeInboundStream(_ row: [String: Any?]) throws -> ACPV2InboundLedgerStream {
        guard row["format_version"] as? Int64 == 1, let json = strictInboundText(row, column: "wire_context", bytes: "context_bytes"),
              (try? ACPBrokerRestorePolicy.context(from: json)) == .rawV2 else { throw ACPV2InboundLedgerError.unsupportedFormat }
        guard let id = inboundUUID(row["id"] ?? nil), let session = strictInboundText(row, column: "session_id", bytes: "session_bytes"), !session.isEmpty,
              let upstream = strictInboundText(row, column: "upstream_session_id", bytes: "upstream_bytes"), !upstream.isEmpty else { throw ACPV2InboundLedgerError.corruptRecord }
        let source: ACPV2InboundLedgerSource
        let baseline: ACPBrokerEventCursor?
        switch row["source_kind"] as? String {
        case "stdio":
            guard let connection = inboundUUID(row["connection_id"] ?? nil), row["broker_id"] == nil,
                  row["broker_generation"] == nil, row["initial_cursor"] == nil else { throw ACPV2InboundLedgerError.corruptRecord }
            source = .stdio(connectionID: connection)
            baseline = nil
        case "broker":
            guard row["connection_id"] == nil, let id = row["broker_id"] as? String,
                  let generation = row["broker_generation"] as? Int64, generation > 0,
                  let cursor = row["initial_cursor"] as? Int64, cursor >= 0 else { throw ACPV2InboundLedgerError.corruptRecord }
            source = .broker(id: .init(rawValue: id), generation: .init(rawValue: UInt64(generation)))
            baseline = .init(rawValue: UInt64(cursor))
        default: throw ACPV2InboundLedgerError.unsupportedFormat
        }
        guard let key = try? inboundSourceKey(source), let storedKey = row["source_key"] as? String,
              storedKey.utf8.elementsEqual(key.utf8) else { throw ACPV2InboundLedgerError.corruptRecord }
        return .init(id: id, sessionId: session, upstreamSessionId: upstream, source: source, formatVersion: 1, initialBrokerCursor: baseline)
    }

    func decodeInboundRecord(_ row: [String: Any?], stream: ACPV2InboundLedgerStream) throws -> ACPV2InboundLedgerRecord {
        guard row["stream_id"] as? String == stream.id.uuidString,
              let ordinal = row["ordinal"] as? Int64, ordinal > 0,
              let receipt = inboundUUID(row["receipt_id"] ?? nil), let connection = inboundUUID(row["connection_id"] ?? nil),
              let frame = row["frame"] as? Data, frame.count <= Int32.max else { throw ACPV2InboundLedgerError.corruptRecord }
        let source: ACPV2InboundDelivery.Source
        let key: String
        switch stream.source {
        case .stdio(let expected):
            guard connection == expected, row["broker_cursor"] == nil, row["broker_origin"] == nil,
                  row["pending_request_id"] == nil else { throw ACPV2InboundLedgerError.corruptRecord }
            source = .stdio
            key = "stdio:\(receipt.uuidString)"
        case .broker(let id, let generation):
            guard let cursor = row["broker_cursor"] as? Int64, cursor > 0,
                  let rawOrigin = row["broker_origin"] as? String,
                  let origin = ACPBrokerFrameProvenance.Origin(rawValue: rawOrigin) else { throw ACPV2InboundLedgerError.corruptRecord }
            let pending: String?
            if row["pending_request_id"] != nil {
                guard let value = strictInboundText(row, column: "pending_request_id", bytes: "pending_bytes") else { throw ACPV2InboundLedgerError.corruptRecord }
                pending = value
            } else { pending = nil }
            source = .broker(provenance: .init(brokerID: id, generation: generation, cursor: .init(rawValue: UInt64(cursor)), origin: origin),
                pendingRequestID: pending)
            key = "broker:\(cursor)"
        }
        guard key == row["receipt_key"] as? String else { throw ACPV2InboundLedgerError.corruptRecord }
        return .init(streamID: stream.id, ordinal: ordinal, receiptID: receipt, connectionID: connection, source: source, frame: frame)
    }

    private func strictInboundText(_ row: [String: Any?], column: String, bytes: String) -> String? {
        guard row[column] is String, let data = row[bytes] as? Data, data.count <= Int32.max else { return nil }
        return String(validating: data, as: UTF8.self)
    }

    private func inboundUUID(_ value: Any?) -> UUID? {
        guard let raw = value as? String, let id = UUID(uuidString: raw), raw == id.uuidString else { return nil }
        return id
    }
}
