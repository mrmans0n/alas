import Testing
import Foundation
@testable import Alas

@MainActor
@Suite("ACPSessionManager - remote accessors")
struct ACPManagerAccessorsTests {
    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-accessors-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
    }

    @Test func liveSessionReturnsCachedSession() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        #expect(mgr.liveSession(for: session.id) === session)  // exact cached instance
    }

    @Test func liveSessionReturnsNilForUnknownId() throws {
        let mgr = try makeManager()
        #expect(mgr.liveSession(for: "missing") == nil)
    }

    @Test func permissionPolicyIsNilWithoutAttachedRunner() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        // No runner attached for a freshly-created session.
        #expect(mgr.permissionPolicy(for: session.id) == nil)
        #expect(mgr.permissionPolicy(for: "missing") == nil)
    }

    @Test func sessionRowsExposesRecent() throws {
        let mgr = try makeManager()
        let session = mgr.createSession(agentId: "claude")
        #expect(mgr.sessionRows.contains { $0.id == session.id })
    }

    @Test func isWriterReflectsOwnedLeases() throws {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.isWriter(for: s.id) == false)
        mgr._ownedLeases.insert(s.id)
        #expect(mgr.isWriter(for: s.id) == true)
    }

    @Test func authoritativeWriterCheckStandsDownAfterTakeover() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-accessors-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
        let s = mgr.createSession(agentId: "claude")
        await mgr.flushPersistence()
        #expect(await mgr.acquireWriterLease(sessionId: s.id))
        #expect(mgr.isWriter(for: s.id))
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: s.id, instanceId: "other-window",
                             pid: Int64(ProcessInfo.processInfo.processIdentifier), now: now)

        var result: Bool?
        await mgr.sendPrompt(for: s.id, text: "hi", attachments: []) { result = $0 }
        #expect(result == false)
        #expect(mgr.isWriter(for: s.id) == false)
    }

    @Test func sendPromptRefusedWhenNotWriter() async throws {
        // Re-checks the lease at call time: a manager that isn't the writer must
        // refuse the remote prompt instead of enqueuing it as a mirror (closing
        // the TOCTOU window between the gateway's isWriter gate and submit).
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.isWriter(for: s.id) == false)
        var result: Bool?
        await mgr.sendPrompt(for: s.id, text: "hi", attachments: []) { result = $0 }
        #expect(result == false)   // refused synchronously
        #expect(s.queue.isEmpty)   // nothing enqueued/persisted as a mirror
    }

    @Test func setAutoRunRequiresWriter() async throws {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        await mgr.setAutoRun(for: s.id, enabled: true)
        #expect(s.autoRunEnabled == false)          // not writer → ignored
        await mgr.flushPersistence()
        #expect(await mgr.acquireWriterLease(sessionId: s.id))
        await mgr.setAutoRun(for: s.id, enabled: true)
        #expect(s.autoRunEnabled == true)
    }

    @Test func setModelOptimisticallyUpdatesAndRequiresWriter() async throws {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        await mgr.setModel(for: s.id, modelId: "opus")
        #expect(s.currentModel == nil)              // not writer → ignored
        await mgr.flushPersistence()
        #expect(await mgr.acquireWriterLease(sessionId: s.id))
        await mgr.setModel(for: s.id, modelId: "opus")
        #expect(s.currentModel == "opus")           // optimistic update even with no runner
        await mgr.setMode(for: s.id, modeId: "ask")
        #expect(s.currentMode == "ask")
    }

    @Test func sendPromptRejectsFormerWriterAfterTakeover() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-former-writer-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
        let session = mgr.createSession(agentId: "claude")
        await mgr.flushPersistence()
        #expect(await mgr.acquireWriterLease(sessionId: session.id))
        try store.seizeLease(
            sessionId: session.id,
            instanceId: "other-window",
            pid: Int64(ProcessInfo.processInfo.processIdentifier),
            now: Int64(Date().timeIntervalSince1970)
        )

        var result: Bool?
        await mgr.sendPrompt(for: session.id, text: "hi", attachments: []) { result = $0 }

        #expect(result == false)
        #expect(mgr.isWriter(for: session.id) == false)
        #expect(session.queue.isEmpty)
    }
}
