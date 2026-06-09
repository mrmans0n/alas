import Foundation
import SQLite3

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteError.openFailed(code: rc, message: msg)
        }
        sqlite3_busy_timeout(h, 5_000)
        _ = sqlite3_exec(h, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        _ = sqlite3_exec(h, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    deinit { sqlite3_close(handle) }

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
