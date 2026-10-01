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
        #expect(session.readOnlyBlockedTools == (allowed ? [] : ["Tool"]))
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
