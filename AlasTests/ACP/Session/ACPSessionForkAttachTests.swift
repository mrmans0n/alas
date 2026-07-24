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

    @Test("source advancing past the copied boundary falls back before native fork")
    func sourceHeadMismatchFallsBackToTranscript() async throws {
        let store = try seededForkStore()
        try store.appendMessage(
            sessionId: "source",
            id: "msg-source-1",
            kind: "agent",
            seq: 1,
            payload: Data(),
            createdAt: 1
        )
        let client = ACPMockClient()
        scriptInitialize(client, supportsFork: true)
        scriptSessionResult(client, method: "session/new", sessionId: "new-remote")
        let manager = makeManager(store: store, client: client)
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/new"])
        #expect(target.remoteSessionId == "new-remote")
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
        #expect(fork.contextDeliveryPending == true)
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

    @Test("downgrade persistence failure blocks the normal setup failure UI")
    func downgradePersistenceFailureBlocksNormalFailureUI() async throws {
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

        #expect(target.setupState != .needsSetup(reason: "adapter missing"))
        if case .failed(let reason) = target.agentState {
            #expect(reason.contains("Failed to persist fork fallback"))
            #expect(!reason.contains("adapter missing"))
        } else {
            Issue.record("Expected a durability-specific failure")
        }
        #expect(target.lastError?.contains("Failed to persist fork fallback") == true)
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

    @Test("broker pre-send failure durably falls back to transcript transfer")
    func brokerPreSendFailureFallsBackToTranscript() async throws {
        let store = try seededForkStore()
        let broker = ForkPreSendFailureBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(await broker.sentMethods == ["session/fork", "session/new"])
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.forkRecord?.contextDeliveryPending == true)
        #expect(target.remoteSessionId == "new-remote")
        #expect(manager.runners[target.id] != nil)
        let fork = try #require(try store.loadFork(targetSessionID: "target"))
        #expect(fork.phase == .ready)
        #expect(fork.mechanism == .transcriptTransfer)
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

    @Test("repeated startup replay failure preserves a completed native fork for retry")
    func repeatedStartupReplayFailurePreservesCompletedNativeFork() async throws {
        let store = try seededForkStore()
        let broker = ForkReplayBrokerService(failSecondStartupReplay: true)
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

        await manager.reattach(to: target.id)

        #expect(target.forkRecord?.phase == .negotiatingNative)
        #expect(target.forkRecord?.mechanism == nil)
        #expect(try store.loadFork(targetSessionID: "target")?.phase == .negotiatingNative)
        #expect(await broker.sentOperationKeys == [
            ACPBrokerOperationKey(rawValue: "startup:target:session/fork:source-remote")
        ])
        #expect(await broker.detachCount == 2)

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

    @Test("terminal fork error replay is released before fallback session/new")
    func terminalForkErrorReplayIsReleasedBeforeFallbackSessionNew() async throws {
        let store = try seededForkStore()
        let broker = ForkReplayBrokerService(forkError: JSONRPCError(
            code: -32601,
            message: "Method not found",
            data: nil
        ))
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )
        let target = try await hydratedTarget(manager)

        await manager.attach(to: target.id, freshlyCreated: true)

        #expect(await broker.sentMethods == ["session/fork", "session/new"])
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.remoteSessionId == "new-remote")
        #expect(manager.runners[target.id] != nil)
        try await waitUntil {
            await broker.acknowledgedCursors == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3)
            ]
        }
    }

    @Test("source mismatch closes and releases a replayed fork before session/new")
    func sourceMismatchClosesAndReleasesReplayedFork() async throws {
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
        try store.appendMessage(
            sessionId: "source",
            id: "msg-source-1",
            kind: "agent",
            seq: 1,
            payload: Data(),
            createdAt: 1
        )

        await manager.reattach(to: target.id)

        #expect(await broker.sentMethods == [
            "session/fork",
            "session/close",
            "session/new"
        ])
        #expect(await broker.closedSessionIDs == ["forked-remote"])
        #expect(target.forkRecord?.phase == .ready)
        #expect(target.forkRecord?.mechanism == .transcriptTransfer)
        #expect(target.remoteSessionId == "new-remote")
        try await waitUntil {
            await broker.acknowledgedCursors == [
                ACPBrokerEventCursor(rawValue: 2),
                ACPBrokerEventCursor(rawValue: 3),
                ACPBrokerEventCursor(rawValue: 4)
            ]
        }
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
        try store.appendMessage(
            sessionId: "source",
            id: "msg-source-0",
            kind: "user",
            seq: 0,
            payload: Data(),
            createdAt: 0
        )
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if ContinuousClock.now - start > timeout {
                throw ForkAttachTestTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ForkAttachTestTimeout: Error {}

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
    case preSendFailure
}

private actor ForkPreSendFailureBrokerService: ACPBrokerServicing {
    private var nextRequestID: UInt64 = 0
    private(set) var sentMethods: [String] = []

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        ACPBrokerOpenResult(
            snapshot: snapshot(
                brokerId: params.brokerId,
                sessionId: params.sessionId,
                acknowledgedCursor: .init(rawValue: 0)
            ),
            adopted: false
        )
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        ACPBrokerAttachResult(
            snapshot: snapshot(
                brokerId: params.brokerId,
                sessionId: "target",
                acknowledgedCursor: params.acknowledgedCursor
            ),
            events: []
        )
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sentMethods.append(params.method)
        if params.method == "session/fork" {
            throw ForkReplayBrokerError.preSendFailure
        }
        nextRequestID += 1
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: nextRequestID),
            replayed: false,
            result: .object([
                "sessionId": .string("new-remote"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ]),
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
        ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(
        brokerId: ACPBrokerID,
        sessionId: String,
        acknowledgedCursor: ACPBrokerEventCursor
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: brokerId,
                generation: ACPBrokerGeneration(rawValue: 11),
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
            journalTail: acknowledgedCursor,
            pendingRequests: [],
            operations: []
        )
    }
}

private actor ForkReplayBrokerService: ACPBrokerServicing {
    private let forkError: JSONRPCError?
    private let failSecondStartupReplay: Bool
    private var attachCount = 0
    private var replayEvents: [ACPBrokerEvent] = []
    private var nextCursor: UInt64 = 2
    private(set) var sentOperationKeys: [ACPBrokerOperationKey] = []
    private(set) var sentMethods: [String] = []
    private(set) var closedSessionIDs: [String] = []
    private(set) var acknowledgedCursors: [ACPBrokerEventCursor] = []
    private(set) var detachCount = 0

    init(
        forkError: JSONRPCError? = nil,
        failSecondStartupReplay: Bool = false
    ) {
        self.forkError = forkError
        self.failSecondStartupReplay = failSecondStartupReplay
    }

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
            if failSecondStartupReplay {
                throw ForkReplayBrokerError.trailingReplayFailure
            }
            return ACPBrokerAttachResult(
                snapshot: snapshot(
                    brokerId: params.brokerId,
                    sessionId: "target",
                    acknowledgedCursor: params.acknowledgedCursor
                ),
                events: replayEvents
            )
        default:
            return ACPBrokerAttachResult(
                snapshot: snapshot(
                    brokerId: params.brokerId,
                    sessionId: "target",
                    acknowledgedCursor: params.acknowledgedCursor
                ),
                events: replayEvents
            )
        }
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sentMethods.append(params.method)
        sentOperationKeys.append(params.operationKey)
        let result: ACPBrokerJSONValue?
        let error: JSONRPCError?
        switch params.method {
        case "session/fork":
            result = forkError == nil ? forkResult : nil
            error = forkError
        case "session/close":
            let closeParams = try JSONDecoder().decode(
                ACPSessionCloseParams.self,
                from: params.params.data
            )
            closedSessionIDs.append(closeParams.sessionId)
            result = .null
            error = nil
        case "session/new":
            result = sessionNewResult
            error = nil
        default:
            result = .null
            error = nil
        }
        let wasReplayed = replayEvents.contains(where: { event in
            if case .operationCompleted(let operationKey, _) = event.kind {
                return operationKey == params.operationKey
            }
            return false
        })
        if !wasReplayed {
            replayEvents.append(ACPBrokerEvent(
                cursor: ACPBrokerEventCursor(rawValue: nextCursor),
                kind: .operationCompleted(
                    operationKey: params.operationKey,
                    outcome: ACPBrokerRPCOutcome(result: result, error: error)
                )
            ))
            nextCursor += 1
        }
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: UInt64(sentOperationKeys.count)),
            replayed: wasReplayed,
            result: result,
            error: error,
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
        detachCount += 1
        return ACPBrokerSimpleOK(ok: true)
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

    private var sessionNewResult: ACPBrokerJSONValue {
        .object([
            "sessionId": .string("new-remote"),
            "availableModels": .array([]),
            "availableModes": .array([]),
            "promptSuggestions": .array([]),
            "configOptions": .array([])
        ])
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
            journalTail: replayEvents.last?.cursor ?? acknowledgedCursor,
            pendingRequests: [],
            operations: replayEvents.compactMap { event in
                guard case .operationCompleted(let operationKey, let outcome) = event.kind else {
                    return nil
                }
                return ACPBrokerOperationSnapshot(
                    operationKey: operationKey,
                    adapterRequestId: ACPBrokerAdapterRequestID(rawValue: event.cursor.rawValue),
                    method: sentOperationKeys.first == operationKey ? "session/fork" : "unknown",
                    params: .object([:]),
                    terminalOutcome: outcome
                )
            }
        )
    }
}
