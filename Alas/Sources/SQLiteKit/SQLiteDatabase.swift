import Foundation
import SQLite3

final class SQLiteDatabase {
    private struct BusyRetryIdentity {
        let generationKey: String
        let sessionId: String?
        var requiresExistingSessionRow: Bool
        var expectedLeaseToken: String?
    }

    private enum BusyRetryReplayDecision {
        case allow
        case blocked
        case retryLater
    }

    private static let busyRetryQueue = DispatchQueue(
        label: "SQLiteDatabase.busyRetry",
        qos: .utility,
        attributes: .concurrent)
    private static let busyRetryLeaseStaleAfter: Int64 = 15

    private var handle: OpaquePointer?
    private let path: String
    private var busyRetryTimeoutMilliseconds: Int32?
    private var busyRetryOwnerInstanceId: String?
    private let busyRetryLock = NSLock()
    private var busyRetryGenerations: [String: Int] = [:]

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.openFailed(code: rc, message: msg)
        }
        sqlite3_busy_timeout(h, busyTimeoutMilliseconds)
        _ = sqlite3_exec(h, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        _ = sqlite3_exec(h, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    deinit { sqlite3_close(handle) }

    func setBusyTimeout(milliseconds: Int32) {
        guard let h = handle else { return }
        sqlite3_busy_timeout(h, milliseconds)
    }

    func setBusyRetryTimeout(milliseconds: Int32?) {
        busyRetryTimeoutMilliseconds = milliseconds
    }

    func setBusyRetryOwnerInstanceId(_ ownerInstanceId: String?) {
        busyRetryOwnerInstanceId = ownerInstanceId
    }

    func invalidateBusyRetry(generationKey: String) {
        guard busyRetryTimeoutMilliseconds != nil else { return }
        _ = bumpBusyRetryGeneration(for: generationKey)
    }

    func exec(_ sql: String, bindings: [Any?] = []) throws {
        guard let h = handle else { return }
        let stmt = try SQLiteStatement(db: h, sql: sql)
        try stmt.bind(bindings)
        do {
            try stmt.run()
            invalidatePendingBusyRetry(sql: sql, bindings: bindings)
        } catch {
            scheduleBusyRetryIfNeeded(sql: sql, bindings: bindings, error: error)
            throw error
        }
    }

    func execChanges(_ sql: String, bindings: [Any?] = [], retryOnBusy: Bool = false) throws -> Int32 {
        guard let h = handle else { return 0 }
        let stmt = try SQLiteStatement(db: h, sql: sql)
        try stmt.bind(bindings)
        do {
            try stmt.run()
            invalidatePendingBusyRetry(sql: sql, bindings: bindings)
        } catch {
            if retryOnBusy {
                scheduleBusyRetryIfNeeded(sql: sql, bindings: bindings, error: error)
            }
            throw error
        }
        return sqlite3_changes(h)
    }

    func query(_ sql: String, bindings: [Any?] = []) throws -> [[String: Any?]] {
        guard let h = handle else { return [] }
        let stmt = try SQLiteStatement(db: h, sql: sql)
        try stmt.bind(bindings)
        return try stmt.rows()
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let v = try work()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func scheduleBusyRetryIfNeeded(sql: String, bindings: [Any?], error: Error) {
        guard let timeout = busyRetryTimeoutMilliseconds,
              var identity = busyRetryIdentity(sql: sql, bindings: bindings),
              shouldScheduleBusyRetry(for: error, identity: identity)
        else { return }

        if identity.generationKey.hasPrefix("sessions.upsert:"),
           let sessionId = identity.sessionId,
           sessionRowExistsNow(sessionId: sessionId) == true {
            identity.requiresExistingSessionRow = true
        }
        if let ownerInstanceId = busyRetryOwnerInstanceId,
           let sessionId = identity.sessionId {
            identity.expectedLeaseToken = busyRetryLeaseToken(
                sessionId: sessionId,
                ownerInstanceId: ownerInstanceId
            )
        }
        if (isSessionDelete(sql) || isSessionArchiveUpdate(sql)), let sessionId = identity.sessionId {
            _ = bumpBusyRetryGeneration(for: "sessions.upsert:\(sessionId)")
        }

        let generation = bumpBusyRetryGeneration(for: identity.generationKey)
        let leaseGenerationKey = identity.sessionId.map { "session_lease:\($0)" }
        let leaseGeneration = leaseGenerationKey.flatMap { busyRetryGeneration(for: $0) } ?? 0
        let path = self.path
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000.0)
        SQLiteDatabase.busyRetryQueue.async { [weak self] in
            guard let self else { return }
            guard Date() < deadline else { return }
            guard let db = try? SQLiteDatabase(path: path, busyTimeoutMilliseconds: 0) else { return }
            while Date() < deadline {
                guard self.busyRetryGeneration(for: identity.generationKey) == generation else { return }
                if let leaseGenerationKey,
                   (self.busyRetryGeneration(for: leaseGenerationKey) ?? 0) != leaseGeneration {
                    return
                }
                switch self.busyRetryReplayDecision(for: identity, using: db) {
                case .allow:
                    break
                case .blocked:
                    return
                case .retryLater:
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                guard self.busyRetryGeneration(for: identity.generationKey) == generation else { return }
                if let leaseGenerationKey,
                   (self.busyRetryGeneration(for: leaseGenerationKey) ?? 0) != leaseGeneration {
                    return
                }
                do {
                    try db.exec(sql, bindings: bindings)
                    self.invalidatePendingBusyRetry(sql: sql, bindings: bindings)
                    return
                } catch {
                    guard self.isBusyRetryable(error) else { return }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }

    private func invalidatePendingBusyRetry(sql: String, bindings: [Any?]) {
        guard busyRetryTimeoutMilliseconds != nil,
              let identity = busyRetryIdentity(sql: sql, bindings: bindings)
        else { return }
        _ = bumpBusyRetryGeneration(for: identity.generationKey)
        if (isSessionDelete(sql) || isSessionArchiveUpdate(sql)), let sessionId = identity.sessionId {
            _ = bumpBusyRetryGeneration(for: "sessions.upsert:\(sessionId)")
        }
        if isSessionLeaseDelete(sql), let sessionId = identity.sessionId {
            _ = bumpBusyRetryGeneration(for: "session_lease:\(sessionId)")
        }
    }

    private func bumpBusyRetryGeneration(for key: String) -> Int {
        busyRetryLock.lock()
        defer { busyRetryLock.unlock() }
        let next = (busyRetryGenerations[key] ?? 0) + 1
        busyRetryGenerations[key] = next
        return next
    }

    private func busyRetryGeneration(for key: String) -> Int? {
        busyRetryLock.lock()
        defer { busyRetryLock.unlock() }
        return busyRetryGenerations[key]
    }

    private func busyRetryIdentity(sql: String, bindings: [Any?]) -> BusyRetryIdentity? {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("composer_drafts") {
            return firstStringBinding(in: bindings).map {
                BusyRetryIdentity(generationKey: "composer_drafts:\($0)", sessionId: $0,
                                  requiresExistingSessionRow: true, expectedLeaseToken: nil)
            }
        }
        if normalized.contains("session_queue") {
            return firstStringBinding(in: bindings).map {
                BusyRetryIdentity(generationKey: "session_queue:\($0)", sessionId: $0,
                                  requiresExistingSessionRow: true, expectedLeaseToken: nil)
            }
        }
        if normalized.contains("session_leases") {
            return firstStringBinding(in: bindings).map {
                BusyRetryIdentity(generationKey: "session_leases:\($0)", sessionId: $0,
                                  requiresExistingSessionRow: true, expectedLeaseToken: nil)
            }
        }
        if normalized.contains("permission_decisions") {
            guard let sessionId = stringBinding(at: 0, in: bindings),
                  let scopeKey = stringBinding(at: 1, in: bindings)
            else { return nil }
            return BusyRetryIdentity(
                generationKey: "permission_decisions:\(sessionId):\(scopeKey)",
                sessionId: sessionId,
                requiresExistingSessionRow: true,
                expectedLeaseToken: nil)
        }
        if normalized.contains("messages") {
            if normalized.hasPrefix("insert") || normalized.hasPrefix("replace") {
                guard let messageId = stringBinding(at: 0, in: bindings) else { return nil }
                return BusyRetryIdentity(
                    generationKey: "messages.insert:\(messageId)",
                    sessionId: stringBinding(at: 1, in: bindings),
                    requiresExistingSessionRow: true,
                    expectedLeaseToken: nil)
            }
            guard let messageId = lastStringBinding(in: bindings) else { return nil }
            return BusyRetryIdentity(
                generationKey: "messages.update:\(messageId)",
                sessionId: sessionId(fromMessageRowId: messageId),
                requiresExistingSessionRow: true,
                expectedLeaseToken: nil)
        }
        if normalized.contains("sessions") {
            let sessionId: String?
            let operation: String
            if normalized.hasPrefix("insert") || normalized.hasPrefix("replace") {
                sessionId = stringBinding(at: 0, in: bindings)
                operation = "upsert"
            } else {
                sessionId = whereIdStringBinding(in: bindings) ?? firstStringBinding(in: bindings)
                operation = sessionRetryOperation(for: normalized)
            }
            return sessionId.map {
                BusyRetryIdentity(generationKey: "sessions.\(operation):\($0)", sessionId: $0,
                                  requiresExistingSessionRow: false, expectedLeaseToken: nil)
            }
        }
        return nil
    }

    private func busyRetryReplayDecision(
        for identity: BusyRetryIdentity,
        using db: SQLiteDatabase
    ) -> BusyRetryReplayDecision {
        if let sessionId = identity.sessionId, identity.requiresExistingSessionRow {
            switch sessionRowExists(sessionId: sessionId, using: db) {
            case .allow:
                break
            case .blocked:
                return .blocked
            case .retryLater:
                return .retryLater
            }
        }
        guard let ownerInstanceId = busyRetryOwnerInstanceId,
              let sessionId = identity.sessionId
        else { return .allow }
        do {
            let rows = try db.query(
                "SELECT owner_instance, pid, heartbeat_at, lease_token FROM session_leases WHERE session_id = ?",
                bindings: [sessionId])
            guard let owner = rows.first?["owner_instance"] as? String else {
                return identity.expectedLeaseToken == nil ? .allow : .blocked
            }
            let pid = (rows.first?["pid"] as? Int64) ?? 0
            let heartbeatAt = (rows.first?["heartbeat_at"] as? Int64) ?? 0
            let staleCutoff = Int64(Date().timeIntervalSince1970) - Self.busyRetryLeaseStaleAfter
            guard ACPProcessLiveness.pidAlive(pid), heartbeatAt >= staleCutoff else { return .allow }
            guard owner == ownerInstanceId else { return .blocked }
            if let expectedLeaseToken = identity.expectedLeaseToken {
                return rows.first?["lease_token"] as? String == expectedLeaseToken ? .allow : .blocked
            }
            return .allow
        } catch {
            return isBusyRetryable(error) ? .retryLater : .allow
        }
    }

    private func sessionRowExistsNow(sessionId: String) -> Bool? {
        do {
            let rows = try query("SELECT 1 FROM sessions WHERE id = ? LIMIT 1", bindings: [sessionId])
            return !rows.isEmpty
        } catch {
            return nil
        }
    }

    private func busyRetryLeaseToken(sessionId: String, ownerInstanceId: String) -> String? {
        do {
            let rows = try query(
                "SELECT lease_token FROM session_leases WHERE session_id = ? AND owner_instance = ? LIMIT 1",
                bindings: [sessionId, ownerInstanceId]
            )
            guard let token = rows.first?["lease_token"] as? String, !token.isEmpty else { return nil }
            return token
        } catch {
            return nil
        }
    }

    private func sessionRowExists(
        sessionId: String,
        using db: SQLiteDatabase
    ) -> BusyRetryReplayDecision {
        do {
            let rows = try db.query("SELECT 1 FROM sessions WHERE id = ? LIMIT 1", bindings: [sessionId])
            return rows.isEmpty ? .retryLater : .allow
        } catch {
            return isBusyRetryable(error) ? .retryLater : .allow
        }
    }

    private func shouldScheduleBusyRetry(for error: Error, identity: BusyRetryIdentity) -> Bool {
        if isBusyRetryable(error) { return true }
        guard isChildForeignKeyRetryable(error, identity: identity),
              let sessionId = identity.sessionId
        else { return false }
        switch sessionRowExists(sessionId: sessionId, using: self) {
        case .retryLater:
            return true
        case .allow, .blocked:
            return false
        }
    }

    private func isChildForeignKeyRetryable(_ error: Error, identity: BusyRetryIdentity) -> Bool {
        guard let sessionId = identity.sessionId,
              !sessionId.isEmpty,
              !identity.generationKey.hasPrefix("sessions."),
              case SQLiteError.stepFailed(let code, let message, _) = error
        else { return false }
        return code == SQLITE_CONSTRAINT
            || message.localizedCaseInsensitiveContains("foreign key")
    }

    private func firstStringBinding(in bindings: [Any?]) -> String? {
        bindings.compactMap { $0 as? String }.first
    }

    private func lastStringBinding(in bindings: [Any?]) -> String? {
        bindings.compactMap { $0 as? String }.last
    }

    private func stringBinding(at index: Int, in bindings: [Any?]) -> String? {
        guard bindings.indices.contains(index) else { return nil }
        return bindings[index] as? String
    }

    private func whereIdStringBinding(in bindings: [Any?]) -> String? {
        let strings = bindings.compactMap { $0 as? String }
        guard strings.count >= 2 else { return strings.first }
        switch strings.last {
        case "manual", "generated", "placeholder":
            return strings[strings.count - 2]
        default:
            return strings.last
        }
    }

    private func sessionRetryOperation(for normalizedSQL: String) -> String {
        if normalizedSQL.hasPrefix("delete") {
            return "delete"
        }
        if normalizedSQL.contains("last_opened_at") {
            return "last_opened_at"
        }
        if normalizedSQL.contains("context_recovery_pending") {
            return "context_recovery"
        }
        if normalizedSQL.contains("remote_session_id") {
            return "remote_session"
        }
        if normalizedSQL.contains("title") || normalizedSQL.contains("title_source") {
            return "title"
        }
        return "update"
    }

    private func sessionId(fromMessageRowId messageId: String) -> String? {
        guard messageId.hasPrefix("msg-"),
              let dash = messageId.lastIndex(of: "-")
        else { return nil }
        return String(messageId.dropFirst(4).prefix(upTo: dash))
    }

    private func isSessionDelete(_ sql: String) -> Bool {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("delete") && normalized.contains("sessions")
    }

    private func isSessionArchiveUpdate(_ sql: String) -> Bool {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("update")
            && normalized.contains("sessions")
            && normalized.contains("archived")
    }

    private func isSessionLeaseDelete(_ sql: String) -> Bool {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("delete") && normalized.contains("session_leases")
    }

    private func isBusyRetryable(_ error: Error) -> Bool {
        guard case SQLiteError.stepFailed(let code, _, _) = error else { return false }
        return code == SQLITE_BUSY || code == SQLITE_LOCKED
    }
}
