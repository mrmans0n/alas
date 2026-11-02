import Foundation

private struct ResponseStorageField: Sendable {
    let name: String
    let type: String
    let bytes: Int64
    let exact: Bool
    let nullable: Bool
    init(_ name: String, _ type: String, _ bytes: Int64 = Int64(Int32.max), exact: Bool = false, nullable: Bool = false) {
        self.name = name
        self.type = type
        self.bytes = bytes
        self.exact = exact
        self.nullable = nullable
    }
}

extension ACPSessionStore {
    static let responseIntentColumns = "id, stream_id, origin_ordinal, format_version, frame, binding_digest"
    static let responseAttemptColumns = "id, intent_id, sequence, format_version, namespace, operation_key"
    static let responseObservationColumns = "id, attempt_id, sequence, format_version, kind, status, message"
    static let responseStreamColumns = """
    id, session_id, upstream_session_id, source_key, format_version, wire_context, source_kind,
    connection_id, broker_id, broker_generation, initial_cursor,
    CAST(session_id AS BLOB) AS session_bytes, CAST(upstream_session_id AS BLOB) AS upstream_bytes,
    CAST(wire_context AS BLOB) AS context_bytes
    """
    static let responseRequestColumns = """
    stream_id, ordinal, receipt_key, receipt_id, connection_id, broker_cursor, broker_origin,
    pending_request_id, frame, CAST(pending_request_id AS BLOB) AS pending_bytes
    """

    // Only scalar type/byte-length information crosses this boundary. Never
    // materialize a malformed fixed-format field before checking its size.
    private func responseCheckStorage(table: String, predicate: String, bindings: [Any?], fields: [ResponseStorageField]) throws -> Bool {
        let columns = fields.enumerated().map { index, field in
            "typeof(\(field.name)) AS t\(index), length(CAST(\(field.name) AS BLOB)) AS n\(index)"
        }.joined(separator: ",")
        guard let row = try db.query("SELECT \(columns) FROM \(table) WHERE \(predicate)", bindings: bindings).first else { return false }
        for (index, field) in fields.enumerated() {
            let type = row["t\(index)"] as? String
            if type == "null", field.nullable { continue }
            guard type == field.type, let bytes = row["n\(index)"] as? Int64,
                  bytes >= 0, field.exact ? bytes == field.bytes : bytes <= field.bytes else { throw ACPV2ResponseLedgerError.corruptRecord }
        }
        return true
    }

    func responsePreflightIntent(id: UUID) throws -> Bool {
        try responseCheckStorage(table: "acp_v2_response_intents", predicate: "id = ?", bindings: [id.uuidString], fields: [
            .init("id", "text", 36, exact: true), .init("stream_id", "text", 36, exact: true),
            .init("origin_ordinal", "integer", 20), .init("format_version", "integer", 20),
            .init("frame", "blob"), .init("binding_digest", "blob", 32, exact: true),
        ])
    }

    func responsePreflightAttempt(id: UUID) throws -> Bool {
        try responseCheckStorage(table: "acp_v2_response_attempts", predicate: "id = ?", bindings: [id.uuidString], fields: [
            .init("id", "text", 36, exact: true), .init("intent_id", "text", 36, exact: true),
            .init("sequence", "integer", 20), .init("format_version", "integer", 20),
            .init("namespace", "blob", 200), .init("operation_key", "blob"),
        ])
    }

    func responsePreflightObservation(id: UUID) throws -> Bool {
        try responseCheckStorage(table: "acp_v2_response_observations", predicate: "id = ?", bindings: [id.uuidString], fields: [
            .init("id", "text", 36, exact: true), .init("attempt_id", "text", 36, exact: true),
            .init("sequence", "integer", 20), .init("format_version", "integer", 20), .init("kind", "integer", 20),
            .init("status", "integer", 20, nullable: true), .init("message", "blob", nullable: true),
        ])
    }

    func responsePreflightStream(id: UUID) throws -> Bool {
        try responseCheckStorage(table: "acp_v2_inbound_streams", predicate: "id = ?", bindings: [id.uuidString], fields: [
            .init("id", "text", 36, exact: true), .init("session_id", "text"), .init("upstream_session_id", "text"),
            .init("source_key", "text", 200), .init("format_version", "integer", 20), .init("wire_context", "text"),
            .init("source_kind", "text", 6), .init("connection_id", "text", 36, exact: true, nullable: true),
            .init("broker_id", "text", 160, nullable: true), .init("broker_generation", "integer", 20, nullable: true),
            .init("initial_cursor", "integer", 20, nullable: true),
        ])
    }

    func responsePreflightRequest(stream: ACPV2InboundLedgerStream, ordinal: Int64) throws -> Bool {
        try responseCheckStorage(table: "acp_v2_inbound_records", predicate: "stream_id = ? AND ordinal = ?", bindings: [stream.id.uuidString, ordinal], fields: [
            .init("stream_id", "text", 36, exact: true), .init("ordinal", "integer", 20), .init("receipt_key", "text", 64),
            .init("receipt_id", "text", 36, exact: true), .init("connection_id", "text", 36, exact: true),
            .init("broker_cursor", "integer", 20, nullable: true), .init("broker_origin", "text", 32, nullable: true),
            .init("pending_request_id", "text", nullable: true), .init("frame", "blob"),
        ])
    }

    func responseRequireStream(_ stream: ACPV2InboundLedgerStream) throws {
        guard try responsePreflightStream(id: stream.id),
              let row = try db.query("SELECT \(Self.responseStreamColumns) FROM acp_v2_inbound_streams WHERE id = ?", bindings: [stream.id.uuidString]).first,
              try decodeInboundStream(row) == stream else { throw ACPV2ResponseLedgerError.incompatibleSource }
    }
}
