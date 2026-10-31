import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPPermissionPolicy")
struct ACPPermissionPolicyTests {
    private func makeStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pol-\(UUID()).sqlite")
        let s = try ACPSessionStore(path: url.path)
        try s.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        return s
    }

    @Test("auto-run short-circuits with allow_once")
    func autoRun() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.autoRunEnabled = true
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let resp = await policy.evaluate(scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(1))
        #expect(resp.outcome == .selected(optionId: "allow"))
    }

    @Test("logged session-scope decision is replayed without UI")
    func remembered() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: store)
        try await log.record(sessionId: "s", scopeKey: "tool:bash", decision: .deny, scope: .session)
        let policy = ACPPermissionPolicy(session: session, log: log)
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let resp = await policy.evaluate(scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(1))
        #expect(resp.outcome == .selected(optionId: "deny"))
    }

    @Test(
        "read-only side sessions run only reads, despite auto-run and remembered allows",
        arguments: [
            ("read", true), ("search", true), ("think", true),
            ("edit", false), ("execute", false), ("delete", false), ("switch_mode", false),
            (nil, false),
        ] as [(String?, Bool)]
    )
    func readOnlyGate(kind: String?, allowed: Bool) async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.autoRunEnabled = true
        session.readOnlyRestricted = true
        let log = ACPPermissionDecisionLog(store: store)
        try await log.record(sessionId: "s", scopeKey: "tool:x", decision: .allow, scope: .project)
        let policy = ACPPermissionPolicy(session: session, log: log)
        let opts: [ACPPermissionOption] = [
            .init(optionId: "always", name: "Always", kind: "allow_always"),
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "tc", title: "Tool", kind: kind),
            options: opts
        )

        let resp = await policy.evaluate(scopeKey: "tool:x", options: opts, params: params, requestID: .number(1))

        #expect(resp.outcome == .selected(optionId: allowed ? "allow" : "deny"))
        #expect(session.readOnlyBlockedTools.map(\.title) == (allowed ? [] : ["Tool"]))
    }

    @Test("a read-only rejection without a one-shot option cancels instead of persisting")
    func readOnlyRejectionNeverPersists() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.readOnlyRestricted = true
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "never", name: "Never", kind: "reject_always")
        ]
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "tc", title: "Edit", kind: "edit"),
            options: opts
        )

        let resp = await policy.evaluate(scopeKey: "tool:Edit", options: opts, params: params, requestID: .number(1))

        #expect(resp.outcome == .cancelled)
    }

    @Test("a read-only read with only a persistent allow asks with one-shot choices only")
    func readOnlyReadNeverPicksPersistentAllow() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.readOnlyRestricted = true
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "always", name: "Always", kind: "allow_always"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        let params = ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: "tc", title: "Read", kind: "read"),
            options: opts
        )
        async let decision = policy.evaluate(scopeKey: "tool:Read", options: opts, params: params, requestID: .number(1))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(session.transcript.pendingPermission != nil)
        // The parked prompt must not offer the persistent allow either.
        #expect(session.transcript.pendingPermission?.params.options.map(\.kind) == ["reject_once"])

        policy.userCancelled()
        #expect(await decision.outcome == .cancelled)
    }

    @Test("cancelRequest resolves a parked permission matching its id as cancelled")
    func cancelRequestResolvesMatchingParkedPermission() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "opencode", worktreeId: "wt", title: "t")
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        try? await Task.sleep(for: .milliseconds(100))

        policy.cancelRequest(id: .number(7))

        let resp = await decision
        #expect(resp.outcome == .cancelled)
        #expect(session.transcript.pendingPermission == nil)
    }

    @Test("cancelRequest for a non-matching id leaves the parked permission untouched")
    func cancelRequestIgnoresNonMatchingId() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "opencode", worktreeId: "wt", title: "t")
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [
            .init(optionId: "allow", name: "Allow", kind: "allow_once"),
            .init(optionId: "deny", name: "Deny", kind: "reject_once")
        ]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        try? await Task.sleep(for: .milliseconds(100))

        policy.cancelRequest(id: .number(999))
        #expect(session.transcript.pendingPermission != nil)

        await policy.userDecided(scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: nil)
        let resp = await decision
        #expect(resp.outcome == .selected(optionId: "allow"))
    }

    @Test("an answer the caller may no longer give cancels the request instead")
    func withheldAnswerCancelsTheRequest() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: store)
        let policy = ACPPermissionPolicy(session: session, log: log)
        let opts: [ACPPermissionOption] = [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        let answered = await policy.userDecided(
            scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: .session,
            stillAuthorized: { false }
        )
        #expect(!answered)
        #expect(await decision.outcome == .cancelled)
        #expect(try await log.lookup(sessionId: "s", scopeKey: "tool:bash") == nil)
    }

    @Test("a remembered answer covers the agent's next request before its record lands")
    func rememberedAnswerCoversTheNextRequestAtOnce() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        // A record that never lands stands in for one still in flight.
        let log = ACPPermissionDecisionLog(store: store, canWrite: { false })
        let box = PolicyBox()
        let policy = ACPPermissionPolicy(session: session, log: log) { id, _ in
            // Parking the second request is the failure; cancel it rather than hang.
            guard id == .number(8) else { return }
            Task { @MainActor in box.policy?.userCancelled() }
        }
        box.policy = policy
        let opts: [ACPPermissionOption] = [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        async let first = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        await policy.userDecided(
            scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: .session)
        #expect(await first.outcome == .selected(optionId: "allow"))
        let second = await policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(8))
        #expect(second.outcome == .selected(optionId: "allow"))
    }

    @Test("a request the agent withdraws while its answer is being recorded stays cancelled")
    func requestWithdrawnWhileAnsweringStaysCancelled() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        // `$/cancel_request` lands while the answer is still on its way.
        let answered = await policy.userDecided(
            scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: .session,
            stillAuthorized: {
                _ = policy.cancelRequest(id: .number(7))
                return true
            }
        )
        #expect(!answered)
        #expect(await decision.outcome == .cancelled)
    }

    /// A permission that parks out of turn (a background child asking after
    /// the parent's prompt returned) must not leave the session streaming.
    @Test("a decision restores the state the permission parked from",
          arguments: [ACPSession.StreamingState.idle, .streaming])
    func decisionRestoresParkedState(prior: ACPSession.StreamingState) async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.transcript.streamingState = prior
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(session.transcript.streamingState == .awaitingPermission)

        await policy.userDecided(scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: nil)

        #expect(await decision.outcome == .selected(optionId: "allow"))
        #expect(session.transcript.streamingState == prior)
    }

    @Test("persisted user decisions commit before userDecided returns")
    func persistedUserDecisionIsAwaited() async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: store)
        let policy = ACPPermissionPolicy(session: session, log: log)
        await policy.userDecided(
            scopeKey: "tool:bash",
            optionId: "allow",
            decision: .allow,
            persistScope: .session
        )

        #expect(try await log.lookup(sessionId: "s", scopeKey: "tool:bash") == .allow)
    }

    private func stubParams() -> ACPPermissionRequestParams {
        .init(sessionId: "s",
              toolCall: .init(toolCallId: "tc", title: "bash", kind: "execute", status: "pending",
                              content: nil, locations: nil, rawInput: nil, rawOutput: nil),
              options: [])
    }
}

@MainActor
private final class PolicyBox {
    var policy: ACPPermissionPolicy?
}
