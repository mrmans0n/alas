import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager hydration")
struct ACPSessionManagerHydrationTests {
    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-hydration-\(UUID()).sqlite").path
    }

    @Test("placeholderSession returns .loading session synchronously")
    func placeholderSync() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))

        #expect(s.hydrationState == .loading)
        #expect(s.transcript.messages.isEmpty)
        #expect(mgr.sessions["s"] === s)
    }

    @Test("placeholderSession returns nil for unknown session")
    func placeholderNil() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        #expect(mgr.placeholderSession(id: "ghost") == nil)
    }

    @Test("placeholderSession is idempotent for cached sessions")
    func placeholderCached() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let created = mgr.createSession(agentId: "claude")
        let again = try #require(mgr.placeholderSession(id: created.id))
        #expect(again === created)
        #expect(again.hydrationState == .ready) // created sessions start ready
    }

    @Test("hydrateIfNeeded flips state to .ready and populates transcript")
    func hydrateReady() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let userMsg: ACPMessage = .user(id: UUID(), text: "hi", attachments: [])
        let payload = try ACPMessageCodec.encode(userMsg)
        try store.appendMessage(sessionId: "s", id: "m0", kind: "user",
                                seq: 0, payload: payload, createdAt: 0)

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.transcript.messages.count == 1)
        if case .user(_, let text, _) = s.transcript.messages.first! {
            #expect(text == "hi")
        } else {
            #expect(Bool(false), "expected user message")
        }
    }

    @Test("hydrateIfNeeded restores persisted remote ACP session id")
    func hydrateRestoresRemoteSessionId() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "t",
            remoteSessionId: "remote-1",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        #expect(s.remoteSessionId == "remote-1")

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.remoteSessionId == "remote-1")
    }

    @Test("hydrateIfNeeded does not overwrite a newer in-memory remote ACP session id")
    func hydratePreservesNewerRemoteSessionId() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s",
            agentId: "claude",
            title: "t",
            remoteSessionId: "remote-old",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        #expect(s.remoteSessionId == "remote-old")
        s.remoteSessionId = "remote-new"

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.remoteSessionId == "remote-new")
    }

    @Test("hydrateIfNeeded short-circuits when already ready")
    func hydrateShortCircuit() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let created = mgr.createSession(agentId: "claude")
        // No await needed because state == .ready short-circuits before any work.
        await mgr.hydrateIfNeeded(id: created.id)
        #expect(created.hydrationState == .ready)
    }

    @Test("hydrateIfNeeded resets transcript visibleHead to tail")
    func hydrateResetsWindow() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        // Seed 40 user messages so the tail window kicks in.
        for i in 0..<40 {
            let m: ACPMessage = .user(id: UUID(), text: "m\(i)", attachments: [])
            let payload = try ACPMessageCodec.encode(m)
            try store.appendMessage(sessionId: "s", id: "m\(i)", kind: "user",
                                    seq: Int64(i), payload: payload, createdAt: 0)
        }

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        await mgr.hydrateIfNeeded(id: "s")
        #expect(s.transcript.messages.count == 40)
        #expect(s.transcript.visibleHead == 10) // 40 - 30
    }

    @Test("concurrent hydrateIfNeeded calls coalesce")
    func hydrateCoalesce() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        _ = mgr.placeholderSession(id: "s")

        async let a: Void = mgr.hydrateIfNeeded(id: "s")
        async let b: Void = mgr.hydrateIfNeeded(id: "s")
        async let c: Void = mgr.hydrateIfNeeded(id: "s")
        _ = await (a, b, c)

        #expect(mgr.sessions["s"]?.hydrationState == .ready)
    }

    @Test("hydrateIfNeeded sets .failed for unknown id")
    func hydrateFailure() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        // Insert a row, then drop it from the store but keep a placeholder so
        // hydrate can target the cached session id and surface its failure.
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        try store.deleteSession(id: "s")

        await mgr.hydrateIfNeeded(id: "s")

        if case .failed = s.hydrationState {} else {
            #expect(Bool(false), "expected .failed hydration state")
        }
    }

    @Test("hydrateIfNeeded does not overwrite a draft typed during hydration")
    func hydratePreservesInProgressDraft() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: ACPComposerDraft(segments: [.text("old persisted")]),
            updatedAt: 1
        )

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        // Simulate the user typing into the composer before hydration lands.
        let inFlight = ACPComposerDraft(segments: [.text("user is typing")])
        s.replaceComposerDraft(inFlight)

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.composerDraft == inFlight)
    }

    @Test("hydrateIfNeeded does not restore a draft after a deliberate clear")
    func hydrateRespectsDeliberateClear() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        try store.upsertComposerDraft(
            sessionId: "s",
            draft: ACPComposerDraft(segments: [.text("old persisted")]),
            updatedAt: 1
        )

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        // User types and then deletes — composer ends up empty, but the
        // revision counter records that they touched it on purpose.
        s.replaceComposerDraft(ACPComposerDraft(segments: [.text("typed then deleted")]))
        s.replaceComposerDraft(.empty)
        #expect(s.composerDraftRevision == 2)

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.composerDraft == .empty)
    }

    @Test("hydrateIfNeeded does not overwrite a title renamed during hydration")
    func hydratePreservesInProgressTitleEdit() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "Old title",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false
        ))
        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let s = try #require(mgr.placeholderSession(id: "s"))
        // User renames via the toolbar while hydration is in flight.
        s.title = "Renamed by user"

        await mgr.hydrateIfNeeded(id: "s")

        #expect(s.hydrationState == .ready)
        #expect(s.title == "Renamed by user")
    }

    @Test("hydrateIfNeeded re-hydrates after close + reopen during in-flight hydration")
    func hydrateAfterCloseReopen() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        try store.upsertSession(.init(
            id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let m: ACPMessage = .user(id: UUID(), text: "hi", attachments: [])
        try store.appendMessage(
            sessionId: "s", id: "m0", kind: "user",
            seq: 0, payload: ACPMessageCodec.encode(m), createdAt: 0
        )

        let mgr = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let first = try #require(mgr.placeholderSession(id: "s"))
        // Kick off hydration without awaiting yet.
        async let firstHydrate: Void = mgr.hydrateIfNeeded(id: "s")
        // Simulate the user closing the tab while hydration is in flight,
        // then reopening it. The reopened session must end up `.ready`.
        mgr.closeSession(id: "s")
        let second = try #require(mgr.placeholderSession(id: "s"))
        #expect(second !== first)
        async let secondHydrate: Void = mgr.hydrateIfNeeded(id: "s")
        _ = await (firstHydrate, secondHydrate)

        #expect(second.hydrationState == .ready)
        #expect(second.transcript.messages.count == 1)
    }
}
