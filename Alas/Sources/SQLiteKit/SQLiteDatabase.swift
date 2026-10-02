import Foundation
import SQLite3

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var replicaChangeObservers: [UUID: @Sendable () -> Void] = [:]

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
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

    /// The persistence actor serializes the next outbox read after the current
    /// SQLite operation returns. Rollbacks may wake it but cannot export rows.
    func observeReplicaChanges(id: UUID, _ observer: @escaping @Sendable () -> Void) {
        replicaChangeObservers[id] = observer
        sqlite3_update_hook(handle, { context, operation, _, table, _ in
            guard operation != SQLITE_DELETE, let context, let table else { return }
            let isReplicaChange = "session_replica_dirty".withCString { strcmp(table, $0) == 0 }
            guard isReplicaChange else { return }
            for observer in Unmanaged<SQLiteDatabase>.fromOpaque(context).takeUnretainedValue().replicaChangeObservers.values { observer() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func removeReplicaChangeObserver(id: UUID) {
        replicaChangeObservers.removeValue(forKey: id)
    }

    func exec(_ sql: String, bindings: [Any?] = []) throws {
        guard let h = handle else { return }
        let stmt = try SQLiteStatement(db: h, sql: sql)
        try stmt.bind(bindings)
        try stmt.run()
    }

    func execChanges(_ sql: String, bindings: [Any?] = []) throws -> Int32 {
        guard let h = handle else { return 0 }
        let stmt = try SQLiteStatement(db: h, sql: sql)
        try stmt.bind(bindings)
        try stmt.run()
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
}
