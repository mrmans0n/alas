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
        #expect(session.composerDraftRevision == 1)
        #expect(try store.loadComposerDraft(sessionId: session.id) == draft)

        mgr.persistComposerDraft(.empty, for: session)
        #expect(session.composerDraft == .empty)
        #expect(session.composerDraftRevision == 2)
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

    @Test("conditional composer draft clear only clears the submitted draft")
    func conditionalComposerDraftClear() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-conditional-clear-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])
        let newer = ACPComposerDraft(segments: [.text("newer")])

        mgr.persistComposerDraft(submitted, for: session)
        let submittedRevision = session.composerDraftRevision
        mgr.clearComposerDraft(for: session, ifCurrentDraftEquals: submitted, revision: submittedRevision)
        #expect(session.composerDraft == .empty)
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)

        mgr.persistComposerDraft(newer, for: session)
        mgr.clearComposerDraft(for: session, ifCurrentDraftEquals: submitted, revision: submittedRevision)
        #expect(session.composerDraft == newer)
        #expect(try store.loadComposerDraft(sessionId: session.id) == newer)
    }

    @Test("conditional composer draft persist does not overwrite a newer draft revision")
    func conditionalComposerDraftPersistByRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-conditional-persist-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        mgr.persistComposerDraft(submitted, for: session)
        let submittedRevision = session.composerDraftRevision
        mgr.persistComposerDraft(submitted, for: session, ifCurrentDraftEquals: submitted, revision: submittedRevision)
        #expect(session.composerDraft == submitted)
        #expect(try store.loadComposerDraft(sessionId: session.id) == submitted)

        mgr.persistComposerDraft(submitted, for: session)
        mgr.persistComposerDraft(.empty, for: session, ifCurrentDraftEquals: submitted, revision: submittedRevision)
        #expect(session.composerDraft == submitted)
        #expect(try store.loadComposerDraft(sessionId: session.id) == submitted)
    }

    @Test("detach normalizes a .sending queue head so re-attach can flush")
    func detachNormalizesSendingHead() async throws {
        // Regression: closing a tab while the flusher had promoted the
        // head to .sending used to leave the cached ACPSession with a
        // .sending head. The next openSession returns the cached object
        // (no `restoreQueue`), and the post-attach `flushQueueIfIdle`
        // sees `.sending` and no-ops — the queue is stuck until a full
        // app restart reloads from SQLite.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-detach-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.enqueue(blocks: [.text("queued")])
        session.markQueueHeadSending()
        #expect(session.queue[0].status == .sending)

        await mgr.detach(sessionId: session.id)
        #expect(session.queue[0].status == .pending)
    }

    @Test("persistQueue writes to SQLite without requiring a runner")
    func persistQueueWithoutRunner() throws {
        // Regression: ACPTabView's queue actions used to call
        // `manager.runners[sessionId]?.persistQueue()`, which silently
        // no-oped when no runner was attached (setup nudge / launch
        // failure). Edits then lived only in memory; relaunch restored
        // the supposedly-removed prompts from SQLite.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-persist-q-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.enqueue(blocks: [.text("a")])
        session.enqueue(blocks: [.text("b")])

        mgr.persistQueue(for: session)
        let persisted = try store.loadQueue(sessionId: session.id)
        #expect(persisted == session.queue)

        session.clearPendingQueue()
        mgr.persistQueue(for: session)
        let afterClear = try store.loadQueue(sessionId: session.id)
        #expect(afterClear.isEmpty)
    }
}
