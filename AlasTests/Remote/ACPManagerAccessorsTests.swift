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

    @Test func isWriterFalseWhenAnotherLiveInstanceOwnsLease() throws {
        // Regression: after another window seizes the lease, the former owner
        // keeps the id in `_ownedLeases` until its heartbeat stands down
        // (~leaseStaleAfter seconds). isWriter must consult the store and report
        // false in that window so a phone on the old owner can't keep writing
        // into a session another instance now drives.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-accessors-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: store)
        let s = mgr.createSession(agentId: "claude")
        mgr._ownedLeases.insert(s.id)
        #expect(mgr.isWriter(for: s.id) == true)   // we claim it; no conflicting store row
        // Another LIVE instance seizes the store lease (fresh heartbeat, live pid).
        let now = Int64(Date().timeIntervalSince1970)
        try store.seizeLease(sessionId: s.id, instanceId: "other-window",
                             pid: Int64(ProcessInfo.processInfo.processIdentifier), now: now)
        #expect(mgr.isWriter(for: s.id) == false)  // store says another live instance owns it
    }

    @Test func sendPromptRefusedWhenNotWriter() throws {
        // Re-checks the lease at call time: a manager that isn't the writer must
        // refuse the remote prompt instead of enqueuing it as a mirror (closing
        // the TOCTOU window between the gateway's isWriter gate and submit).
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.isWriter(for: s.id) == false)
        var result: Bool?
        mgr.sendPrompt(for: s.id, text: "hi", attachments: []) { result = $0 }
        #expect(result == false)   // refused synchronously
        #expect(s.queue.isEmpty)   // nothing enqueued/persisted as a mirror
    }

    @Test func setAutoRunRequiresWriter() throws {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        mgr.setAutoRun(for: s.id, enabled: true)
        #expect(s.autoRunEnabled == false)          // not writer → ignored
        mgr._ownedLeases.insert(s.id)
        mgr.setAutoRun(for: s.id, enabled: true)
        #expect(s.autoRunEnabled == true)
    }

    @Test func setModelOptimisticallyUpdatesAndRequiresWriter() throws {
        let mgr = try makeManager()
        let s = mgr.createSession(agentId: "claude")
        mgr.setModel(for: s.id, modelId: "opus")
        #expect(s.currentModel == nil)              // not writer → ignored
        mgr._ownedLeases.insert(s.id)
        mgr.setModel(for: s.id, modelId: "opus")
        #expect(s.currentModel == "opus")           // optimistic update even with no runner
        mgr.setMode(for: s.id, modeId: "ask")
        #expect(s.currentMode == "ask")
    }
}
