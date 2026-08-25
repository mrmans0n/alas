import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession agentState")
struct ACPSessionAgentStateTests {
    @Test("default state is .idle")
    func defaultIsIdle() {
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        #expect(session.agentState == .idle)
    }

    @Test("AgentState.failed equality compares reason")
    func failedEquality() {
        #expect(ACPSession.AgentState.failed("a") == ACPSession.AgentState.failed("a"))
        #expect(ACPSession.AgentState.failed("a") != ACPSession.AgentState.failed("b"))
    }

    @Test("all transitions are assignable")
    func transitionsAssignable() {
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .spawning
        #expect(session.agentState == .spawning)
        session.agentState = .ready
        #expect(session.agentState == .ready)
        session.agentState = .disconnected
        #expect(session.agentState == .disconnected)
        session.agentState = .failed("boom")
        #expect(session.agentState == .failed("boom"))
    }

    @Test("provider state is runtime-only and isolated per session")
    func providerStateIsIsolated() {
        let first = ACPSession(id: "s1", agentId: "claude", worktreeId: "wt", title: "one")
        let second = ACPSession(id: "s2", agentId: "codex", worktreeId: "wt", title: "two")
        first.providerCapabilities = .init()
        first.availableProviders = [.init(
            providerId: "claude",
            name: "Enterprise Gateway",
            supported: ["anthropic"],
            required: true,
            current: .init(apiType: "anthropic", baseUrl: "https://gateway.example")
        ), .init(
            providerId: "fallback",
            name: nil,
            supported: ["openai"],
            required: false,
            current: .init(apiType: "openai", baseUrl: "https://fallback.example")
        )]

        #expect(first.currentProviderDisplayName == nil)
        first.agentState = .ready
        #expect(first.currentProviderDisplayName == "Enterprise Gateway, fallback")
        first.agentState = .disconnected
        #expect(first.currentProviderDisplayName == nil)
        #expect(second.currentProviderDisplayName == nil)
        #expect(second.availableProviders.isEmpty)
    }

    @Test("lone required provider is hidden")
    func loneRequiredProviderIsHidden() {
        let session = ACPSession(id: "s1", agentId: "codex", worktreeId: "wt", title: "one")
        session.providerCapabilities = .init()
        session.availableProviders = [.init(
            providerId: "openai",
            supported: ["openai"],
            required: true,
            current: .init(apiType: "openai", baseUrl: "https://api.openai.com")
        )]
        session.agentState = .ready

        #expect(session.currentProviderDisplayName == nil)
    }
}

@MainActor
@Suite("ACPSessionRunner agentState transitions")
struct ACPSessionRunnerAgentStateTests {
    @Test("runner flips agentState to .disconnected when updates stream ends")
    func runnerFlipsToDisconnectedOnStreamEnd() async throws {
        // Drive the runner's `incomingUpdates` for-await loop to natural
        // end-of-stream by calling `mock.shutdown()`. The runner's exit
        // branch (not the Task-cancelled branch) should fire and set
        // `agentState = .disconnected`.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-state-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))

        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.agentState = .ready
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path
        )
        runner.start()

        await mock.shutdown()

        // Wait for the runner's MainActor.run cleanup to land.
        for _ in 0..<50 where session.agentState != .disconnected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(session.agentState == .disconnected)
    }
}

@MainActor
@Suite("ACPSessionManager attach state transitions")
struct ACPSessionManagerAttachStateTests {
    @Test("attach while .spawning is a no-op")
    func attachDoubleNoop() async throws {
        // Construct a manager + session against the real APIs. The point
        // of this test is to prove the early-return guard fires before
        // any spawn work — so the test doesn't need a working agent.
        // Pre-set agentState to .spawning and call attach; expect the
        // state to stay .spawning and no runner to be registered.
        //
        // TODO(harness): Once Task 10 lands a real test harness with
        // injectable agent specs, restore the attachSuccess and
        // attachSpawnFailure tests from the plan and remove this comment.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-attach-noop-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.agentState = .spawning

        await mgr.attach(to: session.id, freshlyCreated: true)

        #expect(session.agentState == .spawning)
        #expect(mgr.runners[session.id] == nil)
    }

    /// Stale lastError from a prior failed attempt must not leak through to
    /// the recovery banner once the user retries — the next attach clears it
    /// upfront so a successful retry doesn't show a phantom failure.
    @Test("attach clears stale lastError before spawning")
    func attachClearsStaleLastError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-attach-clear-err-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        // Bogus agentId so attach() hits the spec-missing branch (which
        // repopulates lastError with its own message — but the clear at
        // the top of attach should happen first).
        let session = mgr.createSession(agentId: "no-such-agent-\(UUID().uuidString)")
        session.lastError = "previous failure that should not leak"
        session.providerCapabilities = .init()
        session.availableProviders = [.init(
            providerId: "stale",
            supported: ["anthropic"],
            required: false,
            current: .init(apiType: "anthropic", baseUrl: "https://stale.example")
        )]
        session.agentState = .disconnected

        await mgr.attach(to: session.id, freshlyCreated: false)

        // After attach: lastError reflects THIS attempt's failure, not the
        // stale one. (The spec-missing branch doesn't set lastError, so
        // it should now be nil — only the agentState carries the failure.)
        #expect(session.lastError == nil || session.lastError?.contains("previous failure") == false)
        #expect(session.providerCapabilities == nil)
        #expect(session.availableProviders.isEmpty)
    }
}

@MainActor
@Suite("ACPSessionManager reattach")
struct ACPSessionManagerReattachTests {
    /// `.ready` is the steady state — reattach must not poke `attach()` and
    /// must leave the runner registry untouched.
    @Test("reattach while .ready is a no-op")
    func noopWhileReady() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-reattach-ready-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.agentState = .ready
        let runnersBefore = mgr.runners

        await mgr.reattach(to: session.id)

        #expect(session.agentState == .ready)
        // Runner map must be identical (no new entry, no removal).
        #expect(mgr.runners.keys == runnersBefore.keys)
    }

    /// `.spawning` means an attach is in flight — reattach must defer to it.
    @Test("reattach while .spawning is a no-op")
    func noopWhileSpawning() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-reattach-spawning-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.agentState = .spawning

        await mgr.reattach(to: session.id)

        #expect(session.agentState == .spawning)
        #expect(mgr.runners[session.id] == nil)
    }

    /// `.disconnected` should delegate to `attach()`. Without an agent
    /// harness, `attach()` bounces off the spec-missing / setup-not-ready
    /// branch and lands on `.failed(reason)` (per Task 2's failure-path
    /// behavior). Observing the transition out of `.disconnected` proves
    /// the delegation fired without needing a working agent.
    @Test("reattach while .disconnected delegates to attach")
    func reattachFromDisconnected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mgr-reattach-disc-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        // Use an agentId with no launch spec so attach takes the
        // "no ACP launch spec" branch and lands at .failed.
        let session = mgr.createSession(agentId: "no-such-agent-\(UUID().uuidString)")
        session.agentState = .disconnected

        await mgr.reattach(to: session.id)

        #expect(session.agentState != .disconnected)
    }
}
