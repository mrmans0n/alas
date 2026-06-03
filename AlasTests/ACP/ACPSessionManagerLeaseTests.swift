import Testing
import Foundation
@testable import Alas

@Suite @MainActor struct ACPSessionManagerLeaseTests {
    private func tempManager(instanceId: String, store: ACPSessionStore) -> ACPSessionManager {
        ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt",
                          store: store, instanceId: instanceId, pid: Int64(getpid()))
    }

    @Test("manager exposes its instanceId")
    func exposesInstanceId() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = tempManager(instanceId: "INST-A", store: store)
        #expect(mgr.instanceId == "INST-A")
        #expect(mgr.pid == Int64(getpid()))
    }

    @Test("second instance attaching the same session becomes a mirror")
    func secondInstanceMirrors() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-mirror-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")

        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)
        #expect(mgrA.isMirror(sessionId: session.id) == false)

        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == false)
        #expect(mgrB.isMirror(sessionId: session.id) == true)
    }

    @Test("releasing the lease lets another instance claim it")
    func releaseAllowsReclaim() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-release-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)
        mgrA.releaseWriterLease(sessionId: session.id)

        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == true)
    }

    @Test("mirror re-read applies appended messages from another writer")
    func mirrorReReads() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-read-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        _ = mgrA.acquireWriterLease(sessionId: session.id)

        // Writer appends a user message directly to the shared DB.
        let msg: ACPMessage = .user(id: UUID(), text: "hello from writer", attachments: [])
        let payload = try ACPMessageCodec.encode(msg)
        let now = Int64(Date().timeIntervalSince1970)
        try storeA.appendMessage(
            sessionId: session.id, id: "m0", kind: msg.kind,
            seq: 0, payload: payload, createdAt: now)

        // Mirror instance creates a placeholder then pulls the new row.
        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        let mirror = mgrB.placeholderSession(id: session.id)
        #expect(mirror != nil)
        await mgrB.refreshMirror(sessionId: session.id)
        #expect(mgrB.sessions[session.id]?.transcript.messages.isEmpty == false)
    }

    @Test("takeOver seizes a live lease and flips ownership")
    func takeOverSeizes() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeover-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        _ = mgrA.acquireWriterLease(sessionId: session.id)
        #expect(mgrA.isMirror(sessionId: session.id) == false)

        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        _ = mgrB.placeholderSession(id: session.id)
        mgrB.takeOver(sessionId: session.id)

        // The synchronous parts (seizeLease + _ownedLeases insert) must have
        // completed before takeOver returns; the async attach kicks off later.
        #expect(try storeB.loadLease(sessionId: session.id)?.ownerInstance == "B")
        #expect(mgrA.ownsLeaseForTest(sessionId: session.id) == false)
    }

    @Test("heartbeat re-asserts ownership when the lease row went missing")
    func heartbeatReassertsMissingRow() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-missing-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = tempManager(instanceId: "A", store: store)
        let session = mgr.createSession(agentId: "claude")
        #expect(mgr.acquireWriterLease(sessionId: session.id) == true)
        // Simulate a failed-takeover deleting the row out from under us.
        try store.releaseLease(sessionId: session.id, instanceId: "A")
        #expect(try store.loadLease(sessionId: session.id) == nil)
        // A heartbeat tick should re-assert our ownership, not stand down.
        let standDown = mgr.heartbeatTickForTest(sessionId: session.id)
        #expect(standDown == false)
        #expect(try store.loadLease(sessionId: session.id)?.ownerInstance == "A")
    }

    @Test("heartbeat signals stand-down when another instance owns the lease")
    func heartbeatStandsDownOnTakeover() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-takeover-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)
        // B seizes it.
        let now = Int64(Date().timeIntervalSince1970)
        try storeA.seizeLease(sessionId: session.id, instanceId: "B", pid: Int64(getpid()), now: now)
        #expect(mgrA.heartbeatTickForTest(sessionId: session.id) == true)   // A should stand down
    }

    @Test("a failed attach releases the writer lease")
    func failedAttachReleasesLease() async throws {
        struct StubError: Error {}
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-failattach-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt",
            store: storeA, instanceId: "A", pid: Int64(getpid()),
            setupEvaluator: { _ in .ready },
            connectionFactory: { _ in throw StubError() })
        let session = mgrA.createSession(agentId: "claude")
        await mgrA.attach(to: session.id, freshlyCreated: true)
        // attach failed at connectionFactory; the defer must have released the lease.
        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt",
            store: storeB, instanceId: "B", pid: Int64(getpid()))
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == true)
    }

    // MARK: - P1: Queue-write lease guard

    @Test("mirror cannot persist the queue; writer can")
    func mirrorCannotPersistQueue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-guard-\(UUID()).sqlite")
        // Writer: instance A owns the lease.
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let session = mgrA.createSession(agentId: "claude")
        #expect(mgrA.acquireWriterLease(sessionId: session.id) == true)

        // Mirror: instance B fails to acquire.
        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: session.id) == false)

        // Give mgrB a placeholder session so it has a local ACPSession to work with.
        let mirrorSession = mgrB.placeholderSession(id: session.id)
        #expect(mirrorSession != nil)

        // Populate the mirror session's in-memory queue.
        mirrorSession!.enqueue(blocks: [.text("mirror prompt")])
        #expect(mirrorSession!.queue.count == 1)

        // Mirror calls persistQueue — must be a no-op at the store level.
        mgrB.persistQueue(for: mirrorSession!)
        let storedAfterMirrorWrite = try storeB.loadQueue(sessionId: session.id)
        #expect(storedAfterMirrorWrite.isEmpty,
                "mirror must not write session_queue when it does not hold the lease")

        // Positive case: writer can persist its queue.
        session.enqueue(blocks: [.text("writer prompt")])
        mgrA.persistQueue(for: session)
        let storedAfterWriterWrite = try storeA.loadQueue(sessionId: session.id)
        #expect(storedAfterWriterWrite.count == 1,
                "writer must be able to persist the queue when it holds the lease")
    }

    // MARK: - P2: Mirror poll teardown on eviction

    @Test("endMirroring is idempotent and evictIfIdle cancels the mirror poll")
    func mirrorPollCancelledOnEvict() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evict-mirror-\(UUID()).sqlite")
        let storeA = try ACPSessionStore(path: url.path)
        let mgrA = tempManager(instanceId: "A", store: storeA)
        let sessionA = mgrA.createSession(agentId: "claude")
        #expect(mgrA.acquireWriterLease(sessionId: sessionA.id) == true)

        // Instance B mirrors the session.
        let storeB = try ACPSessionStore(path: url.path)
        let mgrB = tempManager(instanceId: "B", store: storeB)
        #expect(mgrB.acquireWriterLease(sessionId: sessionA.id) == false)
        let mirrorSession = mgrB.placeholderSession(id: sessionA.id)
        #expect(mirrorSession != nil)
        mgrB.beginMirroring(sessionId: sessionA.id)

        // Poll task is running.
        #expect(mgrB.mirrorPollActiveForTest(sessionId: sessionA.id))

        // Simulate the mirror tab closing: retain then release with refcount=1.
        mgrB.retainSession(id: sessionA.id)
        // Session is idle (no runner), so releaseSession → evictIfIdle.
        mgrB.releaseSession(id: sessionA.id)

        // After eviction the mirror poll task must be cancelled.
        #expect(!mgrB.mirrorPollActiveForTest(sessionId: sessionA.id),
                "mirror poll must be cancelled when the mirrored session is evicted")

        // Calling endMirroring again must be safe (idempotent).
        mgrB.endMirroring(sessionId: sessionA.id)
        #expect(!mgrB.mirrorPollActiveForTest(sessionId: sessionA.id))
    }
}
