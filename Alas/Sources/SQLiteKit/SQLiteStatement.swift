import Foundation
import SQLite3

final class SQLiteStatement {
    private let db: OpaquePointer
    private let handle: OpaquePointer
    private let sql: String

    init(db: OpaquePointer, sql: String) throws {
        self.db = db
        self.sql = sql
        var h: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &h, nil)
        guard rc == SQLITE_OK, let handle = h else {
            throw SQLiteError.prepareFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        self.handle = handle
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [Any?]) throws {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case nil, is NSNull:        rc = sqlite3_bind_null(handle, idx)
            case let v as Int:          rc = sqlite3_bind_int64(handle, idx, Int64(v))
            case let v as Int64:        rc = sqlite3_bind_int64(handle, idx, v)
            case let v as Double:       rc = sqlite3_bind_double(handle, idx, v)
            case let v as String:       rc = sqlite3_bind_text(handle, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let v as Data:
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(handle, idx, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            default:
                rc = sqlite3_bind_text(handle, idx, String(describing: v), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if rc != SQLITE_OK {
                throw SQLiteError.bindFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), index: i + 1)
            }
        }
    }

    /// Steps until completion (for `INSERT` / `UPDATE` / DDL).
    func run() throws {
        let rc = sqlite3_step(handle)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw SQLiteError.stepFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
        }
    }

    /// Steps and yields each row as `[String: Any?]`.
    func rows() throws -> [[String: Any?]] {
        var out: [[String: Any?]] = []
        while true {
            let rc = sqlite3_step(handle)
            if rc == SQLITE_DONE { return out }
            if rc != SQLITE_ROW {
                throw SQLiteError.stepFailed(code: rc, message: String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            let count = sqlite3_column_count(handle)
            var row: [String: Any?] = [:]
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(handle, i))
                if let value = readColumn(i) {
                    row[name] = value
                }
            }
            out.append(row)
        }
    }

    private func readColumn(_ i: Int32) -> Any? {
        switch sqlite3_column_type(handle, i) {
        case SQLITE_NULL:    return nil
        case SQLITE_INTEGER: return sqlite3_column_int64(handle, i)
        case SQLITE_FLOAT:   return sqlite3_column_double(handle, i)
        case SQLITE_TEXT:    return String(cString: sqlite3_column_text(handle, i))
        case SQLITE_BLOB:
            if let ptr = sqlite3_column_blob(handle, i) {
                let len = Int(sqlite3_column_bytes(handle, i))
                return Data(bytes: ptr, count: len)
            }
            return Data()
        default: return nil
        }
    }
}
