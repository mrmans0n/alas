import Foundation

extension ACPSessionStore {
    public func loadV2SubmissionPage(sessionId: String, upstreamSessionId: String, source: ACPV2SubmissionSource,
        after: ACPV2SubmissionContinuation? = nil, maxRecords: Int = 128, maxBytes: Int = 1_048_576) throws -> ACPV2SubmissionPage {
        guard !sessionId.isEmpty, !upstreamSessionId.isEmpty, (1...1000).contains(maxRecords),
              maxBytes > 0, maxBytes <= Int32.max else { throw ACPV2SubmissionLedgerError.invalidInput }
        try validateSubmissionSource(source)
        if let after {
            guard after.sessionId == sessionId, after.upstreamSessionId == upstreamSessionId,
                  after.source == source, after.afterSequence > 0 else { throw ACPV2SubmissionLedgerError.invalidInput }
        }
        let key = try submissionStorageJSON(source)
        return try db.transaction {
            let position = after?.afterSequence ?? 0
            if after != nil {
                guard try !db.query("""
                SELECT id FROM acp_v2_submissions WHERE session_id = ? AND upstream_session_id = ? AND source_key = ? AND sequence = ?
                """, bindings: [sessionId, upstreamSessionId, key, position]).isEmpty else { throw ACPV2SubmissionLedgerError.invalidInput }
            }
            // Count registration-only records too, and inspect lengths without
            // materializing every outcome BLOB before applying the byte budget.
            let candidates = try db.query("""
            SELECT s.sequence, COALESCE(length(o.frame), 0) AS bytes FROM acp_v2_submissions s
            LEFT JOIN acp_v2_submission_outcomes o ON o.submission_id = s.id
            WHERE s.session_id = ? AND s.upstream_session_id = ? AND s.source_key = ? AND s.sequence > ?
            ORDER BY s.sequence LIMIT ?
            """, bindings: [sessionId, upstreamSessionId, key, position, maxRecords + 1])
            var count = 0
            var end = position
            var total: Int64 = 0
            var oversized = false
            for row in candidates {
                guard let sequence = row["sequence"] as? Int64, sequence > position, let next = Int(exactly: sequence),
                      let bytes = row["bytes"] as? Int64, bytes >= 0, bytes <= Int32.max else { throw ACPV2SubmissionLedgerError.corruptRecord }
                guard count < maxRecords else { break }
                if bytes > Int64(maxBytes) - total {
                    if count == 0 { count = 1
                    end = next
                    oversized = true }
                    break
                }
                count += 1
                end = next
                total += bytes
            }
            let records = try db.query("""
            SELECT * FROM acp_v2_submissions WHERE session_id = ? AND upstream_session_id = ? AND source_key = ?
              AND sequence > ? AND sequence <= ? ORDER BY sequence
            """, bindings: [sessionId, upstreamSessionId, key, position, end]).map { try decodeSubmissionRecord($0) }
            guard records.count == count else { throw ACPV2SubmissionLedgerError.corruptRecord }
            let atEnd = count == candidates.count
            let next = atEnd ? nil : ACPV2SubmissionContinuation(sessionId: sessionId, upstreamSessionId: upstreamSessionId,
                source: source, afterSequence: end)
            return .init(records: records, next: next, isAtEnd: atEnd, containsOversizedRecord: oversized)
        }
    }
}
