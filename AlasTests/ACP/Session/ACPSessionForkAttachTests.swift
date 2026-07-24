import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager fork attach")
struct ACPSessionForkAttachTests {
    @Test("negotiating fork uses native ACP and persists the returned remote session")
    func negotiatingForkUsesNativeACP() async throws {
        let store = try seededForkStore()
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true)
        scriptSessionResult(client, method: "session/fork", sessionId: "forked-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        #expect(manager.sessions["source"] == nil)
        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/fork"])
        #expect(client.sent.last?.brokerOperationKey == "startup:target:session/fork:source-remote")
        #expect(manager.runners[target.id] != nil)
        #expect(target.remoteSessionId == "forked-remote")
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .nativeACP)
        #expect(target.forkRecord?.contextDeliveryPending == false)
        let row = try #require(try store.loadSession(id: "target"))
        #expect(row.remoteSessionId == "forked-remote")
        #expect(row.origin == .agentForked)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .nativeACP)
        #expect(fork.contextDeliveryPending == false)
    }

    @Test("missing fork capability falls back to transcript transfer and session/new")
    func missingForkCapabilityFallsBackToTranscript() async throws {
        let store = try seededForkStore()
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: false)
        scriptSessionResult(client, method: "session/new", sessionId: "new-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/new"])
        #expect(manager.runners[target.id] != nil)
        #expect(target.remoteSessionId == "new-remote")
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
    }

    @Test("session/fork JSON-RPC failure falls back on the same connection")
    func forkJSONRPCFailureFallsBackOnSameConnection() async throws {
        let store = try seededForkStore()
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true)
        client.script(method: "session/fork") { _ in
            throw ACPClientError.jsonrpc(.init(
                code: -32601,
                message: "Method not found",
                data: nil
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "new-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/fork", "session/new"])
        #expect(manager.runners[target.id] != nil)
        #expect(target.remoteSessionId == "new-remote")
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        #expect(client.shutdownCount == 0)
    }

    @Test("fork auth failure finalizes transcript fallback and keeps needs-auth state")
    func forkAuthFailurePreservesNeedsAuth() async throws {
        let store = try seededForkStore()
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true, authMethods: [terminalAuthMethod()])
        client.script(method: "session/fork") { _ in
            throw ACPClientError.jsonrpc(.init(
                code: -32000,
                message: "login required",
                data: nil
            ))
        }
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/fork"])
        #expect(manager.runners[target.id] == nil)
        if case .needsAuth(let methods, let reason) = target.setupState {
            #expect(methods.map(\.id) == ["claude-login"])
            #expect(reason == "login required")
        } else {
            Issue.record("Expected needs-auth setup state")
        }
        #expect(target.agentState == .failed("login required"))
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
    }

    @Test("reattaching the same target reuses the stable native fork operation key")
    func reattachReusesStableForkOperationKey() async throws {
        let first = try await nativeForkOperationKey()
        let second = try await nativeForkOperationKey()

        #expect(first == "startup:target:session/fork:source-remote")
        #expect(second == first)
    }

    @Test("native fork resolves the source remote ID from persistence")
    func nativeForkResolvesSourceFromPersistence() async throws {
        let store = try seededForkStore(sourceRemoteSessionID: "persisted-source-remote")
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true)
        scriptSessionResult(client, method: "session/fork", sessionId: "forked-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        #expect(manager.sessions["source"] == nil)
        await manager.attach(to: target.id, freshlyCreated: true)

        let params = try #require(client.sent.last?.params as? ACPSessionForkParams)
        #expect(params.sessionId == "persisted-source-remote")
        #expect(client.sent.last?.brokerOperationKey
            == "startup:target:session/fork:persisted-source-remote")
    }

    @Test("setup failure durably downgrades a negotiating fork before surfacing the error")
    func setupFailureDowngradesNegotiatingFork() async throws {
        let store = try seededForkStore()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .missing(reason: "adapter missing") }
        )
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(target.setupState == .needsSetup(reason: "adapter missing"))
        #expect(target.agentState == .failed("adapter missing"))
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
    }

    @Test("launch failure durably downgrades a negotiating fork before surfacing the error")
    func launchFailureDowngradesNegotiatingFork() async throws {
        let store = try seededForkStore()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                throw ACPClientError.notRunning
            }
        )
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        if case .failed(let reason) = target.agentState {
            #expect(reason.contains("Failed to launch agent"))
        } else {
            Issue.record("Expected launch failure")
        }
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
    }

    private func nativeForkOperationKey() async throws -> String? {
        let store = try seededForkStore()
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true)
        scriptSessionResult(client, method: "session/fork", sessionId: "forked-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        return client.sent.first { $0.method == "session/fork" }?.brokerOperationKey
    }

    private func seededForkStore(
        sourceRemoteSessionID: String = "source-remote"
    ) throws -> ACPSessionStore {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(
            id: "source",
            remoteSessionID: sourceRemoteSessionID
        ))
        try store.createFork(
            session: row(id: "target", remoteSessionID: nil),
            messages: [],
            record: .init(
                targetSessionID: "target",
                sourceSessionID: "source",
                sourceAgentID: "claude",
                sourceBoundarySequence: 0,
                inheritedMessageCount: 0,
                phase: .negotiatingNative,
                mechanism: nil,
                contextDeliveryPending: false
            )
        )
        return store
    }

    private func row(id: String, remoteSessionID: String?) -> ACPSessionRow {
        ACPSessionRow(
            id: id,
            agentId: "claude",
            title: id.capitalized,
            titleSource: .placeholder,
            remoteSessionId: remoteSessionID,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        )
    }

    private func makeManager(
        store: ACPSessionStore,
        client: ACPMockClient
    ) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
    }

    private func hydratedTarget(_ manager: ACPSessionManager) async throws -> ACPSession {
        let target = try #require(manager.placeholderSession(id: "target"))
        await manager.hydrateIfNeeded(id: target.id)
        return target
    }

    private func scriptInitialize(
        _ client: ACPMockClient,
        supportsFork: Bool,
        authMethods: [ACPInitializeResult.ACPAuthMethod] = []
    ) {
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    sessionCapabilities: .init(
                        fork: supportsFork ? .init() : nil
                    )
                ),
                authMethods: authMethods
            ))
        }
    }

    private func terminalAuthMethod() -> ACPInitializeResult.ACPAuthMethod {
        .init(
            id: "claude-login",
            name: "Claude Login",
            kind: .terminal
        )
    }

    private func scriptSessionResult(
        _ client: ACPMockClient,
        method: String,
        sessionId: String
    ) {
        client.script(method: method) { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: sessionId,
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
    }

    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-fork-attach-\(UUID().uuidString).sqlite")
            .path
    }
}
