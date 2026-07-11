import Foundation
import SQLite3
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

    @Test("execChanges returns affected row count")
    func execChangesReturnsAffectedRowCount() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try db.exec("INSERT INTO t (id, name) VALUES (1, 'alice')")

        let changed = try db.execChanges("UPDATE t SET name = ? WHERE id = ?", bindings: ["bob", 1])
        let missing = try db.execChanges("UPDATE t SET name = ? WHERE id = ?", bindings: ["nobody", 2])

        #expect(changed == 1)
        #expect(missing == 0)
    }

    @Test("busy timeout is configurable")
    func busyTimeoutIsConfigurable() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try writer.exec("BEGIN IMMEDIATE")
        defer { try? writer.exec("ROLLBACK") }

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 25)
        let start = Date()
        do {
            try blocked.exec("INSERT INTO t (name) VALUES ('blocked')")
            Issue.record("Expected the blocked writer to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("busy retry persists permission decisions")
    func busyRetryPersistsPermissionDecisions() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("""
        CREATE TABLE permission_decisions (
          session_id  TEXT NOT NULL,
          scope_key   TEXT NOT NULL,
          decision    TEXT NOT NULL,
          scope       TEXT NOT NULL,
          decided_at  INTEGER NOT NULL,
          PRIMARY KEY (session_id, scope_key)
        )
        """)
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try blocked.exec("""
            INSERT INTO permission_decisions (session_id, scope_key, decision, scope, decided_at)
            VALUES (?,?,?,?,?)
            ON CONFLICT(session_id, scope_key) DO UPDATE SET
                decision = excluded.decision,
                scope = excluded.scope,
                decided_at = excluded.decided_at
            """, bindings: ["session-1", "scope-key", "allow", "session", Int64(1)])
            Issue.record("Expected the blocked permission write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try writer.query("""
            SELECT decision FROM permission_decisions
            WHERE session_id = ? AND scope_key = ?
            """, bindings: ["session-1", "scope-key"])
            if rows.first?["decision"] as? String == "allow" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected permission decision to be replayed after the writer lock cleared")
    }

    @Test("busy retry waits for parent session before replaying child rows")
    func busyRetryWaitsForSessionParentBeforeChildRows() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("""
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL
        )
        """)
        try writer.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try blocked.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "draft"])
            Issue.record("Expected the blocked draft write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        try await Task.sleep(nanoseconds: 200_000_000)
        try writer.exec("INSERT INTO sessions (id, title) VALUES (?, ?)", bindings: ["session-1", "New"])

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try writer.query("""
            SELECT payload FROM composer_drafts
            WHERE session_id = ?
            """, bindings: ["session-1"])
            if rows.first?["payload"] as? String == "draft" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected child row retry to wait for and persist after the parent session exists")
    }

    @Test("foreign key retry waits for parent session before replaying child rows")
    func foreignKeyRetryWaitsForSessionParentBeforeChildRows() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(path: url.path)
        try db.exec("""
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL
        )
        """)
        try db.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        db.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try db.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "draft"])
            Issue.record("Expected the child write to hit a foreign-key failure")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_CONSTRAINT)
        } catch {
            Issue.record("Expected SQLITE_CONSTRAINT, got \(error)")
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        try db.exec("INSERT INTO sessions (id, title) VALUES (?, ?)", bindings: ["session-1", "New"])

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try db.query("""
            SELECT payload FROM composer_drafts
            WHERE session_id = ?
            """, bindings: ["session-1"])
            if rows.first?["payload"] as? String == "draft" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected child row retry to wait for and persist after the parent session exists")
    }

    @Test("busy retry does not recreate deleted sessions from queued upserts")
    func busyRetryDoesNotRecreateDeletedSessionsFromQueuedUpserts() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("""
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL
        )
        """)
        try writer.exec("INSERT INTO sessions (id, title) VALUES (?, ?)", bindings: ["session-1", "Original"])
        try writer.exec("BEGIN IMMEDIATE")
        try writer.exec("DELETE FROM sessions WHERE id = ?", bindings: ["session-1"])

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryTimeout(milliseconds: 300)
        do {
            try blocked.exec("""
            INSERT INTO sessions (id, title)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title
            """, bindings: ["session-1", "Recreated"])
            Issue.record("Expected the blocked session upsert to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("COMMIT")
        try await Task.sleep(nanoseconds: 600_000_000)
        let rows = try writer.query("SELECT title FROM sessions WHERE id = ?", bindings: ["session-1"])
        #expect(rows.isEmpty)
    }

    @Test("busy retry replays new session upserts")
    func busyRetryReplaysNewSessionUpserts() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("""
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL
        )
        """)
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try blocked.exec("""
            INSERT INTO sessions (id, title)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title
            """, bindings: ["session-1", "Created"])
            Issue.record("Expected the blocked session upsert to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try writer.query("SELECT title FROM sessions WHERE id = ?", bindings: ["session-1"])
            if rows.first?["title"] as? String == "Created" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected new session upsert to replay after the writer lock cleared")
    }

    @Test("busy retry delete intent cancels queued new session upserts")
    func busyRetryDeleteIntentCancelsQueuedNewSessionUpserts() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("""
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL
        )
        """)
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try blocked.exec("""
            INSERT INTO sessions (id, title)
            VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title
            """, bindings: ["session-1", "Created"])
            Issue.record("Expected the blocked session upsert to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }
        do {
            try blocked.exec("DELETE FROM sessions WHERE id = ?", bindings: ["session-1"])
            Issue.record("Expected the blocked session delete to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        try await Task.sleep(nanoseconds: 600_000_000)
        let rows = try writer.query("SELECT title FROM sessions WHERE id = ?", bindings: ["session-1"])
        #expect(rows.isEmpty)
    }

    @Test("owner-scoped busy retry allows writable sessions without leases")
    func ownerScopedBusyRetryAllowsWritableSessionWithoutLease() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
        try writer.exec("""
        CREATE TABLE session_leases (
          session_id TEXT PRIMARY KEY,
          owner_instance TEXT NOT NULL
        )
        """)
        try writer.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        try writer.exec("INSERT INTO sessions (id) VALUES (?)", bindings: ["session-1"])
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryOwnerInstanceId("owner-1")
        blocked.setBusyRetryTimeout(milliseconds: 300)
        do {
            try blocked.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "stale"])
            Issue.record("Expected the blocked draft write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try writer.query("SELECT payload FROM composer_drafts WHERE session_id = ?", bindings: ["session-1"])
            if rows.first?["payload"] as? String == "stale" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected owner-scoped retry to replay for a session without a lease row")
    }

    @Test("owner-scoped busy retry allows stale lease rows")
    func ownerScopedBusyRetryAllowsStaleLeaseRow() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
        try writer.exec("""
        CREATE TABLE session_leases (
          session_id TEXT PRIMARY KEY,
          owner_instance TEXT NOT NULL,
          pid INTEGER NOT NULL,
          heartbeat_at INTEGER NOT NULL
        )
        """)
        try writer.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        try writer.exec("INSERT INTO sessions (id) VALUES (?)", bindings: ["session-1"])
        try writer.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at)
        VALUES (?,?,?,?)
        """, bindings: ["session-1", "dead-owner", Int64(Int32.max) + 1, Int64(0)])
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryOwnerInstanceId("owner-1")
        blocked.setBusyRetryTimeout(milliseconds: 1_000)
        do {
            try blocked.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "draft"])
            Issue.record("Expected the blocked draft write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("ROLLBACK")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let rows = try writer.query("SELECT payload FROM composer_drafts WHERE session_id = ?", bindings: ["session-1"])
            if rows.first?["payload"] as? String == "draft" {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Expected owner-scoped retry to replay past a stale lease row")
    }

    @Test("owner-scoped busy retry is fenced by lease token")
    func ownerScopedBusyRetryIsFencedByLeaseToken() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
        try writer.exec("""
        CREATE TABLE session_leases (
          session_id TEXT PRIMARY KEY,
          owner_instance TEXT NOT NULL,
          pid INTEGER NOT NULL,
          heartbeat_at INTEGER NOT NULL,
          lease_token TEXT NOT NULL
        )
        """)
        try writer.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        try writer.exec("INSERT INTO sessions (id) VALUES (?)", bindings: ["session-1"])
        try writer.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, lease_token)
        VALUES (?,?,?,?,?)
        """, bindings: [
            "session-1",
            "owner-1",
            Int64(ProcessInfo.processInfo.processIdentifier),
            Int64(Date().timeIntervalSince1970),
            "old-token"
        ])
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryOwnerInstanceId("owner-1")
        blocked.setBusyRetryTimeout(milliseconds: 300)
        do {
            try blocked.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "stale"])
            Issue.record("Expected the blocked draft write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("""
        UPDATE session_leases
        SET lease_token = ?, heartbeat_at = ?
        WHERE session_id = ? AND owner_instance = ?
        """, bindings: [
            "new-token",
            Int64(Date().timeIntervalSince1970),
            "session-1",
            "owner-1"
        ])
        try writer.exec("COMMIT")
        try await Task.sleep(nanoseconds: 600_000_000)
        let rows = try writer.query("SELECT payload FROM composer_drafts WHERE session_id = ?", bindings: ["session-1"])
        #expect(rows.isEmpty)
    }

    @Test("owner-scoped busy retry blocks when captured lease disappears")
    func ownerScopedBusyRetryBlocksWhenCapturedLeaseDisappears() async throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SQLiteDatabase(path: url.path)
        try writer.exec("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
        try writer.exec("""
        CREATE TABLE session_leases (
          session_id TEXT PRIMARY KEY,
          owner_instance TEXT NOT NULL,
          pid INTEGER NOT NULL,
          heartbeat_at INTEGER NOT NULL,
          lease_token TEXT NOT NULL
        )
        """)
        try writer.exec("""
        CREATE TABLE composer_drafts (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          payload TEXT NOT NULL
        )
        """)
        try writer.exec("INSERT INTO sessions (id) VALUES (?)", bindings: ["session-1"])
        try writer.exec("""
        INSERT INTO session_leases (session_id, owner_instance, pid, heartbeat_at, lease_token)
        VALUES (?,?,?,?,?)
        """, bindings: [
            "session-1",
            "owner-1",
            Int64(ProcessInfo.processInfo.processIdentifier),
            Int64(Date().timeIntervalSince1970),
            "lease-token"
        ])
        try writer.exec("BEGIN IMMEDIATE")

        let blocked = try SQLiteDatabase(path: url.path, busyTimeoutMilliseconds: 0)
        blocked.setBusyRetryOwnerInstanceId("owner-1")
        blocked.setBusyRetryTimeout(milliseconds: 300)
        do {
            try blocked.exec("""
            INSERT INTO composer_drafts (session_id, payload)
            VALUES (?, ?)
            """, bindings: ["session-1", "stale"])
            Issue.record("Expected the blocked draft write to hit SQLITE_BUSY")
        } catch SQLiteError.stepFailed(let code, _, _) {
            #expect(code == SQLITE_BUSY)
        } catch {
            Issue.record("Expected SQLITE_BUSY, got \(error)")
        }

        try writer.exec("DELETE FROM session_leases WHERE session_id = ?", bindings: ["session-1"])
        try writer.exec("COMMIT")
        try await Task.sleep(nanoseconds: 600_000_000)
        let rows = try writer.query("SELECT payload FROM composer_drafts WHERE session_id = ?", bindings: ["session-1"])
        #expect(rows.isEmpty)
    }
}
