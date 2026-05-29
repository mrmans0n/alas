import Foundation
import Testing
@testable import Alas

// TODO(harness): drain-on-attach test deferred to Task 10 integration coverage.
// The second half of the plan (enqueue two, attach, assert the head promotes
// to .sending) needs a working end-to-end attach() path which requires a real
// agent process; covered by the recovery round-trip integration test.

@MainActor
@Suite("ACPSessionManager.enqueueWhileRecovering")
struct ACPSessionEnqueueWhileRecoveringTests {
    @Test("enqueueWhileRecovering appends to session.queue and persists")
    func enqueueAppends() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-recover-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")

        #expect(session.queue.isEmpty)

        mgr.enqueueWhileRecovering(text: "hello", attachments: [], into: session.id)

        #expect(session.queue.count == 1)
        let head = try #require(session.queue.first)
        #expect(head.status == .pending)
        // The blocks-builder mirrors ACPSessionRunner.send(text:attachments:):
        // the first block is the text payload.
        if case .text(let s) = head.blocks.first {
            #expect(s == "hello")
        } else {
            Issue.record("expected first block to be .text(\"hello\"), got \(String(describing: head.blocks.first))")
        }

        let persisted = try store.loadQueue(sessionId: session.id)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == head.id)
    }

    @Test("enqueueWhileRecovering preserves attachments as resource links")
    func enqueueWithAttachments() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-recover-att-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")

        let attachment = ACPMessage.Attachment(uri: "file:///a.txt", name: "a.txt")
        mgr.enqueueWhileRecovering(
            text: "see this", attachments: [attachment], into: session.id)

        let head = try #require(session.queue.first)
        #expect(head.blocks.count == 2)
        if case .resourceLink(let uri, let name) = head.blocks.last {
            #expect(uri == "file:///a.txt")
            #expect(name == "a.txt")
        } else {
            Issue.record("expected last block to be .resourceLink, got \(String(describing: head.blocks.last))")
        }
    }

    @Test("enqueueWhileRecovering is a no-op when the session id is unknown")
    func unknownSessionIsNoOp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-recover-noop-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)

        mgr.enqueueWhileRecovering(text: "hi", attachments: [], into: "missing-id")

        let persisted = try store.loadQueue(sessionId: "missing-id")
        #expect(persisted.isEmpty)
    }
}

// TODO(harness): the `.ready`-with-runner happy path for `submit(...)` needs a
// test harness that can stand up a fake runner and observe `runner.send`. That
// harness doesn't exist today; coverage lives in Task 10's recovery
// round-trip integration test. The cases below preset `agentState` and
// observe the queue / state transitions, which doesn't need the harness.
@MainActor
@Suite("ACPSessionManager.submit")
struct ACPSessionManagerSubmitTests {
    @Test("submit while .spawning enqueues and returns true")
    func submitWhileSpawningEnqueues() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-submit-spawn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "claude")
        session.agentState = .spawning

        let accepted = mgr.submit(
            sessionId: session.id,
            text: "queued during spawn",
            attachments: [],
            intent: .auto
        ) { _ in }

        #expect(accepted == true)
        #expect(session.queue.count == 1)
        let head = try #require(session.queue.first)
        if case .text(let s) = head.blocks.first {
            #expect(s == "queued during spawn")
        } else {
            Issue.record("expected first block to be .text, got \(String(describing: head.blocks.first))")
        }

        let persisted = try store.loadQueue(sessionId: session.id)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == head.id)

        // Spawning must NOT trigger reattach — an attach is already in
        // flight; a second one would race or no-op against itself.
        #expect(session.agentState == .spawning)
    }

    @Test("submit while .disconnected enqueues and triggers reattach")
    func submitWhileDisconnectedReattaches() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-submit-disc-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        // Use an agentId with no launch spec so the reattach-triggered
        // attach takes the "no ACP launch spec" branch and lands on .failed
        // (mirrors ACPSessionManagerReattachTests.reattachFromDisconnected).
        let session = mgr.createSession(agentId: "no-such-agent-\(UUID().uuidString)")
        session.agentState = .disconnected

        let accepted = mgr.submit(
            sessionId: session.id,
            text: "trying again",
            attachments: [],
            intent: .auto
        ) { _ in }

        #expect(accepted == true)
        #expect(session.queue.count == 1)

        // Wait for the reattach's awaited attach() to land.
        for _ in 0..<50 where session.agentState == .disconnected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(session.agentState != .disconnected)
    }

    @Test("submit while .idle enqueues and triggers reattach")
    func submitWhileIdleReattaches() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-submit-idle-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        let session = mgr.createSession(agentId: "no-such-agent-\(UUID().uuidString)")
        // createSession leaves the session at the default .idle state;
        // re-asserting here makes the precondition explicit.
        session.agentState = .idle

        let accepted = mgr.submit(
            sessionId: session.id,
            text: "kick attach",
            attachments: [],
            intent: .auto
        ) { _ in }

        #expect(accepted == true)
        #expect(session.queue.count == 1)

        // attach() from .idle flips to .spawning, then lands on .failed on
        // the spec-missing branch. By the time reattach's awaited attach()
        // returns, the session has been touched. Poll until either a
        // runner appears or we see the setupState set by the spec-missing
        // branch.
        for _ in 0..<50 {
            if mgr.runners[session.id] != nil { break }
            // The spec-missing branch sets setupState to .needsSetup and
            // agentState to .failed — that's our observable signal.
            if case .needsSetup = session.setupState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .needsSetup = session.setupState {
            // success — reattach drove attach() far enough to evaluate spec
        } else {
            Issue.record("reattach from .idle did not invoke attach(): setupState=\(session.setupState)")
        }
    }

    @Test("submit with state/registry desync (.ready but no runner) self-heals")
    func submitReadyButNoRunnerSelfHeals() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-submit-desync-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        let mgr = ACPSessionManager(
            worktreeId: "/tmp/wt", worktreePath: "/tmp/wt", store: store)
        // Use an agentId with no launch spec so the reattach-triggered
        // attach lands on .failed via the spec-missing branch.
        let session = mgr.createSession(agentId: "no-such-agent-\(UUID().uuidString)")
        // Pre-set the desync state directly. runners[session.id] is already
        // nil for a freshly created session — that's the desync we're
        // testing: state says .ready, registry says no runner.
        session.agentState = .ready

        let accepted = mgr.submit(
            sessionId: session.id,
            text: "wake up",
            attachments: [],
            intent: .auto
        ) { _ in }

        #expect(accepted == true)
        #expect(session.queue.count == 1)
        // Fix invariant: state must transition off .ready synchronously so
        // reattach actually fires instead of no-opping.
        #expect(session.agentState != .ready)

        // Poll for the post-reattach state (spec-missing branch → .failed
        // observable via setupState == .needsSetup, matching the .idle test
        // above).
        for _ in 0..<50 {
            if mgr.runners[session.id] != nil { break }
            if case .needsSetup = session.setupState { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .needsSetup = session.setupState {
            // success — desync was recovered: reattach drove attach() far
            // enough to evaluate spec.
        } else {
            Issue.record("reattach from desync did not invoke attach(): setupState=\(session.setupState), agentState=\(session.agentState)")
        }
    }
}
