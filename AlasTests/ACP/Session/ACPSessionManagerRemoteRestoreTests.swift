import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager remote restore")
struct ACPSessionManagerRemoteRestoreTests {
    @Test("loaded sessions refresh advertised provider state")
    func loadedSessionRefreshesProviders() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: false, providers: true)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-id")
        client.script(method: "providers/list") { _ in
            try JSONEncoder().encode(ACPProvidersListResult(providers: [.init(
                providerId: "claude",
                name: "Enterprise Gateway",
                supported: ["anthropic"],
                required: true,
                current: .init(apiType: "anthropic", baseUrl: "https://gateway.example")
            )]))
        }

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "providers/list"])
        #expect(session.availableProviders.first?.name == "Enterprise Gateway")
        #expect(session.currentProviderDisplayName == nil)
        await manager.detach(sessionId: session.id)
    }

    @Test("Alas-owned sessions use resume when advertised")
    func localSessionUsesResume() async throws {
        let (manager, store, client, session) = try fixture(origin: .alasCreated)
        scriptInitialize(client, canLoad: true, canResume: true)
        client.script(method: "session/resume") { _ in Data("{}".utf8) }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method).contains("session/resume"))
        #expect(!client.sent.map(\.method).contains("session/load"))
        #expect(!client.sent.map(\.method).contains("session/new"))
        #expect(session.agentState == .ready)
        #expect(try store.loadSession(id: session.id)?.remoteSessionId == "remote-id")
        await manager.detach(sessionId: session.id)
    }

    @Test("Alas-owned resume suppresses helper stdout replay when locally hydrated")
    func localSessionResumeSuppressesHydratedHelperReplay() async throws {
        let persistedToolCall = ACPMessage.toolCall(.init(
            toolCallId: "tool-1",
            title: "Read file",
            kind: "read",
            status: "completed",
            content: "done"
        ))
        let (manager, store, client, session) = try fixture(
            origin: .alasCreated,
            localMessage: persistedToolCall
        )
        scriptInitialize(client, canLoad: true, canResume: true)
        client.scriptAsync(method: "session/resume") { _ in
            client.emit(.init(sessionId: "remote-id", update: .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: [.content(.text("done"))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ))))
            return Data("{}".utf8)
        }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method).contains("session/resume"))
        #expect(client.yieldedUpdateCount == 1)
        #expect(session.transcript.messages.count == 1)
        #expect(try store.messageCount(sessionId: session.id) == 1)

        client.emit(.init(sessionId: "remote-id", update: .agentMessageChunk(.text("live follow-up"))))
        try await waitUntil { session.transcript.messages.count == 2 }
        await manager.detach(sessionId: session.id)
    }

    @Test("Alas-owned sessions recover locally when resume fails")
    func localSessionResumeFailureRecoversWithNewSession() async throws {
        let (manager, store, client, session) = try fixture(
            origin: .alasCreated,
            localMessage: .user(id: UUID(), text: "persisted context", attachments: [])
        )
        scriptInitialize(client, canLoad: true, canResume: true)
        client.script(method: "session/resume") { _ in
            throw JSONRPCError(code: -32000, message: "session expired", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        try await waitUntil {
            client.sent.map(\.method).contains("session/prompt")
                && session.contextRecoveryStatus == .restored
        }

        #expect(client.sent.map(\.method) == ["initialize", "session/resume", "session/new", "session/prompt"])
        #expect(session.agentState == .ready)
        #expect(session.remoteSessionId == "remote-new")
        // Recovery marks the session restored before its queued
        // `contextRecoveryPending` write lands; wait for it before reading.
        await manager.flushAllPersistence()
        #expect(try store.loadSession(id: session.id)?.remoteSessionId == "remote-new")
        #expect(try store.loadSession(id: session.id)?.contextRecoveryPending == false)
        await manager.detach(sessionId: session.id)
    }

    @Test("imported sessions prefer strict load so history can replay")
    func importedSessionUsesLoad() async throws {
        let (manager, store, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: true)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-id")

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method).contains("session/load"))
        #expect(!client.sent.map(\.method).contains("session/resume"))
        #expect(session.agentState == .ready)
        await manager.detach(sessionId: session.id)
        #expect(try store.loadSession(id: session.id)?.origin == .agentImported)
    }

    @Test("imported sessions resume the same remote session when strict load fails")
    func importedSessionResumesWhenLoadFails() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: true)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32603, message: "Internal error", data: nil)
        }
        client.script(method: "session/resume") { _ in Data("{}".utf8) }

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/resume"])
        #expect(session.agentState == .ready)
        #expect(session.remoteSessionId == "remote-id")
        #expect(session.contextRestoreWarning?.canSendTranscript == false)
        #expect(session.contextRestoreWarning?.message.contains("remain in the agent") == true)
        await manager.detach(sessionId: session.id)
    }

    @Test("imported sessions retry a durably completed load before resuming")
    func importedSessionRetriesDurableLoadCompletion() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: true)
        var loadAttempts = 0
        client.script(method: "session/load") { _ in
            loadAttempts += 1
            if loadAttempts == 1 {
                throw ACPBrokerDurableCompletionReplayError(
                    outcome: .init(result: .object(["sessionId": .string("remote-id")]), error: nil),
                    underlying: JSONRPCError(code: -32603, message: "Replay failed", data: nil)
                )
            }
            return Data("{}".utf8)
        }

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/load"])
        #expect(session.agentState == .ready)
        await manager.detach(sessionId: session.id)
    }

    @Test("strict load fallback keeps hydrated replay suppressed through resume")
    func importedSessionLoadFallbackSuppressesResumeReplay() async throws {
        let persistedToolCall = ACPMessage.toolCall(.init(
            toolCallId: "tool-1",
            title: "Read file",
            kind: "read",
            status: "completed",
            content: "done"
        ))
        let (manager, store, client, session) = try fixture(
            origin: .agentImported,
            localMessage: persistedToolCall
        )
        scriptInitialize(client, canLoad: true, canResume: true)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32603, message: "Internal error", data: nil)
        }
        client.scriptAsync(method: "session/resume") { _ in
            client.emit(.init(sessionId: "remote-id", update: .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: [.content(.text("done"))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ))))
            return Data("{}".utf8)
        }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/resume"])
        #expect(session.transcript.messages.count == 1)
        #expect(try store.messageCount(sessionId: session.id) == 1)
        await manager.detach(sessionId: session.id)
    }

    @Test("strict load fallback discards partial load replay before resume")
    func importedSessionLoadFallbackDiscardsPartialLoadReplay() async throws {
        let (manager, store, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: true)
        client.scriptAsync(method: "session/load") { _ in
            client.emit(.init(
                sessionId: "remote-id",
                update: .agentMessageChunk(.text("partial failed load"))
            ))
            throw JSONRPCError(code: -32603, message: "Internal error", data: nil)
        }
        client.scriptAsync(method: "session/resume") { _ in
            client.emit(.init(
                sessionId: "remote-id",
                update: .agentMessageChunk(.text("resumed history"))
            ))
            return Data("{}".utf8)
        }

        await manager.attach(to: session.id, freshlyCreated: false)
        try await waitUntil { session.transcript.messages.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/resume"])
        #expect(session.transcript.messages.count == 1)
        #expect(try store.messageCount(sessionId: session.id) == 1)
        guard case .agent(_, _, let text) = session.transcript.messages[0] else {
            Issue.record("Expected resumed history")
            return
        }
        #expect(text.value == "resumed history")
        await manager.detach(sessionId: session.id)
    }

    @Test("imported sessions resume after their history has been persisted locally")
    func importedSessionWithLocalHistoryUsesResume() async throws {
        let (manager, store, client, session) = try fixture(
            origin: .agentImported,
            localMessage: .agent(id: UUID(), StreamingText("persisted history"))
        )
        scriptInitialize(client, canLoad: true, canResume: true)
        client.script(method: "session/resume") { _ in Data("{}".utf8) }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method).contains("session/resume"))
        #expect(!client.sent.map(\.method).contains("session/load"))
        #expect(try store.messageCount(sessionId: session.id) == 1)
        await manager.detach(sessionId: session.id)
    }

    @Test("load-only imports suppress replay after history has been persisted locally")
    func loadOnlyImportSuppressesPersistedHistoryReplay() async throws {
        let (manager, store, client, session) = try fixture(
            origin: .agentImported,
            localMessage: .agent(id: UUID(), StreamingText("persisted history"))
        )
        scriptInitialize(client, canLoad: true, canResume: false)
        client.scriptAsync(method: "session/load") { _ in
            client.emit(.init(
                sessionId: "remote-id",
                update: .agentMessageChunk(.text("persisted history"))
            ))
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-id",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }

        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method).contains("session/load"))
        #expect(try store.messageCount(sessionId: session.id) == 1)
        #expect(session.transcript.messages.count == 1)
        await manager.detach(sessionId: session.id)
    }

    @Test("resume-only imports stay connected and disclose unavailable local history")
    func importedSessionUsesResumeWithDisclosure() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: false, canResume: true)
        client.script(method: "session/resume") { _ in Data("{}".utf8) }

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.agentState == .ready)
        #expect(session.contextRestoreWarning?.canSendTranscript == false)
        #expect(session.contextRestoreWarning?.message.contains("remain in the agent") == true)
        await manager.detach(sessionId: session.id)
    }

    @Test("failed imports never fall back to a new unrelated session")
    func failedImportDoesNotCreateSession() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: true, canResume: false)

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method).contains("session/load"))
        #expect(!client.sent.map(\.method).contains("session/new"))
        if case .failed = session.agentState {
            // Expected.
        } else {
            Issue.record("Imported session should remain failed when its remote load fails")
        }
        #expect(session.remoteSessionId == "remote-id")
    }

    @Test("imports without load or resume fail without issuing a lifecycle request")
    func unsupportedImportDoesNotCreateSession() async throws {
        let (manager, _, client, session) = try fixture(origin: .agentImported)
        scriptInitialize(client, canLoad: false, canResume: false)

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize"])
        #expect(!client.sent.map(\.method).contains("session/new"))
        if case .failed = session.agentState {
            // Expected.
        } else {
            Issue.record("Unsupported imported session should surface a failed state")
        }
    }

    @Test("a foreign SSH mirror takes over and continues the same conversation with a persisted prompt reply", arguments: [ACPSessionOrigin.agentImported, .alasCreated])
    func sshMirrorTakeoverLoadsAndPromptsExistingConversation(origin: ACPSessionOrigin) async throws {
        let endpoint = ReplicaEndpoint()
        let coordinatorA = ACPRemoteSessionCoordinator(owner: .init(serverId: "mac-a", instanceId: "A")) { method, data in
            try await endpoint.request(method, data)
        }
        let coordinatorB = ACPRemoteSessionCoordinator(owner: .init(serverId: "mac-b", instanceId: "B")) { method, data in
            try await endpoint.request(method, data)
        }
        let (a, _, clientA, sessionA) = try fixture(
            origin: origin,
            localMessage: .agent(id: UUID(), StreamingText("Earlier reply")),
            localId: UUID().uuidString,
            instanceId: "A",
            remoteCoordinator: coordinatorA
        )
        let (b, storeB, clientB, sessionB) = try fixture(
            origin: origin,
            localId: UUID().uuidString,
            instanceId: "B",
            remoteCoordinator: coordinatorB
        )
        defer {
            a.shutdownBackgroundTasks()
            b.shutdownBackgroundTasks()
        }
        for client in [clientA, clientB] {
            scriptInitialize(client, canLoad: true, canResume: true)
            scriptSessionResult(client, method: "session/load", sessionId: "remote-id")
        }
        clientA.script(method: "session/resume") { _ in Data("{}".utf8) }
        clientB.scriptAsync(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-id")
            #expect(params.prompt.contains { block in
                if case .text("Continue from the other Mac") = block { return true }
                return false
            })
            clientB.emit(.init(sessionId: "remote-id", update: .agentMessageChunk(.text("Continued on Mac B"))))
            return Data(#"{"stopReason":"end_turn"}"#.utf8)
        }

        await a.hydrateIfNeeded(id: sessionA.id)
        await a.attach(to: sessionA.id, freshlyCreated: false)
        try #require(sessionA.agentState == .ready)
        await a.flushAllPersistence()
        await coordinatorA.flush(sessionId: sessionA.id)
        await b.hydrateIfNeeded(id: sessionB.id)
        await b.attach(to: sessionB.id, freshlyCreated: false)
        try #require(b.isMirror(sessionId: sessionB.id))
        #expect(a.isWriter(for: sessionA.id))
        #expect(clientB.sent.isEmpty)
        try await waitUntil { sessionB.transcript.messages.count == 1 }

        try #require(await b.takeOver(sessionId: sessionB.id))
        _ = await a.heartbeatTick(sessionId: sessionA.id)
        try await waitUntil { sessionB.agentState == .ready }
        #expect(b.isWriter(for: sessionB.id))
        #expect(!b.isMirror(sessionId: sessionB.id))
        #expect(!a.isWriter(for: sessionA.id))
        #expect(a.isMirror(sessionId: sessionA.id))
        #expect(clientB.sent.contains { $0.method == "session/load" })
        #expect(!clientB.sent.contains { $0.method == "session/new" })

        var promptSucceeded: Bool?
        await b.sendPrompt(for: sessionB.id, text: "Continue from the other Mac", attachments: []) {
            promptSucceeded = $0
        }
        try await waitUntil {
            promptSucceeded == true && sessionB.agentState == .ready
                && sessionB.transcript.messages.count == 3
        }
        await b.flushAllPersistence()

        let expected: [ACPMessageWire] = [
            .agent(messageId: nil, text: "Earlier reply", phase: nil, metadata: nil),
            .user(messageId: nil, text: "Continue from the other Mac", attachments: [], delegatedSource: nil),
            .agent(messageId: nil, text: "Continued on Mac B", phase: nil, metadata: nil)
        ]
        let transcript = try sessionB.transcript.messages.map {
            try ACPMessageWire.decode(kind: $0.kind, payload: ACPMessageCodec.encode($0))
        }
        let persisted = try storeB.loadMessages(sessionId: sessionB.id).map {
            try ACPMessageWire.decode(kind: $0.kind, payload: $0.payload)
        }
        #expect(transcript == expected)
        #expect(persisted == expected)
        #expect(try storeB.loadSession(id: sessionB.id)?.remoteSessionId == "remote-id")
        #expect(!clientB.sent.contains { $0.method == "session/new" })
        #expect(b.isWriter(for: sessionB.id))
        #expect(a.isMirror(sessionId: sessionA.id))
        await a.detach(sessionId: sessionA.id)
        await b.detach(sessionId: sessionB.id)
    }

    @Test("SSH context recovery creates a distinct fenced conversation and retains the original history", arguments: [false, true])
    func sshContextRecoveryPreservesOriginalConversation(canResume: Bool) async throws {
        let original = ReplicaEndpoint(recordId: "original"), recovered = ReplicaEndpoint(recordId: "recovered")
        let request: ACPRemoteSessionCoordinator.Request = { method, data in
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let key = object["key"] as? [String: Any]
            let fence = object["fence"] as? [String: Any]
            let record = object["recordId"] as? String ?? fence?["recordId"] as? String
            let endpoint: ReplicaEndpoint
            if let key {
                endpoint = key["remoteSessionId"] as? String == "remote-id" ? original : recovered
            } else {
                endpoint = record == "recovered" ? recovered : original
            }
            return try await endpoint.request(method, data)
        }
        let coordinator = ACPRemoteSessionCoordinator(owner: .init(serverId: "mac-a", instanceId: "A"), request: request)
        let first = ACPMockClient(), next = ACPMockClient()
        scriptInitialize(first, canLoad: true, canResume: canResume)
        first.script(method: canResume ? "session/resume" : "session/load") { _ in
            throw JSONRPCError(code: -32602, message: "conversation unavailable", data: nil)
        }
        scriptInitialize(next, canLoad: true, canResume: true)
        scriptSessionResult(next, method: "session/new", sessionId: "recovered-id")
        next.script(method: "session/prompt") { _ in Data(#"{"stopReason":"end_turn"}"#.utf8) }
        var clients = [first, next]
        let (manager, store, _, session) = try fixture(origin: .alasCreated,
            localMessage: .agent(id: UUID(), StreamingText("Original reply")), instanceId: "A",
            remoteCoordinator: coordinator, connectionFactory: { _, _, _ in ACPConnection(client: clients.removeFirst()) })
        defer { manager.shutdownBackgroundTasks() }
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        try await waitUntil { session.agentState == .ready }
        #expect(manager.isWriter(for: session.id))
        #expect(session.remoteSessionId == "recovered-id")
        #expect(try store.loadSession(id: session.id)?.remoteSessionId == "recovered-id")
        #expect(coordinator.lease(sessionId: session.id)?.recordId == "recovered")
        #expect(!first.sent.contains { $0.method == "session/new" })
        let observeParams = try JSONEncoder().encode(RemoteSessionObserveParams(key: .init(worktreePath: "/tmp/wt", agentId: "claude", remoteSessionId: "remote-id")))
        let oldData = try await original.request("lease/observe", observeParams)
        let old = try JSONDecoder().decode(RemoteSessionObserveResult.self, from: oldData)
        let oldLease = try #require(old.lease)
        #expect(oldLease.owner == nil)
        #expect(oldLease.procId != coordinator.lease(sessionId: session.id)?.procId)
        let mirror = ACPSessionPersistence(path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        try await mirror.upsertSession(.init(id: "original-reader", agentId: "claude", title: "Original", remoteSessionId: "remote-id", currentModel: nil, currentMode: nil, autoRun: false, createdAt: 1, updatedAt: 1, lastOpenedAt: 1, archived: false))
        let reader = ACPRemoteSessionCoordinator(owner: .init(serverId: "mac-b", instanceId: "B"), request: request)
        defer { reader.shutdown() }
        try await reader.syncMirror(sessionId: "original-reader", lease: oldLease, persistence: mirror, isCurrent: { true })
        #expect(try await mirror.mirrorSnapshot(sessionId: "original-reader").wireMessages == [.agent(messageId: nil, text: "Original reply", phase: nil, metadata: nil)])
        await manager.detach(sessionId: session.id)
    }

    private func fixture(
        origin: ACPSessionOrigin,
        localMessage: ACPMessage? = nil,
        localId: String = "local-id",
        instanceId: String = UUID().uuidString,
        remoteCoordinator: ACPRemoteSessionCoordinator? = nil,
        connectionFactory: ACPSessionManager.ACPConnectionFactory? = nil
    ) throws -> (ACPSessionManager, ACPSessionStore, ACPMockClient, ACPSession) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-remote-restore-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: localId,
            agentId: "claude",
            title: "Session",
            titleSource: .generated,
            remoteSessionId: "remote-id",
            origin: origin,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 1,
            lastOpenedAt: 1,
            archived: false
        ))
        if let localMessage {
            // Matches `ACPSessionRunner.persistIndices`'s own id convention
            // (`msg-<sessionId>-<index>`) — a row hydrated under any OTHER
            // id looks, to that same convention, like a DIFFERENT row at
            // this array position, so a live reconciliation that persists
            // the position it resolved to (correctly, since that write is
            // real) creates a duplicate instead of updating this one.
            try store.appendMessage(
                sessionId: localId,
                id: "msg-\(localId)-0",
                kind: localMessage.kind,
                seq: 0,
                payload: ACPMessageCodec.encode(localMessage),
                createdAt: 1
            )
        }
        let client = ACPMockClient()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            instanceId: instanceId,
            remoteHost: remoteCoordinator == nil ? nil : "fixture",
            remoteSessionCoordinator: remoteCoordinator,
            setupEvaluator: { _ in .ready },
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/claude/bin/claude-agent-acp", nodeBinDirectory: ""))
            },
            connectionFactory: connectionFactory ?? { _, _, _ in ACPConnection(client: client) }
        )
        let session = try #require(manager.placeholderSession(id: localId))
        return (manager, store, client, session)
    }

    private func scriptInitialize(
        _ client: ACPMockClient,
        canLoad: Bool,
        canResume: Bool,
        providers: Bool = false
    ) {
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    loadSession: canLoad,
                    sessionCapabilities: .init(resume: canResume ? .init() : nil),
                    providerCapabilities: providers ? .init() : nil
                ),
                authMethods: []
            ))
        }
    }

    private func scriptSessionResult(_ client: ACPMockClient, method: String, sessionId: String) {
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

    /// Polls the condition, so the deadline only bounds a failure. Recovery
    /// runs several agent round trips and SQLite writes, which a loaded CI
    /// shard can stretch well past half a second.
    private func waitUntil(
        timeoutNanos: UInt64 = 10_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanos {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
