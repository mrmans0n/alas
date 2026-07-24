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

    @Test("downgrade persistence failure keeps the fork negotiating")
    func downgradePersistenceFailureKeepsForkNegotiating() async throws {
        let store = try seededForkStore()
        try installFinalizeFailure(mechanism: .transcriptTransfer, store: store)
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
        #expect(target.forkRecord?.phase == .negotiatingNative)
        #expect(target.forkRecord?.mechanism == nil)
        #expect(target.forkRecord?.contextDeliveryPending == false)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .negotiatingNative)
        #expect(fork.mechanism == nil)
        #expect(fork.contextDeliveryPending == false)
    }

    @Test("native finalization failure closes the remote before acknowledging transcript fallback")
    func nativeFinalizationFailureClosesRemoteAndOrdersAcknowledgements() async throws {
        let store = try seededForkStore()
        try installFinalizeFailure(mechanism: .nativeACP, store: store)
        let client = ACPMockClient()
        let acknowledgements = ForkAcknowledgementRecorder()
        scriptInitialize(client, supportsFork: true)
        client.scriptResponse(method: "session/fork") { _ in
            ACPResponse(
                body: try JSONEncoder().encode(ACPSessionNewResult(
                    sessionId: "orphaned-remote",
                    availableModels: [],
                    availableModes: [],
                    currentModel: nil,
                    currentMode: nil,
                    promptSuggestions: []
                )),
                durableConsumptionAcknowledgement: {
                    acknowledgements.record("fork")
                }
            )
        }
        client.scriptResponse(method: "session/close") { request in
            let params = try #require(request.params as? ACPSessionCloseParams)
            #expect(params.sessionId == "orphaned-remote")
            return ACPResponse(
                body: Data(),
                durableConsumptionAcknowledgement: {
                    acknowledgements.record("close")
                }
            )
        }
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/fork", "session/close"])
        #expect(manager.runners[target.id] == nil)
        #expect(target.remoteSessionId == nil)
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let row = try #require(try store.loadSession(id: "target"))
        #expect(row.remoteSessionId == nil)
        #expect(row.origin == .alasCreated)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
        #expect(acknowledgements.values == ["close", "fork"])
    }

    @Test("broker replay failure keeps negotiation and reuses the durable fork key")
    func brokerReplayFailureRetriesStableForkOperation() async throws {
        let store = try seededForkStore()
        let broker = ForkReplayBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(target.forkRecord?.phase == .negotiatingNative)
        #expect(target.forkRecord?.mechanism == nil)
        #expect(try store.loadFork(targetSessionID: "target")?.phase == .negotiatingNative)
        #expect(await broker.sentOperationKeys == [
            ACPBrokerOperationKey(rawValue: "startup:target:session/fork:source-remote")
        ])
        #expect(await broker.acknowledgedCursors.isEmpty)

        await manager.reattach(to: target.id)

        #expect(await broker.sentOperationKeys == [
            ACPBrokerOperationKey(rawValue: "startup:target:session/fork:source-remote"),
            ACPBrokerOperationKey(rawValue: "startup:target:session/fork:source-remote")
        ])
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .nativeACP)
        #expect(target.remoteSessionId == "forked-remote")
        #expect(await broker.acknowledgedCursors == [ACPBrokerEventCursor(rawValue: 2)])
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

    private func installFinalizeFailure(
        mechanism: ACPSessionForkMechanism,
        store: ACPSessionStore
    ) throws {
        try store.db.exec("""
        CREATE TRIGGER fail_\(mechanism.rawValue)_fork_finalize
        BEFORE UPDATE OF mechanism ON session_forks
        WHEN NEW.mechanism = '\(mechanism.rawValue)'
        BEGIN
          SELECT RAISE(ABORT, 'forced \(mechanism.rawValue) finalization failure');
        END
        """)
    }
}

private final class ForkAcknowledgementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private enum ForkReplayBrokerError: Error {
    case trailingReplayFailure
}

private actor ForkReplayBrokerService: ACPBrokerServicing {
    private var attachCount = 0
    private(set) var sentOperationKeys: [ACPBrokerOperationKey] = []
    private(set) var acknowledgedCursors: [ACPBrokerEventCursor] = []

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        ACPBrokerOpenResult(snapshot: snapshot(
            brokerId: params.brokerId,
            sessionId: params.sessionId,
            acknowledgedCursor: .init(rawValue: 0)
        ), adopted: false)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        attachCount += 1
        switch attachCount {
        case 2:
            throw ForkReplayBrokerError.trailingReplayFailure
        case 3:
            return ACPBrokerAttachResult(
                snapshot: snapshot(
                    brokerId: params.brokerId,
                    sessionId: "target",
                    acknowledgedCursor: params.acknowledgedCursor
                ),
                events: [forkCompletionEvent]
            )
        default:
            return ACPBrokerAttachResult(
                snapshot: snapshot(
                    brokerId: params.brokerId,
                    sessionId: "target",
                    acknowledgedCursor: params.acknowledgedCursor
                ),
                events: []
            )
        }
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sentOperationKeys.append(params.operationKey)
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: UInt64(sentOperationKeys.count)),
            replayed: sentOperationKeys.count > 1,
            result: forkResult,
            pending: false
        )
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        acknowledgedCursors.append(params.cursor)
        return ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    private var forkResult: ACPBrokerJSONValue {
        .object([
            "sessionId": .string("forked-remote"),
            "availableModels": .array([]),
            "availableModes": .array([]),
            "promptSuggestions": .array([]),
            "configOptions": .array([])
        ])
    }

    private var forkCompletionEvent: ACPBrokerEvent {
        ACPBrokerEvent(
            cursor: ACPBrokerEventCursor(rawValue: 2),
            kind: .operationCompleted(
                operationKey: ACPBrokerOperationKey(
                    rawValue: "startup:target:session/fork:source-remote"
                ),
                outcome: ACPBrokerRPCOutcome(result: forkResult, error: nil)
            )
        )
    }

    private func snapshot(
        brokerId: ACPBrokerID,
        sessionId: String,
        acknowledgedCursor: ACPBrokerEventCursor
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: brokerId,
                generation: ACPBrokerGeneration(rawValue: 7),
                alasSessionId: sessionId,
                adapterProgram: "mock",
                adapterArgs: [],
                cwd: "/tmp/wt",
                envKeys: [],
                createdAtMillis: 10
            ),
            initializeResult: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "sessionCapabilities": .object([
                        "fork": .object([:])
                    ])
                ]),
                "authMethods": .array([])
            ]),
            remoteSessionResult: nil,
            turnState: .idle,
            acknowledgedCursor: acknowledgedCursor,
            journalTail: ACPBrokerEventCursor(rawValue: 2),
            pendingRequests: [],
            operations: []
        )
    }
}
