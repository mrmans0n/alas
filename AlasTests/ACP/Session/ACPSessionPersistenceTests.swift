import Foundation
import Testing
@testable import Alas

private actor SQLiteWriteLock {
    let path: String

    init(path: String) {
        self.path = path
    }

    func hold(for seconds: TimeInterval, didLock: @Sendable () -> Void) throws {
        let database = try SQLiteDatabase(path: path)
        try database.exec("BEGIN IMMEDIATE")
        didLock()
        Thread.sleep(forTimeInterval: seconds)
        try database.exec("ROLLBACK")
    }
}

@MainActor
@Suite("ACP session persistence")
struct ACPSessionPersistenceTests {
    @Test("SQLite lock waits do not block the main actor")
    func lockWaitRunsOffMainActor() async throws {
        let url = temporaryDatabaseURL()
        let seed = try ACPSessionStore(path: url.path)
        try seed.upsertSession(row(id: "seed"))

        let lock = SQLiteWriteLock(path: url.path)
        let (locked, continuation) = AsyncStream<Void>.makeStream()
        let lockTask = Task {
            try await lock.hold(for: 0.4) {
                continuation.yield()
                continuation.finish()
            }
        }
        var iterator = locked.makeAsyncIterator()
        _ = await iterator.next()

        let persistence = ACPSessionPersistence(path: url.path)
        let startedAt = Date()
        let writeTask = Task {
            try await persistence.upsertSession(row(id: "waiter"))
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(Date().timeIntervalSince(startedAt) < 0.2)

        try await writeTask.value
        try await lockTask.value
        #expect(try await persistence.loadSession(id: "waiter") != nil)
    }

    @Test("manager preserves parent-before-child persistence order")
    func parentSessionPrecedesDraft() async throws {
        let url = temporaryDatabaseURL()
        let persistence = ACPSessionPersistence(path: url.path)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            persistence: persistence
        )
        let session = manager.createSession(agentId: "claude")
        let draft = ACPComposerDraft(segments: [.text("ordered")])

        manager.persistComposerDraft(draft, for: session)
        manager.flushPendingDraftWrites()
        await manager.flushPersistence()

        #expect(try await persistence.loadSession(id: session.id) != nil)
        #expect(try await persistence.loadComposerDraftRecord(sessionId: session.id)?.draft == draft)
    }

    @Test("takeover fences every write from the old owner")
    func staleLeaseTokenCannotWrite() async throws {
        let url = temporaryDatabaseURL()
        let persistence = ACPSessionPersistence(path: url.path)
        try await persistence.upsertSession(row(id: "session"))
        let now = Int64(Date().timeIntervalSince1970)
        let oldLease = try #require(try await persistence.claimLease(
            sessionId: "session",
            instanceId: "old",
            pid: Int64(getpid()),
            now: now,
            staleAfter: 15,
            leaseToken: "old-token"
        ))
        let newLease = try await persistence.seizeLease(
            sessionId: "session",
            instanceId: "new",
            pid: Int64(getpid()),
            now: now + 1,
            leaseToken: "new-token"
        )

        let oldWrite = try await persistence.setContextRecoveryPending(
            sessionId: "session",
            pending: true,
            fence: fence(for: oldLease)
        )
        #expect(!oldWrite)
        #expect(try await persistence.loadSession(id: "session")?.contextRecoveryPending == false)

        let newWrite = try await persistence.setContextRecoveryPending(
            sessionId: "session",
            pending: true,
            fence: fence(for: newLease)
        )
        #expect(newWrite)
        #expect(try await persistence.loadSession(id: "session")?.contextRecoveryPending == true)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-persistence-\(UUID()).sqlite")
    }

    private func row(id: String) -> ACPSessionRow {
        let now = Int64(Date().timeIntervalSince1970)
        return ACPSessionRow(
            id: id,
            agentId: "claude",
            title: "New session",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archived: false
        )
    }

    private func fence(for lease: ACPSessionLease) -> ACPSessionLeaseFence {
        ACPSessionLeaseFence(
            sessionId: lease.sessionId,
            ownerInstance: lease.ownerInstance,
            token: lease.token
        )
    }
}
