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

    private func planReviewParams(
        toolCallId: String = "toolu_1",
        title: String = "Approve Plan",
        kind: String? = "switch_mode"
    ) -> (options: [ACPPermissionOption], params: ACPPermissionRequestParams) {
        let options: [ACPPermissionOption] = [
            .init(optionId: "clear", name: "Yes, clear context", kind: "allow_always"),
            .init(optionId: "keep", name: "Yes, keep context", kind: "allow_always"),
            .init(optionId: "default", name: "Yes, manual", kind: "allow_once"),
            .init(optionId: "reject", name: "No", kind: "reject_once")
        ]
        return (options, ACPPermissionRequestParams(
            sessionId: "s",
            toolCall: .init(toolCallId: toolCallId, title: title, kind: kind),
            options: options
        ))
    }

    private func waitForPendingPermission(_ session: ACPSession) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while session.transcript.pendingPermission == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    @Test(
        "a plan review ignores a remembered decision and asks",
        arguments: [
            ("Approve Plan", "toolu_1", "switch_mode"),
            ("Implement this plan?", "plan-review:item_1", "switch_mode"),
            ("Approve Plan", "plan-review:item_2", nil),
        ] as [(String, String, String?)]
    )
    func planReviewIgnoresDecisionLog(title: String, toolCallId: String, kind: String?) async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: try makeStore())
        try await log.record(sessionId: "s", scopeKey: "tool:\(title)", decision: .allow, scope: .project)
        let policy = ACPPermissionPolicy(session: session, log: log)
        let (options, params) = planReviewParams(toolCallId: toolCallId, title: title, kind: kind)
        async let decision = policy.evaluate(scopeKey: "tool:\(title)", options: options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)
        #expect(session.transcript.pendingPermission != nil)
        policy.userCancelled()
        #expect(await decision.outcome == .cancelled)
    }

    @Test("auto-run never approves a plan review")
    func planReviewNeverAutoRuns() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.autoRunEnabled = true
        let policy = ACPPermissionPolicy(session: session, log: .init(store: try makeStore()))
        let (options, params) = planReviewParams()
        async let decision = policy.evaluate(scopeKey: "tool:Approve Plan", options: options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)
        #expect(session.transcript.pendingPermission != nil)
        policy.userCancelled()
        #expect(await decision.outcome == .cancelled)
    }

    @Test("an always-allow answer to a plan review acts once")
    func planReviewAllowAlwaysActsOnce() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let log = ACPPermissionDecisionLog(store: try makeStore())
        let policy = ACPPermissionPolicy(session: session, log: log)
        let (options, params) = planReviewParams()
        async let first = policy.evaluate(scopeKey: "tool:Approve Plan", options: options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)
        await policy.userDecided(scopeKey: "tool:Approve Plan", optionId: "keep", decision: .allow, persistScope: .project)
        #expect(await first.outcome == .selected(optionId: "keep"))
        #expect(try await log.lookup(sessionId: "s", scopeKey: "tool:Approve Plan") == nil)

        async let second = policy.evaluate(scopeKey: "tool:Approve Plan", options: options, params: params, requestID: .number(2))
        await waitForPendingPermission(session)
        #expect(session.transcript.pendingPermission != nil)
        policy.userCancelled()
        #expect(await second.outcome == .cancelled)
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
        await waitForPendingPermission(session)
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
        await waitForPendingPermission(session)

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
        await waitForPendingPermission(session)

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
        await waitForPendingPermission(session)

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

    /// A background child can ask after its parent's turn settled, so the
    /// answer derives the state from what still waits instead of assuming
    /// a turn is streaming.
    @Test("a decision settles the state from the turn and what still waits",
          arguments: [
            (true, false, ACPSession.StreamingState.streaming),
            (false, false, .idle),
            (false, true, .awaitingInput),
          ])
    func decisionDerivesWaitingState(foreground: Bool, questionPending: Bool,
                                     expected: ACPSession.StreamingState) async throws {
        let store = try makeStore()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        session.foregroundTurnActive = { foreground }
        session.transcript.streamingState = foreground ? .streaming : .idle
        if questionPending {
            session.transcript.pendingUserInputs = [ACPUserInputRequest(
                id: UUID(),
                source: .cursor(id: .string("q1"),
                                params: ACPQuestionRequestParams(toolCallId: "t1", title: "Pick", questions: [])),
                title: "Pick", message: "Pick", fields: [], mode: .form)]
        }
        let policy = ACPPermissionPolicy(session: session, log: .init(store: store))
        let opts: [ACPPermissionOption] = [.init(optionId: "allow", name: "Allow", kind: "allow_once")]
        async let decision = policy.evaluate(
            scopeKey: "tool:bash", options: opts, params: stubParams(), requestID: .number(7))
        await waitForPendingPermission(session)
        #expect(session.transcript.streamingState == .awaitingPermission)

        await policy.userDecided(scopeKey: "tool:bash", optionId: "allow", decision: .allow, persistScope: nil)

        #expect(await decision.outcome == .selected(optionId: "allow"))
        #expect(session.transcript.streamingState == expected)
    }

    @Test("a plan review whose plan or context changed since it parked refuses approval but accepts a rejection",
          arguments: ["planUpdate", "contextReset"])
    func staleReviewRefusesApproval(staleness: String) async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.apply(.usageUpdate(.init(used: 0, size: 1000, cost: nil)))
        let policy = ACPPermissionPolicy(session: session, log: .init(store: try makeStore()))
        let params = ACPToolCallPresentationTests.codexReview()
        async let decision = policy.evaluate(
            scopeKey: "tool:Implement this plan?", options: params.options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)
        session.apply(staleness == "planUpdate"
            ? .markdownPlan("item_1", "# Revised") : .usageUpdate(.init(used: 0, size: 1000, cost: nil)))

        #expect(await !policy.userDecided(
            scopeKey: "tool:Implement this plan?", optionId: "implement_plan", decision: .allow, persistScope: nil))
        #expect(await !policy.userDecided(
            scopeKey: "tool:Implement this plan?", optionId: "unoffered", decision: .allow, persistScope: nil))
        #expect(session.transcript.pendingPermission != nil)
        #expect(policy.pendingPermissionRequestID == .number(1))

        #expect(await policy.userDecided(
            scopeKey: "tool:Implement this plan?", optionId: "revise_plan", decision: .deny, persistScope: nil))
        #expect(await decision.outcome == .selected(optionId: "revise_plan"))
    }

    @Test("a child's plan review goes stale on the child's own plan or context, not the root's",
          arguments: [
              (fromChild: true, update: ACPSessionUpdate.markdownPlan("item_1", "# Revised"), stale: true),
              (fromChild: true, update: .usageUpdate(.init(used: 0, size: 1000, cost: nil)), stale: true),
              (fromChild: false, update: .markdownPlan("item_1", "# Revised"), stale: false),
              (fromChild: false, update: .usageUpdate(.init(used: 0, size: 1000, cost: nil)), stale: false),
          ])
    func childReviewUsesItsOwnCounters(fromChild: Bool, update: ACPSessionUpdate, stale: Bool) async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        session.apply(.subagentSpawned(.init(subagentSessionId: "child-1", name: "Plan")))
        let policy = ACPPermissionPolicy(session: session, log: .init(store: try makeStore()))
        let review = ACPToolCallPresentationTests.codexReview()
        let params = ACPPermissionRequestParams(sessionId: "child-1", toolCall: review.toolCall, options: review.options)
        async let decision = policy.evaluate(
            scopeKey: "tool:Implement this plan?", options: params.options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)

        if fromChild {
            session.applySubagentUpdate(update, subagentSessionId: "child-1")
        } else {
            session.apply(update)
        }

        #expect(policy.refusesApproval(optionKind: "allow_once", planDigest: nil) == stale)
        policy.userCancelled()
        #expect(await decision.outcome == .cancelled)
    }

    @Test("a plan that changes while the answer is being authorized cancels an approval but not a rejection",
          arguments: [
              (optionId: "implement_plan", decision: ACPPermissionDecision.allow, delivered: false),
              (optionId: "revise_plan", decision: .deny, delivered: true),
          ])
    func reviewGoingStaleDuringAuthorization(optionId: String, decision: ACPPermissionDecision,
                                             delivered: Bool) async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        let policy = ACPPermissionPolicy(session: session, log: .init(store: try makeStore()))
        let params = ACPToolCallPresentationTests.codexReview()
        async let outcome = policy.evaluate(
            scopeKey: "tool:Implement this plan?", options: params.options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)

        let answered = await policy.userDecided(
            scopeKey: "tool:Implement this plan?", optionId: optionId, decision: decision, persistScope: nil,
            stillAuthorized: {
                session.apply(.markdownPlan("item_1", "# Revised"))
                return true
            })
        #expect(answered == delivered)
        #expect(await outcome.outcome == (delivered ? .selected(optionId: optionId) : .cancelled))
    }

    @Test("a plan review approval must name the plan text the review parked with, unless it names none",
          arguments: [
              (digest: String(repeating: "0", count: 64) as String?, accepted: false),
              (digest: ACPToolCallPresentationTests.planReviewDigest, accepted: true),
              (digest: nil, accepted: true),
          ])
    func reviewApprovalNeedsDisplayedDigest(digest: String?, accepted: Bool) async throws {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "wt", title: "t")
        let policy = ACPPermissionPolicy(session: session, log: .init(store: try makeStore()))
        let params = ACPToolCallPresentationTests.codexReview()
        async let decision = policy.evaluate(
            scopeKey: "tool:Implement this plan?", options: params.options, params: params, requestID: .number(1))
        await waitForPendingPermission(session)

        #expect(await policy.userDecided(
            scopeKey: "tool:Implement this plan?", optionId: "implement_plan", decision: .allow, persistScope: nil,
            planDigest: digest) == accepted)
        if !accepted {
            #expect(policy.pendingPermissionRequestID == .number(1))
            policy.userCancelled()
        }
        #expect(await decision.outcome == (accepted ? .selected(optionId: "implement_plan") : .cancelled))
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
