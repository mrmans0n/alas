import Foundation
import Testing
@testable import Alas

// TODO(harness): end-to-end .ready + drain coverage requires a stub ACP
// agent target — out of scope for this refactor. The full happy path
// (persist → fresh manager → attach() → session/new → .ready → queue
// drain) cannot be exercised without either a fake agent CLI on $PATH
// or a factory-injection seam in `ACPSessionManager.attach()`. The
// tests below exercise everything *up to* the actual subprocess
// handshake: persistence round-trip, hydration, the reattach state
// machine via the spec-missing branch, and queue ordering invariants.

@MainActor
@Suite("ACPSessionManager recovery round-trip")
struct ACPSessionRecoveryIntegrationTests {
    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-recover-int-\(UUID()).sqlite").path
    }

    /// Scenario 1: write a session with a transcript message and a queued
    /// item directly to SQLite, tear down the manager, spin up a fresh
    /// `ACPSessionManager` against the same store, hydrate, and verify the
    /// transcript / queue / metadata are intact. Then call `attach()` with
    /// an agentId that has no launch spec to walk the state machine
    /// (.idle → .spawning → .idle via the spec-missing branch) without
    /// losing the persisted queue.
    @Test("persistence round-trip survives manager teardown and reattach")
    func persistenceRoundTripWithReattach() async throws {
        let path = tmpStorePath()
        let sessionId = "round-trip-\(UUID().uuidString)"
        let agentId = "no-such-agent-\(UUID().uuidString)"

        // --- Phase 1: seed the store directly, then drop everything. ---
        do {
            let store = try ACPSessionStore(path: path)
            try store.upsertSession(.init(
                id: sessionId, agentId: agentId, title: "Original title",
                currentModel: "model-x", currentMode: "mode-y", autoRun: true,
                createdAt: 100, updatedAt: 200, lastOpenedAt: 300,
                archived: false))

            // Hand-rolled user message payload — same shape ACPMessageCodec
            // writes on the live path (see ACPSessionManagerHydrationTests
            // .hydrateReady for the established pattern).
            let userMsg: ACPMessage = .user(
                id: UUID(), text: "persisted hello", attachments: [])
            let payload = try ACPMessageCodec.encode(userMsg)
            try store.appendMessage(
                sessionId: sessionId, id: "m0", kind: "user",
                seq: 0, payload: payload, createdAt: 100)

            // Hand-rolled queue item — matches the QueuedPrompt shape used
            // by ACPSessionStoreQueueTests.
            let queued = QueuedPrompt(
                blocks: [.text("queued before crash")],
                status: .pending)
            try store.upsertQueue(sessionId: sessionId, items: [queued])
        }

        // --- Phase 2: fresh manager against the same on-disk store. ---
        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = try #require(mgr.placeholderSession(id: sessionId))
        // Initial agentState is .idle — no spawn has happened on the
        // fresh manager regardless of what the prior process was doing.
        #expect(session.agentState == .idle)
        #expect(session.hydrationState == .loading)

        await mgr.hydrateIfNeeded(id: sessionId)

        #expect(session.hydrationState == .ready)
        #expect(session.transcript.messages.count == 1)
        if case .user(_, _, let text, _, _) = session.transcript.messages.first! {
            #expect(text == "persisted hello")
        } else {
            Issue.record("expected hydrated transcript head to be a user message")
        }
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.blocks == [.text("queued before crash")])
        #expect(session.currentModel == "model-x")
        #expect(session.currentMode == "mode-y")
        #expect(session.autoRunEnabled == true)

        // --- Phase 3: drive attach() through the state machine. ---
        // The no-spec branch flips .idle → .spawning, then lands at
        // .failed(reason) with setupState = .needsSetup. The persisted
        // queue must survive that transition.
        await mgr.attach(to: sessionId, freshlyCreated: false)

        if case .failed = session.agentState {
            // success — attach() ran the spec-missing branch
        } else {
            Issue.record("expected agentState = .failed after spec-missing attach, got \(session.agentState)")
        }
        if case .needsSetup = session.setupState {
            // success — attach() ran the spec-missing branch
        } else {
            Issue.record("expected setupState = .needsSetup after spec-missing attach, got \(session.setupState)")
        }
        // Queue must NOT have been clobbered by the failed attach.
        #expect(session.queue.count == 1)
        let persistedAfter = try store.loadQueue(sessionId: sessionId)
        #expect(persistedAfter.count == 1)
        #expect(persistedAfter.first?.blocks == [.text("queued before crash")])
    }

    /// Scenario 2: submit-during-recovery. Start from a hydrated session
    /// at .idle, call `manager.submit(...)` with text — assert the prompt
    /// lands in `session.queue`, round-trips through SQLite, AND that the
    /// reattach-driven attempt fires (state transitions out of .idle and
    /// returns via the spec-missing branch).
    @Test("submit during recovery enqueues, persists, and triggers reattach")
    func submitDuringRecoveryRoundTrip() async throws {
        let path = tmpStorePath()
        let sessionId = "submit-recover-\(UUID().uuidString)"
        let agentId = "no-such-agent-\(UUID().uuidString)"

        // Seed an empty session row directly; no transcript, no queue.
        do {
            let store = try ACPSessionStore(path: path)
            try store.upsertSession(.init(
                id: sessionId, agentId: agentId, title: "t",
                currentModel: nil, currentMode: nil, autoRun: false,
                createdAt: 0, updatedAt: 0, lastOpenedAt: 0,
                archived: false))
        }

        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = try #require(mgr.placeholderSession(id: sessionId))
        await mgr.hydrateIfNeeded(id: sessionId)
        #expect(session.hydrationState == .ready)
        #expect(session.agentState == .idle)

        // Submit from the recovery state — the .idle branch enqueues
        // and kicks reattach.
        let accepted = mgr.submit(
            sessionId: sessionId,
            text: "submitted during recovery",
            attachments: [],
            intent: .auto
        ) { _ in }

        #expect(accepted == true)
        #expect(session.queue.count == 1)
        if case .text(let s) = session.queue.first?.blocks.first {
            #expect(s == "submitted during recovery")
        } else {
            Issue.record("expected first block to be .text, got \(String(describing: session.queue.first?.blocks.first))")
        }

        // The prompt must round-trip through SQLite — a fresh load
        // against the same path returns the same head.
        await mgr.flushPersistence()
        let persisted = try store.loadQueue(sessionId: sessionId)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == session.queue.first?.id)

        // Wait for the reattach's awaited attach() to evaluate the spec.
        // The spec-missing branch lands setupState = .needsSetup; that's
        // our observable proof that reattach actually fired.
        for _ in 0..<50 {
            if case .needsSetup = session.setupState { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if case .needsSetup = session.setupState {
            // success — submit kicked reattach, which kicked attach,
            // which walked the spec-missing branch.
        } else {
            Issue.record("submit-during-recovery did not invoke attach(): setupState=\(session.setupState)")
        }
        // The spec-missing branch records setupState = .needsSetup without
        // consuming the queued prompt.
        #expect(session.queue.count == 1)
    }

    /// Scenario 3: queue ordering invariant. Enqueue two items via
    /// `enqueueWhileRecovering` AND one via `submit` while in .spawning.
    /// Assert all three end up in `session.queue` in the order they
    /// were enqueued.
    @Test("queue preserves enqueue order across enqueueWhileRecovering and submit")
    func queueOrderingInvariant() async throws {
        let path = tmpStorePath()
        let store = try ACPSessionStore(path: path)
        let mgr = ACPSessionManager(
            worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        // createSession produces a .ready hydrationState with .idle
        // agentState; agentId is irrelevant here — we never call attach.
        let session = mgr.createSession(agentId: "claude")

        // Two items via the recovery enqueue path.
        mgr.enqueueWhileRecovering(
            text: "first", attachments: [], into: session.id)
        mgr.enqueueWhileRecovering(
            text: "second", attachments: [], into: session.id)

        // Flip to .spawning so submit takes the enqueue-only branch
        // (no reattach kick — an attach is conceptually in flight).
        session.agentState = .spawning

        let accepted = mgr.submit(
            sessionId: session.id,
            text: "third",
            attachments: [],
            intent: .auto
        ) { _ in }
        #expect(accepted == true)

        // All three in original enqueue order.
        #expect(session.queue.count == 3)
        let texts: [String] = session.queue.compactMap { item in
            if case .text(let s) = item.blocks.first { return s }
            return nil
        }
        #expect(texts == ["first", "second", "third"])

        // SQLite agrees — order survives the persistence path.
        await mgr.flushPersistence()
        let persisted = try store.loadQueue(sessionId: session.id)
        #expect(persisted.count == 3)
        let persistedTexts: [String] = persisted.compactMap { item in
            if case .text(let s) = item.blocks.first { return s }
            return nil
        }
        #expect(persistedTexts == ["first", "second", "third"])

        // Submit during .spawning must NOT trigger reattach (avoids a
        // racing second attach against the in-flight one).
        #expect(session.agentState == .spawning)
    }
}
