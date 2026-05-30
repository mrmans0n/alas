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
        #expect(!s.restoredFromPersistence)
        let row = try store.loadSession(id: s.id)
        #expect(row?.agentId == "claude")
    }

    @Test("placeholderSession marks store-backed sessions as restored from persistence")
    func placeholderSessionMarksRestoredFromPersistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-restored-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "stored",
            agentId: "claude",
            title: "Stored",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)

        let session = try #require(mgr.placeholderSession(id: "stored"))
        let cached = try #require(mgr.placeholderSession(id: "stored"))

        #expect(session.restoredFromPersistence)
        #expect(cached === session)
        #expect(cached.restoredFromPersistence)
    }

    @Test("attach freshness uses persisted origin and remote id")
    func attachFreshnessUsesPersistedOriginAndRemoteId() {
        #expect(ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: false,
            remoteSessionId: nil
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: false,
            remoteSessionId: "remote"
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: true,
            remoteSessionId: nil
        ))
        #expect(!ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: true,
            remoteSessionId: "remote"
        ))
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
        let session = try #require(mgr.placeholderSession(id: "s"))
        await mgr.hydrateIfNeeded(id: "s")
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
        mgr.flushPendingDraftWrites()
        #expect(try store.loadComposerDraft(sessionId: session.id) == draft)

        mgr.persistComposerDraft(.empty, for: session)
        #expect(session.composerDraft == .empty)
        #expect(session.composerDraftRevision == 2)
        mgr.flushPendingDraftWrites()
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

    @Test("suspendComposerDraftForSubmission empties memory and durably saves SQLite")
    func suspendComposerDraftForSubmissionFlushesAndClears() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-suspend-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        // Schedule a debounced write but DO NOT flush — simulates the
        // common path where the user types and immediately submits before
        // the 300ms timer fires.
        mgr.persistComposerDraft(submitted, for: session)

        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        #expect(session.composerDraft == .empty)
        #expect(session.composerDraftRevision == suspendedRevision)
        // SQLite was written synchronously by suspend, no flush needed.
        #expect(try store.loadComposerDraft(sessionId: session.id) == submitted)
    }

    @Test("purgeSuspendedComposerDraft deletes SQLite only when revision matches")
    func purgeSuspendedComposerDraftRespectsRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-purge-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        mgr.persistComposerDraft(submitted, for: session)
        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)

        // Success path with no intervening typing: SQLite row is purged.
        mgr.purgeSuspendedComposerDraft(for: session, suspendedRevision: suspendedRevision)
        #expect(try store.loadComposerDraft(sessionId: session.id) == nil)

        // Re-suspend, then simulate the user typing while the prompt is
        // in flight: the new draft must survive a late completion's purge.
        mgr.persistComposerDraft(submitted, for: session)
        let suspendedAgain = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        let newer = ACPComposerDraft(segments: [.text("newer")])
        mgr.persistComposerDraft(newer, for: session)
        mgr.purgeSuspendedComposerDraft(for: session, suspendedRevision: suspendedAgain)
        #expect(session.composerDraft == newer)
        mgr.flushPendingDraftWrites()
        #expect(try store.loadComposerDraft(sessionId: session.id) == newer)
    }

    @Test("reinstateSuspendedComposerDraft restores memory only when revision matches")
    func reinstateSuspendedComposerDraftRespectsRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-reinstate-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("sent")])

        // Failure with no intervening typing: in-memory draft is restored
        // so a still-mounted composer (or next re-mount) shows the text.
        mgr.persistComposerDraft(submitted, for: session)
        let suspendedRevision = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        mgr.reinstateSuspendedComposerDraft(submitted, for: session, suspendedRevision: suspendedRevision)
        #expect(session.composerDraft == submitted)

        // Re-suspend, then simulate the user typing a new draft while the
        // prompt is in flight — a late failure must not stomp it.
        let suspendedAgain = mgr.suspendComposerDraftForSubmission(submitted, for: session)
        let newer = ACPComposerDraft(segments: [.text("newer")])
        mgr.persistComposerDraft(newer, for: session)
        mgr.reinstateSuspendedComposerDraft(submitted, for: session, suspendedRevision: suspendedAgain)
        #expect(session.composerDraft == newer)
    }

    @Test("re-mounting the composer after submit reads an empty initial draft")
    func remountAfterSubmitSeesEmptyDraft() async throws {
        // Regression for #353 follow-up: the second commit of #353 deferred
        // the in-memory draft clear to onPromptFinished. While the agent's
        // prompt RPC is in flight, a worktree switch dismantles the ACP
        // composer; re-mounting reads `session.composerDraft`, which was
        // never cleared, and the sent text reappears in the input. The new
        // suspend hook clears in-memory eagerly so a fresh coordinator
        // sees an empty initial draft.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-draft-remount-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        let submitted = ACPComposerDraft(segments: [.text("hello")])

        mgr.persistComposerDraft(submitted, for: session)
        _ = mgr.suspendComposerDraftForSubmission(submitted, for: session)

        // What `ACPInputField.makeCoordinator()` reads as `initialDraft`.
        #expect(session.composerDraft.isEmpty)
        // …while the persisted row is still durable for crash recovery
        // until the prompt is recorded and the completion fires.
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
