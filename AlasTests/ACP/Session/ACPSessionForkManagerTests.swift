import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork manager")
struct ACPSessionForkManagerTests {
    @Test("createFork copies through selected boundary and leaves source unchanged")
    func createsLocalFork() async throws {
        let path = temporaryPath()
        let store = try ACPSessionStore(path: path)
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let user: ACPMessage = .user(id: UUID(), text: "one", attachments: [])
        let agent: ACPMessage = .agent(id: UUID(), StreamingText("two"))
        let later: ACPMessage = .user(id: UUID(), text: "three", attachments: [])
        for message in [user, agent, later] {
            let index = source.transcript.messages.count
            source.transcript.appendMessage(message)
            try store.appendMessage(
                sessionId: source.id,
                id: "msg-\(source.id)-\(index)",
                kind: message.kind,
                seq: Int64(index),
                payload: try ACPMessageCodec.encode(message),
                createdAt: Int64(index)
            )
        }
        let sourceBefore = try store.loadMessages(sessionId: source.id)

        let target = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: agent.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(target.agentId == "codex")
        #expect(target.title == "New session (fork)")
        #expect(target.transcript.messages.count == 2)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(try store.loadMessages(sessionId: source.id) == sourceBefore)

        let targetID = target.id
        await manager.releaseAllOwnedLeases()
        let restoredStore = try ACPSessionStore(path: path)
        let restoredManager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: restoredStore
        )
        let restored = try #require(restoredManager.placeholderSession(id: targetID))
        await restoredManager.hydrateIfNeeded(id: targetID)
        await restoredManager.awaitBackfill(id: targetID)

        #expect(restored.forkRecord?.mechanism == .transcriptTransfer)
        #expect(restored.forkRecord?.contextDeliveryPending == true)
        #expect(restored.transcript.messages.count == 2)
    }

    @Test("pending transcript context prevents a native child fork")
    func pendingTranscriptContextForcesTranscriptTransfer() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let root = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Root answer"))
        root.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: root.id,
            id: "msg-\(root.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )

        let pendingSource = try await manager.createFork(
            sourceSessionID: root.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )
        pendingSource.remoteSessionId = "remote-pending-source"
        pendingSource.sessionCapabilities = .init(fork: .init())
        let pendingBoundary = try #require(pendingSource.transcript.messages.last)

        let target = try await manager.createFork(
            sourceSessionID: pendingSource.id,
            boundary: .init(stableID: pendingBoundary.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(pendingSource.forkRecord?.mechanism == .transcriptTransfer)
        #expect(pendingSource.forkRecord?.contextDeliveryPending == true)
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
    }

    @Test("createFork releases a lease acquired only for a successful snapshot")
    func successfulSnapshotReleasesTemporaryLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )

        _ = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(try store.loadLease(sessionId: source.id) == nil)
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("createFork releases a temporary snapshot lease after an error")
    func failedSnapshotReleasesTemporaryLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()

        await #expect(throws: ACPSessionForkSnapshotError.self) {
            try await manager.createFork(
                sourceSessionID: source.id,
                boundary: .init(stableID: "missing", kind: .agent),
                targetAgentID: "codex",
                autoRunDefault: false
            )
        }

        #expect(try store.loadLease(sessionId: source.id) == nil)
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("createFork preserves a source lease that was already owned")
    func successfulSnapshotPreservesExistingLease() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )
        #expect(await manager.acquireWriterLease(sessionId: source.id))

        _ = try await manager.createFork(
            sourceSessionID: source.id,
            boundary: .init(stableID: message.stableId, kind: .agent),
            targetAgentID: "codex",
            autoRunDefault: false
        )

        #expect(try store.loadLease(sessionId: source.id)?.ownerInstance == "forker")
        #expect(manager._ownedLeases.contains(source.id))
        await manager.releaseWriterLease(sessionId: source.id)
    }

    @Test("createFork rejects a cached source lease lost to takeover")
    func staleOwnedLeaseIsRejected() async throws {
        let store = try ACPSessionStore(path: temporaryPath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: "forker"
        )
        let source = manager.createSession(agentId: "claude")
        await manager.flushPersistence()
        let message: ACPMessage = .agent(id: UUID(), StreamingText("Answer"))
        source.transcript.appendMessage(message)
        try store.appendMessage(
            sessionId: source.id,
            id: "msg-\(source.id)-0",
            kind: message.kind,
            seq: 0,
            payload: try ACPMessageCodec.encode(message),
            createdAt: 0
        )
        #expect(await manager.acquireWriterLease(sessionId: source.id))
        try store.seizeLease(
            sessionId: source.id,
            instanceId: "other-instance",
            pid: Int64(getpid()),
            now: Int64(Date().timeIntervalSince1970)
        )

        await #expect(throws: ACPSessionForkCreationError.sourceReadOnly) {
            try await manager.createFork(
                sourceSessionID: source.id,
                boundary: .init(stableID: message.stableId, kind: .agent),
                targetAgentID: "codex",
                autoRunDefault: false
            )
        }

        #expect(try store.loadLease(sessionId: source.id)?.ownerInstance == "other-instance")
        #expect(!manager._ownedLeases.contains(source.id))
    }

    @Test("streaming agent is ineligible while earlier messages remain eligible")
    func messageEligibility() {
        let session = ACPSession(
            id: "s", agentId: "claude", worktreeId: "wt",
            title: "Session", hydrationState: .ready
        )
        session.transcript.appendMessage(.user(id: UUID(), text: "old", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("old answer")))
        session.transcript.appendMessage(.user(id: UUID(), text: "new", attachments: []))
        session.transcript.appendMessage(.agent(id: UUID(), StreamingText("partial")))
        session.transcript.streamingState = .streaming

        #expect(session.canForkMessage(at: 0))
        #expect(session.canForkMessage(at: 1))
        #expect(session.canForkMessage(at: 2))
        #expect(!session.canForkMessage(at: 3))
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-fork-manager-\(UUID()).sqlite").path
    }
}
