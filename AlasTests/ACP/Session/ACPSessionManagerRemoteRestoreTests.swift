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

    private func fixture(
        origin: ACPSessionOrigin,
        localMessage: ACPMessage? = nil
    ) throws -> (ACPSessionManager, ACPSessionStore, ACPMockClient, ACPSession) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-remote-restore-\(UUID().uuidString).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(
            id: "local-id",
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
            try store.appendMessage(
                sessionId: "local-id",
                id: "message-0",
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
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = try #require(manager.placeholderSession(id: "local-id"))
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

    private func waitUntil(
        timeoutNanos: UInt64 = 500_000_000,
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
