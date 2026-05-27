import Foundation
import Testing
@testable import Alas

@Suite("SQLiteDatabase")
struct SQLiteDatabaseTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acp-sqlite-\(UUID()).sqlite")
    }

    @Test("opens, runs DDL, inserts, queries")
    func roundtrip() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try db.exec("INSERT INTO t (name) VALUES (?)", bindings: ["alice"])
        try db.exec("INSERT INTO t (name) VALUES (?)", bindings: ["bob"])
        let rows = try db.query("SELECT id, name FROM t ORDER BY id")
        #expect(rows.count == 2)
        #expect(rows[0]["name"] as? String == "alice")
        #expect(rows[1]["id"] as? Int64 == 2)
    }

    @Test("binds NULL, Int, Double, String, Data")
    func bindings() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t (a INTEGER, b REAL, c TEXT, d BLOB, e INTEGER)")
        try db.exec("INSERT INTO t VALUES (?, ?, ?, ?, ?)", bindings: [
            42, 3.14, "hi", Data([0x01, 0x02]), nil
        ])
        let rows = try db.query("SELECT * FROM t")
        #expect(rows[0]["a"] as? Int64 == 42)
        #expect(rows[0]["b"] as? Double == 3.14)
        #expect(rows[0]["c"] as? String == "hi")
        #expect((rows[0]["d"] as? Data) == Data([0x01, 0x02]))
        #expect(rows[0]["e"] == nil)
    }
}
