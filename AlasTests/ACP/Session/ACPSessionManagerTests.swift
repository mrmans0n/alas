import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager")
struct ACPSessionManagerTests {
    @Test("creating a session inserts it and persists the row")
    func create() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let s = mgr.createSession(agentId: "claude")
        #expect(mgr.sessions[s.id] != nil)
        let row = try store.loadSession(id: s.id)
        #expect(row?.agentId == "claude")
    }

    @Test("openSession restores persisted composer draft")
    func openSessionRestoresComposerDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let draft = ACPComposerDraft(segments: [.text("unsent prompt")])
        try store.upsertComposerDraft(sessionId: "s", draft: draft, updatedAt: 123)

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = try #require(mgr.openSession(id: "s"))

        #expect(session.composerDraft == draft)
    }

    @Test("persistComposerDraft stores non-empty drafts and clears empty drafts")
    func persistComposerDraftStoresAndClears() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-clear-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let draft = ACPComposerDraft(segments: [.text("keep me")])

        mgr.persistComposerDraft(draft, for: session)
        #expect(session.composerDraft == draft)
        #expect(try store.loadComposerDraft(sessionId: session.id) == draft)

        mgr.persistComposerDraft(.empty, for: session)
        #expect(session.composerDraft == .empty)
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)
    }

    @Test("clearComposerDraft removes draft from memory and store")
    func clearComposerDraft() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-clear-explicit-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        mgr.persistComposerDraft(ACPComposerDraft(segments: [.text("sent")]), for: session)

        mgr.clearComposerDraft(for: session)

        #expect(session.composerDraft == .empty)
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)
    }
}
