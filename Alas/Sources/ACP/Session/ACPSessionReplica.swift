import Foundation

struct ACPSessionReplicaExport: Sendable {
    struct Receipt: Sendable {
        let kind: String
        let key: String
        let serial: Int64
    }
    let batchId: String
    let entries: [RemoteSessionReplicaEntry]
    let receipts: [Receipt]
}

struct ACPSessionReplicaImportGuard: Sendable {
    let sessionId: String
    let expectedLocalFence: ACPSessionLeaseFence?
}

private struct ReplicaMetadata: Codable {
    let title: String
    let titleSource: ACPSessionTitleSource
    let origin: ACPSessionOrigin
    let contextRecoveryPending: Bool
    let mcpPreamblePending: String?
    let mcpPreambleSent: Bool
    let authStatus: ACPAuthStatus?
    let currentModel: String?
    let currentMode: String?
    let configOptionValues: [String: ACPConfigValue]
    let nativeSubagentsDisabled: Bool?
    let promptSuggestions: [ACPPromptSuggestion]?
    let autoRun: Bool
    let createdAt: Int64
    let updatedAt: Int64

    init(_ row: ACPSessionRow) {
        title = row.title
        titleSource = row.titleSource
        origin = row.origin
        contextRecoveryPending = row.contextRecoveryPending
        mcpPreamblePending = row.mcpPreamblePending
        mcpPreambleSent = row.mcpPreambleSent
        authStatus = row.authStatus
        currentModel = row.currentModel
        currentMode = row.currentMode
        configOptionValues = row.configOptionValues
        nativeSubagentsDisabled = row.nativeSubagentsDisabled
        promptSuggestions = row.promptSuggestions
        autoRun = row.autoRun
        createdAt = row.createdAt
        updatedAt = row.updatedAt
    }
}

private struct ReplicaReference: Codable {
    let recordId: String?
    let agentId: String
    let remoteSessionId: String?
}
private struct ReplicaMessage: Codable {
    let kind: String
    let seq: Int64
    let payload: Data
    let createdAt: Int64
    let subagentSessionId: String?
    let delegatedReference: ReplicaReference?
}
private struct ReplicaQueue: Codable {
    let payload: Data
    let delegatedReferences: [String: ReplicaReference]
}
private struct ReplicaFork: Codable {
    let source: ReplicaReference
    let sourceBoundarySequence: Int64
    let inheritedMessageCount: Int
    let phase: ACPSessionForkCreationPhase
    let mechanism: ACPSessionForkMechanism?
    let contextDeliveryPending: Bool
    let via: String?
}

enum ACPSessionReplicaError: Error {
    case localWriterActive, invalidPage, missingSession, invalidReference
}

extension ACPSessionStore {
    func createReplicaSchema() throws {
        for sql in [
            "CREATE TABLE IF NOT EXISTS session_replica_exports(session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE, record_id TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS session_replica_serial(serial INTEGER NOT NULL)",
            "INSERT INTO session_replica_serial SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM session_replica_serial)",
            "CREATE TABLE IF NOT EXISTS session_replica_dirty(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,kind TEXT NOT NULL,item_key TEXT NOT NULL,serial INTEGER NOT NULL,PRIMARY KEY(session_id,kind,item_key))",
            "CREATE TABLE IF NOT EXISTS session_replica_links(session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,record_id TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS session_replica_cursors(session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,record_id TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS session_replica_staging(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,record_id TEXT NOT NULL,kind TEXT NOT NULL,item_key TEXT NOT NULL,payload BLOB,revision INTEGER NOT NULL,cutoff_revision INTEGER NOT NULL,PRIMARY KEY(session_id,kind,item_key))",
            "CREATE TABLE IF NOT EXISTS session_replica_reads(session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,record_id TEXT NOT NULL,cutoff_revision INTEGER NOT NULL,initial INTEGER NOT NULL,complete INTEGER NOT NULL DEFAULT 0)",
            "CREATE TABLE IF NOT EXISTS session_replica_relations(session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,relation_key TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(session_id,relation_key))"
        ] { try db.exec(sql) }
        let tables: [(String, String, String, String)] = [
            ("messages", "message", "session_id", "CAST(ROW.seq AS TEXT)"),
            ("subagent_messages", "subagent", "session_id", "json_array(ROW.subagent_session_id,ROW.seq)"),
            ("session_queue", "queue", "session_id", "'queue'"),
            ("session_forks", "fork", "target_session_id", "'fork'"),
            ("sessions", "metadata", "id", "'session'")
        ]
        for (table, kind, sessionColumn, key) in tables {
            for action in ["INSERT", "UPDATE", "DELETE"] {
                if table == "sessions", action == "DELETE" { continue }
                let row = action == "DELETE" ? "OLD" : "NEW"
                let itemKey = key.replacingOccurrences(of: "ROW", with: row)
                var predicate = "EXISTS(SELECT 1 FROM session_replica_exports WHERE session_id=\(row).\(sessionColumn)) AND EXISTS(SELECT 1 FROM sessions WHERE id=\(row).\(sessionColumn))"
                if table == "sessions", action == "UPDATE" {
                    let columns = ["title", "title_source", "origin", "context_recovery_pending", "mcp_preamble_pending", "mcp_preamble_sent", "auth_status", "current_model", "current_mode", "config_option_values", "native_subagents_disabled", "prompt_suggestions", "auto_run", "updated_at", "ephemeral_parent_id"]
                    predicate += " AND (" + columns.map { "NEW.\($0) IS NOT OLD.\($0)" }.joined(separator: " OR ") + ")"
                }
                let oldKey = key.replacingOccurrences(of: "ROW.", with: "OLD.")
                let movedKey = action == "UPDATE" && (table == "messages" || table == "subagent_messages") ? """
                    INSERT INTO session_replica_dirty(session_id,kind,item_key,serial)
                    SELECT OLD.\(sessionColumn),'\(kind)',\(oldKey),(SELECT serial FROM session_replica_serial)
                    WHERE \(oldKey) IS NOT \(itemKey)
                    ON CONFLICT(session_id,kind,item_key) DO UPDATE SET serial=excluded.serial;
                """ : ""
                let clearResolvedRelation: String
                if table == "session_forks" {
                    clearResolvedRelation = "DELETE FROM session_replica_relations WHERE session_id=\(row).target_session_id AND relation_key='fork';"
                } else if table == "sessions", action == "UPDATE" {
                    clearResolvedRelation = "DELETE FROM session_replica_relations WHERE session_id=NEW.id AND relation_key='ephemeralParent' AND NEW.ephemeral_parent_id IS NOT OLD.ephemeral_parent_id;"
                } else if table == "messages" || table == "subagent_messages" {
                    let prefix = kind + ":"
                    if action == "DELETE" {
                        clearResolvedRelation = "DELETE FROM session_replica_relations WHERE session_id=OLD.session_id AND relation_key='\(prefix)'||\(itemKey);"
                    } else if action == "UPDATE" {
                        clearResolvedRelation = "UPDATE OR REPLACE session_replica_relations SET relation_key='\(prefix)'||\(itemKey) WHERE session_id=NEW.session_id AND relation_key='\(prefix)'||\(oldKey) AND \(oldKey) IS NOT \(itemKey);"
                    } else { clearResolvedRelation = "" }
                } else { clearResolvedRelation = "" }
                try db.exec("""
                CREATE TRIGGER IF NOT EXISTS replica_\(table)_\(action.lowercased()) AFTER \(action) ON \(table)
                WHEN \(predicate)
                BEGIN
                    UPDATE session_replica_serial SET serial=serial+1;
                    INSERT INTO session_replica_dirty(session_id,kind,item_key,serial)
                    VALUES(\(row).\(sessionColumn),'\(kind)',\(itemKey),(SELECT serial FROM session_replica_serial))
                    ON CONFLICT(session_id,kind,item_key) DO UPDATE SET serial=excluded.serial;
                    \(movedKey)
                    \(clearResolvedRelation)
                END
                """)
            }
        }
    }

    private func markReplicaDirty(sessionId: String, kind: String, key: String) throws {
        try db.exec("UPDATE session_replica_serial SET serial=serial+1")
        try db.exec("INSERT INTO session_replica_dirty(session_id,kind,item_key,serial) VALUES(?,?,?,(SELECT serial FROM session_replica_serial)) ON CONFLICT(session_id,kind,item_key) DO UPDATE SET serial=excluded.serial", bindings: [sessionId, kind, key])
    }

    func enableReplicaExport(sessionId: String, recordId: String, localFence: ACPSessionLeaseFence? = nil) throws {
        try db.exec("BEGIN IMMEDIATE")
        do {
            if let localFence {
                let lease = try loadLease(sessionId: sessionId)
                guard localFence.sessionId == sessionId, lease?.ownerInstance == localFence.ownerInstance,
                      lease?.token == localFence.token else { throw ACPSessionReplicaError.localWriterActive }
            }
            let tracked = try db.query("SELECT record_id FROM session_replica_exports WHERE session_id=?", bindings: [sessionId]).first?["record_id"] as? String
            if tracked == recordId { try db.exec("COMMIT")
            return }
            try db.exec("INSERT INTO session_replica_links(session_id,record_id) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET record_id=excluded.record_id", bindings: [sessionId, recordId])
            try db.exec("INSERT INTO session_replica_exports(session_id,record_id) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET record_id=excluded.record_id", bindings: [sessionId, recordId])
            for row in try db.query("SELECT CAST(seq AS TEXT) AS item_key FROM messages WHERE session_id=?", bindings: [sessionId]) {
                guard let key = row["item_key"] as? String else { throw ACPSessionReplicaError.invalidPage }
                try markReplicaDirty(sessionId: sessionId, kind: "message", key: key)
            }
            for row in try db.query("SELECT json_array(subagent_session_id,seq) AS item_key FROM subagent_messages WHERE session_id=?", bindings: [sessionId]) {
                guard let key = row["item_key"] as? String else { throw ACPSessionReplicaError.invalidPage }
                try markReplicaDirty(sessionId: sessionId, kind: "subagent", key: key)
            }
            for (kind, key) in [("metadata", "session"), ("queue", "queue"), ("fork", "fork")] {
                try markReplicaDirty(sessionId: sessionId, kind: kind, key: key)
            }
            try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK")
        throw error }
    }

    func disableReplicaExport(sessionId: String) throws {
        try db.exec("DELETE FROM session_replica_exports WHERE session_id=?", bindings: [sessionId])
    }

    private func reference(sessionId: String) throws -> ReplicaReference? {
        guard let row = try loadSession(id: sessionId) else { return nil }
        let link = try db.query("SELECT record_id FROM session_replica_links WHERE session_id=?", bindings: [sessionId]).first?["record_id"] as? String
        guard link != nil || row.remoteSessionId != nil else { return nil }
        return ReplicaReference(recordId: link, agentId: row.agentId, remoteSessionId: row.remoteSessionId)
    }

    private func localReference(_ reference: ReplicaReference) throws -> String? {
        if let remote = reference.remoteSessionId, let row = try loadSession(agentId: reference.agentId, remoteSessionId: remote) { return row.id }
        if let record = reference.recordId {
            return try db.query("SELECT session_id FROM session_replica_links WHERE record_id=? LIMIT 1", bindings: [record]).first?["session_id"] as? String
        }
        return nil
    }

    private func delegatedReference(payload: Data, sessionId: String, relationKey: String) throws -> ReplicaReference? {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let source = object["delegatedSource"] as? [String: Any], let id = source["sessionId"] as? String else { return nil }
        return try sourceReference(sourceId: id, sessionId: sessionId, relationKey: relationKey)
    }

    private func sourceMarker(_ reference: ReplicaReference) -> String {
        "remote:" + (reference.recordId ?? reference.remoteSessionId ?? reference.agentId)
    }

    private func sourceReference(sourceId: String, sessionId: String, relationKey: String) throws -> ReplicaReference? {
        if let reference = try reference(sessionId: sourceId) { return reference }
        guard let payload = try db.query("SELECT payload FROM session_replica_relations WHERE session_id=? AND relation_key=?", bindings: [sessionId, relationKey]).first?["payload"] as? Data else { return nil }
        let reference = try JSONDecoder().decode(ReplicaReference.self, from: payload)
        return sourceId == sourceMarker(reference) ? reference : nil
    }

    private func rememberUnresolvedSource(_ reference: ReplicaReference?, sessionId: String, relationKey: String) throws {
        try db.exec("DELETE FROM session_replica_relations WHERE session_id=? AND relation_key=?", bindings: [sessionId, relationKey])
        guard let reference, try localReference(reference) == nil else { return }
        try db.exec("INSERT INTO session_replica_relations(session_id,relation_key,payload) VALUES(?,?,?)",
            bindings: [sessionId, relationKey, try JSONEncoder().encode(reference)])
    }

    private func replicaMessageAddress(kind: String, key: String, sessionId: String) throws -> (table: String, predicate: String, bindings: [Any?]) {
        if kind == "message" { return ("messages", "session_id=? AND seq=?", [sessionId, Int64(key)]) }
        guard let parts = try JSONSerialization.jsonObject(with: Data(key.utf8)) as? [Any], parts.count == 2,
              let child = parts[0] as? String, let seq = parts[1] as? NSNumber else { throw ACPSessionReplicaError.invalidPage }
        return ("subagent_messages", "session_id=? AND subagent_session_id=? AND seq=?", [sessionId, child, seq.int64Value])
    }

    private func unresolvedReplicaRelation(sessionId: String, key: String) throws -> Data? {
        guard let payload = try db.query("SELECT payload FROM session_replica_relations WHERE session_id=? AND relation_key=?", bindings: [sessionId, key]).first?["payload"] as? Data else { return nil }
        let decoder = JSONDecoder()
        let reference = try key == "fork" ? decoder.decode(ReplicaFork.self, from: payload).source : decoder.decode(ReplicaReference.self, from: payload)
        return try localReference(reference) == nil ? payload : nil
    }

    private func portableMessagePayload(_ payload: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var source = object["delegatedSource"] as? [String: Any] else { return payload }
        source["sessionId"] = ""
        object["delegatedSource"] = source
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func replicaChanges(sessionId: String, limit: Int) throws -> ACPSessionReplicaExport? {
        try db.transaction {
            let dirty = try db.query("SELECT d.* FROM session_replica_dirty d JOIN session_replica_exports e ON e.session_id=d.session_id WHERE d.session_id=? ORDER BY d.serial LIMIT ?", bindings: [sessionId, limit])
            guard !dirty.isEmpty else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var entries: [RemoteSessionReplicaEntry] = []
            var receipts: [ACPSessionReplicaExport.Receipt] = []
            for row in dirty {
                guard let kindString = row["kind"] as? String, let kind = RemoteSessionReplicaEntry.Kind(rawValue: kindString), let key = row["item_key"] as? String, let serial = row["serial"] as? Int64 else { throw ACPSessionReplicaError.invalidPage }
                let payload: Data?
                switch kind {
                case .metadata:
                    payload = try loadSession(id: sessionId).map { try encoder.encode(ReplicaMetadata($0)) }
                    if let parent = try loadSession(id: sessionId)?.ephemeralParentId, let ref = try reference(sessionId: parent) {
                        entries.append(.init(kind: .relationship, key: "ephemeralParent", payload: try encoder.encode(ref), revision: 0))
                    } else {
                        entries.append(.init(kind: .relationship, key: "ephemeralParent", payload: try unresolvedReplicaRelation(sessionId: sessionId, key: "ephemeralParent"), revision: 0))
                    }
                case .message:
                    let stored = try db.query("SELECT * FROM messages WHERE session_id=? AND seq=? LIMIT 1", bindings: [sessionId, Int64(key)])
                    if let r = stored.first, let content = r["payload"] as? Data {
                        payload = try encoder.encode(ReplicaMessage(kind: r["kind"] as? String ?? "", seq: r["seq"] as? Int64 ?? 0, payload: try portableMessagePayload(content), createdAt: r["created_at"] as? Int64 ?? 0, subagentSessionId: nil, delegatedReference: try delegatedReference(payload: content, sessionId: sessionId, relationKey: "message:" + key)))
                    } else { payload = nil }
                case .subagent:
                    guard let parts = try JSONSerialization.jsonObject(with: Data(key.utf8)) as? [Any], parts.count == 2, let child = parts[0] as? String, let seq = parts[1] as? NSNumber else { throw ACPSessionReplicaError.invalidPage }
                    let stored = try db.query("SELECT * FROM subagent_messages WHERE session_id=? AND subagent_session_id=? AND seq=? LIMIT 1", bindings: [sessionId, child, seq.int64Value])
                    if let r = stored.first, let content = r["payload"] as? Data {
                        payload = try encoder.encode(ReplicaMessage(kind: r["kind"] as? String ?? "", seq: seq.int64Value, payload: try portableMessagePayload(content), createdAt: r["created_at"] as? Int64 ?? 0, subagentSessionId: child, delegatedReference: try delegatedReference(payload: content, sessionId: sessionId, relationKey: "subagent:" + key)))
                    } else { payload = nil }
                case .queue:
                    var queue = try loadQueue(sessionId: sessionId)
                    for i in queue.indices { queue[i].dispatchedBrokerGeneration = nil
                    queue[i].brokerOperationAttempt = 0 }
                    guard var objects = try JSONSerialization.jsonObject(with: encoder.encode(queue)) as? [[String: Any]] else { throw ACPSessionReplicaError.invalidPage }
                    var refs: [String: ReplicaReference] = [:]
                    for i in objects.indices {
                        guard var source = objects[i]["delegatedSource"] as? [String: Any], let sourceId = source["sessionId"] as? String else { continue }
                        if let ref = try sourceReference(sourceId: sourceId, sessionId: sessionId, relationKey: "queue:" + queue[i].id.uuidString) {
                            refs[queue[i].id.uuidString] = ref
                            source["sessionId"] = ""
                            objects[i]["delegatedSource"] = source
                        } else { objects[i].removeValue(forKey: "delegatedSource") }
                    }
                    payload = try encoder.encode(ReplicaQueue(payload: JSONSerialization.data(withJSONObject: objects, options: .sortedKeys), delegatedReferences: refs))
                case .fork:
                    if let fork = try loadFork(targetSessionID: sessionId), let source = try reference(sessionId: fork.sourceSessionID) {
                        payload = try encoder.encode(ReplicaFork(source: source, sourceBoundarySequence: fork.sourceBoundarySequence, inheritedMessageCount: fork.inheritedMessageCount, phase: fork.phase, mechanism: fork.mechanism, contextDeliveryPending: fork.contextDeliveryPending, via: fork.via?.rawValue))
                    } else { payload = try unresolvedReplicaRelation(sessionId: sessionId, key: "fork") }
                case .relationship:
                    payload = nil
                }
                entries.append(.init(kind: kind, key: key, payload: payload, revision: 0))
                receipts.append(.init(kind: kindString, key: key, serial: serial))
            }
            return ACPSessionReplicaExport(batchId: UUID().uuidString, entries: entries, receipts: receipts)
        }
    }

    func acknowledgeReplicaChanges(sessionId: String, export: ACPSessionReplicaExport) throws {
        try db.transaction {
            for receipt in export.receipts {
                try db.exec("DELETE FROM session_replica_dirty WHERE session_id=? AND kind=? AND item_key=? AND serial=?", bindings: [sessionId, receipt.kind, receipt.key, receipt.serial])
            }
        }
    }

    func replicaRevision(sessionId: String, recordId: String) throws -> Int64 {
        try db.query("SELECT revision FROM session_replica_cursors WHERE session_id=? AND record_id=?", bindings: [sessionId, recordId]).first?["revision"] as? Int64 ?? 0
    }

    func stageReplicaPage(sessionId: String, recordId: String, page: RemoteSessionReadResult) throws {
        try db.transaction {
            if let read = try db.query("SELECT * FROM session_replica_reads WHERE session_id=?", bindings: [sessionId]).first {
                guard read["record_id"] as? String == recordId, read["cutoff_revision"] as? Int64 == page.cutoffRevision else { throw ACPSessionReplicaError.invalidPage }
            } else {
                let initial = try replicaRevision(sessionId: sessionId, recordId: recordId) == 0
                try db.exec("INSERT INTO session_replica_reads(session_id,record_id,cutoff_revision,initial,complete) VALUES(?,?,?,?,0)", bindings: [sessionId, recordId, page.cutoffRevision, initial ? 1 : 0])
            }
            for entry in page.entries {
                guard entry.revision <= page.cutoffRevision else { throw ACPSessionReplicaError.invalidPage }
                try db.exec("INSERT INTO session_replica_staging(session_id,record_id,kind,item_key,payload,revision,cutoff_revision) VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id,kind,item_key) DO UPDATE SET payload=excluded.payload,revision=excluded.revision", bindings: [sessionId, recordId, entry.kind.rawValue, entry.key, entry.payload, entry.revision, page.cutoffRevision])
            }
            if page.nextPageToken == nil { try db.exec("UPDATE session_replica_reads SET complete=1 WHERE session_id=?", bindings: [sessionId]) }
        }
    }

    func discardReplicaImport(sessionId: String) throws {
        try db.exec("DELETE FROM session_replica_staging WHERE session_id=?", bindings: [sessionId])
        try db.exec("DELETE FROM session_replica_reads WHERE session_id=?", bindings: [sessionId])
    }

    func commitReplicaImport(importGuard: ACPSessionReplicaImportGuard) throws -> Int64 {
        let id = importGuard.sessionId
        try db.exec("BEGIN IMMEDIATE")
        do {
            if let lease = try loadLease(sessionId: id) {
                if let expected = importGuard.expectedLocalFence {
                    guard expected.sessionId == id, lease.ownerInstance == expected.ownerInstance,
                          lease.token == expected.token else { throw ACPSessionReplicaError.localWriterActive }
                } else if ACPProcessLiveness.pidAlive(lease.pid), lease.heartbeatAt >= Int64(Date().timeIntervalSince1970) - 15 { throw ACPSessionReplicaError.localWriterActive }
            } else if importGuard.expectedLocalFence != nil { throw ACPSessionReplicaError.localWriterActive }
            guard let read = try db.query("SELECT * FROM session_replica_reads WHERE session_id=?", bindings: [id]).first, read["complete"] as? Int64 == 1,
                  let recordId = read["record_id"] as? String, let cutoff = read["cutoff_revision"] as? Int64, try loadSession(id: id) != nil else { throw ACPSessionReplicaError.invalidPage }
            guard cutoff >= (try replicaRevision(sessionId: id, recordId: recordId)) else { throw ACPSessionReplicaError.invalidPage }
            try disableReplicaExport(sessionId: id)
            try db.exec("DELETE FROM session_replica_dirty WHERE session_id=?", bindings: [id])
            if read["initial"] as? Int64 == 1 {
                for (table, column) in [("messages", "session_id"), ("subagent_messages", "session_id"), ("session_queue", "session_id"), ("session_forks", "target_session_id"), ("session_replica_relations", "session_id")] {
                    try db.exec("DELETE FROM \(table) WHERE \(column)=?", bindings: [id])
                }
            }
            let entries = try db.query("SELECT * FROM session_replica_staging WHERE session_id=? ORDER BY kind,item_key", bindings: [id])
            for entry in entries {
                guard let kind = entry["kind"] as? String, let key = entry["item_key"] as? String else { throw ACPSessionReplicaError.invalidPage }
                let payload = entry["payload"] as? Data
                try applyReplicaEntry(kind: kind, key: key, payload: payload, sessionId: id)
            }
            try db.exec("INSERT INTO session_replica_links(session_id,record_id) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET record_id=excluded.record_id", bindings: [id, recordId])
            try resolveReplicaRelations()
            try db.exec("INSERT INTO session_replica_cursors(session_id,record_id,revision) VALUES(?,?,?) ON CONFLICT(session_id) DO UPDATE SET record_id=excluded.record_id,revision=excluded.revision", bindings: [id, recordId, cutoff])
            try discardReplicaImport(sessionId: id)
            try db.exec("COMMIT")
            return cutoff
        } catch { try? db.exec("ROLLBACK")
        throw error }
    }

    private func importedMessagePayload(_ message: ReplicaMessage) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: message.payload) as? [String: Any], var source = object["delegatedSource"] as? [String: Any] else { return message.payload }
        if let ref = message.delegatedReference {
            source["sessionId"] = try localReference(ref) ?? sourceMarker(ref)
            object["delegatedSource"] = source
        } else {
            // A creator-local UUID is not a reader-local session reference.
            object.removeValue(forKey: "delegatedSource")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func applyReplicaEntry(kind: String, key: String, payload: Data?, sessionId: String) throws {
        let decoder = JSONDecoder()
        switch kind {
        case "metadata":
            guard let payload else { return }
            let m = try decoder.decode(ReplicaMetadata.self, from: payload)
            guard var row = try loadSession(id: sessionId) else { throw ACPSessionReplicaError.missingSession }
            row.title = m.title
            row.titleSource = m.titleSource
            row.origin = m.origin
            row.currentModel = m.currentModel
            row.currentMode = m.currentMode
            row.configOptionValues = m.configOptionValues
            row.promptSuggestions = m.promptSuggestions
            row.autoRun = m.autoRun
            row.updatedAt = m.updatedAt
            try upsertSession(row)
            // Replica metadata is authoritative even for fields preserved by local upserts.
            let authStatus = try m.authStatus.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try db.exec("UPDATE sessions SET context_recovery_pending=?,mcp_preamble_pending=?,mcp_preamble_sent=?,auth_status=?,native_subagents_disabled=?,created_at=? WHERE id=?", bindings: [m.contextRecoveryPending ? 1 : 0, m.mcpPreamblePending, m.mcpPreambleSent ? 1 : 0, authStatus, m.nativeSubagentsDisabled.map { $0 ? 1 : 0 }, m.createdAt, sessionId])
        case "message", "subagent":
            let relationKey = kind + ":" + key
            guard let payload else {
                try rememberUnresolvedSource(nil, sessionId: sessionId, relationKey: relationKey)
                if kind == "message" { try db.exec("DELETE FROM messages WHERE session_id=? AND seq=?", bindings: [sessionId, Int64(key)]) }
                else {
                    guard let parts = try JSONSerialization.jsonObject(with: Data(key.utf8)) as? [Any], parts.count == 2, let child = parts[0] as? String, let seq = parts[1] as? NSNumber else { throw ACPSessionReplicaError.invalidPage }
                    try db.exec("DELETE FROM subagent_messages WHERE session_id=? AND subagent_session_id=? AND seq=?", bindings: [sessionId, child, seq.int64Value])
                }
                return
            }
            let m = try decoder.decode(ReplicaMessage.self, from: payload)
            try rememberUnresolvedSource(m.delegatedReference, sessionId: sessionId, relationKey: relationKey)
            let content = try importedMessagePayload(m)
            if let child = m.subagentSessionId {
                try upsertSubagentMessages([.init(id: ACPStoredSubagentMessage.rowId(sessionId: sessionId, subagentSessionId: child, seq: m.seq), sessionId: sessionId, subagentSessionId: child, kind: m.kind, seq: m.seq, payload: content, createdAt: m.createdAt)])
            } else {
                try upsertMessages([.init(id: "msg-\(sessionId)-\(m.seq)", sessionId: sessionId, kind: m.kind, seq: m.seq, payload: content, createdAt: m.createdAt)], activityAt: m.createdAt)
            }
            let table = m.subagentSessionId == nil ? "messages" : "subagent_messages"
            let childPredicate = m.subagentSessionId == nil ? "" : " AND subagent_session_id=?"
            var bindings: [Any?] = [content, m.createdAt, sessionId, m.seq]
            if let child = m.subagentSessionId { bindings.append(child) }
            // Imported bytes are authoritative, not a local truncated-tool merge.
            try db.exec("UPDATE \(table) SET payload=?,created_at=? WHERE session_id=? AND seq=?\(childPredicate)", bindings: bindings)
        case "queue":
            try db.exec("DELETE FROM session_replica_relations WHERE session_id=? AND relation_key LIKE 'queue:%'", bindings: [sessionId])
            guard let payload else { try upsertQueue(sessionId: sessionId, items: [])
            return }
            let queue = try decoder.decode(ReplicaQueue.self, from: payload)
            guard var objects = try JSONSerialization.jsonObject(with: queue.payload) as? [[String: Any]] else { throw ACPSessionReplicaError.invalidPage }
            for i in objects.indices {
                guard let id = objects[i]["id"] as? String, let ref = queue.delegatedReferences[id],
                      var source = objects[i]["delegatedSource"] as? [String: Any] else { continue }
                try rememberUnresolvedSource(ref, sessionId: sessionId, relationKey: "queue:" + id)
                source["sessionId"] = try localReference(ref) ?? sourceMarker(ref)
                objects[i]["delegatedSource"] = source
            }
            try upsertQueue(sessionId: sessionId, items: decoder.decode([QueuedPrompt].self, from: JSONSerialization.data(withJSONObject: objects)))
        case "fork", "relationship":
            let relationKey = kind == "fork" ? "fork" : key
            if let payload {
                try db.exec("INSERT INTO session_replica_relations(session_id,relation_key,payload) VALUES(?,?,?) ON CONFLICT(session_id,relation_key) DO UPDATE SET payload=excluded.payload", bindings: [sessionId, relationKey, payload])
            } else {
                try db.exec("DELETE FROM session_replica_relations WHERE session_id=? AND relation_key=?", bindings: [sessionId, relationKey])
                if kind == "fork" { try db.exec("DELETE FROM session_forks WHERE target_session_id=?", bindings: [sessionId]) }
                if key == "ephemeralParent" { try db.exec("UPDATE sessions SET ephemeral_parent_id=NULL WHERE id=?", bindings: [sessionId]) }
            }
        default: throw ACPSessionReplicaError.invalidPage
        }
    }

    func resolveReplicaRelations() throws {
        var queuedReferences: [String: [String: (reference: ReplicaReference, localId: String)]] = [:]
        for row in try db.query("SELECT * FROM session_replica_relations") {
            guard let id = row["session_id"] as? String, let key = row["relation_key"] as? String, let payload = row["payload"] as? Data else { continue }
            if key == "fork" {
                let fork = try JSONDecoder().decode(ReplicaFork.self, from: payload)
                guard let source = try localReference(fork.source) else { continue }
                try db.exec("INSERT INTO session_forks(target_session_id,source_session_id,source_agent_id,source_boundary_seq,inherited_message_count,phase,mechanism,context_delivery_pending,via) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(target_session_id) DO UPDATE SET source_session_id=excluded.source_session_id,source_agent_id=excluded.source_agent_id,source_boundary_seq=excluded.source_boundary_seq,inherited_message_count=excluded.inherited_message_count,phase=excluded.phase,mechanism=excluded.mechanism,context_delivery_pending=excluded.context_delivery_pending,via=excluded.via", bindings: [id, source, fork.source.agentId, fork.sourceBoundarySequence, fork.inheritedMessageCount, fork.phase.rawValue, fork.mechanism?.rawValue, fork.contextDeliveryPending ? 1 : 0, fork.via])
            } else if key == "ephemeralParent" {
                let reference = try JSONDecoder().decode(ReplicaReference.self, from: payload)
                if let parent = try localReference(reference) { try db.exec("UPDATE sessions SET ephemeral_parent_id=? WHERE id=?", bindings: [parent, id]) }
            } else if key.hasPrefix("message:") || key.hasPrefix("subagent:") {
                let reference = try JSONDecoder().decode(ReplicaReference.self, from: payload)
                guard let localId = try localReference(reference) else { continue }
                let separator = key.firstIndex(of: ":")!
                let address = try replicaMessageAddress(kind: String(key[..<separator]), key: String(key[key.index(after: separator)...]), sessionId: id)
                guard let content = try db.query("SELECT payload FROM \(address.table) WHERE \(address.predicate)", bindings: address.bindings).first?["payload"] as? Data,
                      var object = try JSONSerialization.jsonObject(with: content) as? [String: Any],
                      var source = object["delegatedSource"] as? [String: Any],
                      source["sessionId"] as? String == sourceMarker(reference) else { continue }
                source["sessionId"] = localId
                object["delegatedSource"] = source
                try db.exec("UPDATE \(address.table) SET payload=? WHERE \(address.predicate)",
                    bindings: [try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)] + address.bindings)
            } else if key.hasPrefix("queue:") {
                let reference = try JSONDecoder().decode(ReplicaReference.self, from: payload)
                guard let localId = try localReference(reference) else { continue }
                queuedReferences[id, default: [:]][String(key.dropFirst(6))] = (reference, localId)
            }
        }
        for (sessionId, references) in queuedReferences {
            let queue = try loadQueue(sessionId: sessionId)
            guard var objects = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [[String: Any]] else { throw ACPSessionReplicaError.invalidPage }
            var changed = false
            for i in objects.indices {
                guard let id = objects[i]["id"] as? String, let mapping = references[id],
                      var source = objects[i]["delegatedSource"] as? [String: Any],
                      source["sessionId"] as? String == sourceMarker(mapping.reference) else { continue }
                source["sessionId"] = mapping.localId
                objects[i]["delegatedSource"] = source
                changed = true
            }
            if changed {
                try upsertQueue(sessionId: sessionId, items: JSONDecoder().decode([QueuedPrompt].self, from: JSONSerialization.data(withJSONObject: objects)))
            }
        }
    }
}
