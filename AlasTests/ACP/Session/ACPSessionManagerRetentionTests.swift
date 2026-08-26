import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager idle eviction")
struct ACPSessionManagerRetentionTests {
    private func makeManager() -> ACPSessionManager {
        let path = NSTemporaryDirectory() + "retain-\(UUID()).sqlite"
        let store = try! ACPSessionStore(path: path)
        return ACPSessionManager(worktreeId: "w1", worktreePath: "/tmp", store: store)
    }

    @Test("placeholderSession increments refcount; release evicts on zero")
    func evictOnZero() {
        let mgr = makeManager()
        let created = mgr.createSession(agentId: "claude")
        let id = created.id
        mgr.retainSession(id: id)
        #expect(mgr.sessions[id] != nil)
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] == nil)
    }

    @Test("multiple retains require matching releases")
    func balancedReleases() {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        let id = s.id
        mgr.retainSession(id: id)
        mgr.retainSession(id: id)
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] != nil)
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] == nil)
    }

    @Test("retain on a deleted session id is a no-op")
    func retainUnknownIsNoOp() {
        let mgr = makeManager()
        mgr.retainSession(id: "does-not-exist")
        #expect(mgr.sessions["does-not-exist"] == nil)
    }

    @Test("attached sessions are NOT evicted on zero refcount")
    func attachedSticky() {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        s.agentState = .ready
        let id = s.id
        mgr.retainSession(id: id)
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] != nil)
    }

    @Test("onSessionEnded fires on deleteSession but not closeSession")
    func onSessionEndedFiresOnDeleteOnly() async throws {
        let path = NSTemporaryDirectory() + "ended-\(UUID()).sqlite"
        let store = try! ACPSessionStore(path: path)
        var ended: [ACPSession.ID] = []
        let mgr = ACPSessionManager(
            worktreeId: "w1", worktreePath: "/tmp", store: store,
            onSessionEnded: { ended.append($0) })
        let closed = mgr.createSession(agentId: "claude").id
        mgr.closeSession(id: closed)
        #expect(ended.isEmpty)
        let deleted = mgr.createSession(agentId: "claude").id
        try await mgr.deleteSession(id: deleted)
        #expect(ended == [deleted])
    }

    @Test("closeSession overrides retention and tears down")
    func closeOverrides() {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        let id = s.id
        mgr.retainSession(id: id)
        mgr.retainSession(id: id)
        mgr.closeSession(id: id)
        #expect(mgr.sessions[id] == nil)
    }

    @Test("detach evicts a session whose refcount already hit zero while attached")
    func detachEvictsAfterAsyncRelease() async {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        let id = s.id
        s.agentState = .ready
        mgr.retainSession(id: id)
        // Simulate SwiftUI's .onDisappear firing before AppState's async
        // cleanupACPSession got around to invoking detach: refcount drops
        // to zero while agentState is still .ready, so eviction is skipped.
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] != nil)
        // Now the async detach completes: agentState flips out of .ready
        // and the session must finally evict because refcount is zero.
        await mgr.detach(sessionId: id)
        #expect(mgr.sessions[id] == nil)
    }

    @Test("evicting a session flushes its pending composer draft")
    func evictionFlushesDraft() async throws {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        let id = s.id
        let draft = ACPComposerDraft(segments: [.text("unsaved tail")])
        // Persist via the debounced path so the 300ms timer is in flight.
        // Without the flush-before-evict, the eviction below races the timer.
        mgr.persistComposerDraft(draft, for: s)
        mgr.retainSession(id: id)
        mgr.releaseSession(id: id)
        // Session is idle by default; release should trigger eviction.
        #expect(mgr.sessions[id] == nil)
        // The store must contain the draft — flushPendingDraftWrite was
        // called inline by evictIfIdle.
        await mgr.flushPersistence()
        let loaded = try await mgr.persistence.loadComposerDraftRecord(sessionId: id)?.draft
        #expect(loaded == draft)
    }

    @Test("reopening before an evicted draft commits keeps the flushed draft")
    func reopenBeforeEvictedDraftCommitUsesHandoff() async throws {
        let mgr = makeManager()
        let s = mgr.createSession(agentId: "claude")
        let id = s.id
        await mgr.flushPersistence()

        let draft = ACPComposerDraft(segments: [.text("restore immediately")])
        mgr.persistComposerDraft(draft, for: s)
        mgr.retainSession(id: id)
        mgr.releaseSession(id: id)
        #expect(mgr.sessions[id] == nil)

        let reopened = try #require(mgr.placeholderSession(id: id))
        #expect(reopened.composerDraft == draft)

        await mgr.hydrateIfNeeded(id: id)
        #expect(reopened.composerDraft == draft)

        await mgr.flushPersistence()
        let loaded = try await mgr.persistence.loadComposerDraftRecord(sessionId: id)?.draft
        #expect(loaded == draft)
    }
}
