import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager attach restore")
struct ACPSessionManagerAttachRestoreTests {
    @Test("reopened session uses session/load")
    func reopenedSessionUsesLoad() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let methods = client.sent.map(\.method)
        #expect(methods == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-restored")
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-restored")
    }

    @Test("replayed load history is ignored when a session is already hydrated")
    func replayedLoadHistoryIgnoredWhenHydrated() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(
                id: UUID(),
                text: "look at this",
                attachments: [
                    .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")
                ]
            ),
            to: store,
            seq: 0
        )
        try appendMessage(
            .agent(id: UUID(), StreamingText("the image looks good")),
            to: store,
            seq: 1
        )
        try appendMessage(
            .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: "done"
            )),
            to: store,
            seq: 2
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        client.scriptAsync(method: "session/load") { _ in
            client.emit(.init(sessionId: "remote-old", update: .userMessageChunk(.text("look at this"))))
            client.emit(.init(sessionId: "remote-old", update: .agentMessageChunk(.text("the image looks good"))))
            client.emit(.init(sessionId: "remote-old", update: .toolCall(.init(
                toolCallId: "tool-1",
                title: "Read file",
                kind: "read",
                status: "completed",
                content: [.content(.text("done"))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ))))
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-restored",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/prompt") { _ in
            client.emit(.init(sessionId: "remote-restored", update: .agentMessageChunk(.text("prompt response"))))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        #expect(session.transcript.messages.count == 3)

        await manager.attach(to: session.id, freshlyCreated: false)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.yieldedUpdateCount == 3)
        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.transcript.messages.count == 3)
        #expect(try store.loadMessages(sessionId: "local").count == 3)
        guard case .user(_, let text, let attachments) = session.transcript.messages[0] else {
            Issue.record("Expected hydrated user message to remain first")
            return
        }
        #expect(text == "look at this")
        #expect(attachments == [
            .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")
        ])

        client.emit(.init(sessionId: "remote-restored", update: .agentMessageChunk(.text("live follow-up"))))
        try await waitUntil { session.transcript.messages.count == 4 }
        guard case .agent(_, let liveText) = session.transcript.messages[3] else {
            Issue.record("Expected post-load live update to be applied")
            return
        }
        #expect(liveText.value == "live follow-up")

        let runner = try #require(manager.runners[session.id])
        var delivered: Bool?
        runner.send(text: "next prompt", attachments: []) { succeeded in
            delivered = succeeded
        }
        try await waitUntil {
            delivered == true
                && session.transcript.streamingState == .idle
                && session.transcript.messages.count == 6
        }
    }

    @Test("fresh session keeps updates emitted during session new")
    func freshSessionKeepsUpdatesEmittedDuringNew() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        client.scriptAsync(method: "session/new") { _ in
            client.emit(.init(sessionId: "remote-new", update: .agentMessageChunk(.text("welcome"))))
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-new",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        try await waitUntil { session.transcript.messages.count == 1 }

        guard case .agent(_, let text) = session.transcript.messages[0] else {
            Issue.record("Expected fresh session update to be applied")
            return
        }
        #expect(text.value == "welcome")
    }

    @Test("non-replaying load still flushes queued prompt")
    func nonReplayingLoadStillFlushesQueuedPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "prior prompt", attachments: []),
            to: store,
            seq: 0
        )
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-restored")
            #expect(params.prompt == [.text("queued prompt")])
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"]
                && session.queue.isEmpty
        }
        #expect(session.transcript.messages.count == 2)
        guard case .user(_, let text, _) = session.transcript.messages[1] else {
            Issue.record("Expected queued prompt to append after hydrated transcript")
            return
        }
        #expect(text == "queued prompt")
    }

    @Test("load failure falls back to session/new with transcript warning")
    func loadFailureFallsBackToNewWithWarning() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let priorPrompt: ACPMessage = .user(id: UUID(), text: "prior prompt", attachments: [])
        try store.appendMessage(
            sessionId: "local", id: "m0", kind: priorPrompt.kind, seq: 0,
            payload: ACPMessageCodec.encode(priorPrompt), createdAt: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let methods = client.sent.map(\.method)
        #expect(methods == ["initialize", "session/load", "session/new"])
        #expect(session.remoteSessionId == "remote-new")
        let warning = try #require(session.contextRestoreWarning)
        #expect(warning.canSendTranscript)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(row.contextRecoveryPending)
    }

    @Test("new auth failure enters needsAuth with initialized auth method")
    func newAuthFailureEntersNeedsAuthWithInitializedAuthMethod() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "Internal error: 401 Unauthorized", data: nil)
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "session/new"])
        #expect(session.authMethods == [method])
        #expect(session.setupState == .needsAuth(methods: [method], reason: "401 Unauthorized"))
        #expect(session.lastError?.contains("401 Unauthorized") == true)
        #expect(manager.runners[session.id] == nil)
        if case .failed(let message) = session.agentState {
            #expect(message == "401 Unauthorized")
        } else {
            Issue.record("Expected failed agent state")
        }
    }

    @Test("load auth failure does not fall back to session new")
    func loadAuthFailureDoesNotFallBackToSessionNew() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32000, message: "auth_required: 401", data: nil)
        }
        client.script(method: "session/new") { _ in
            Issue.record("session/new should not be called after auth-related session/load failure")
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.authMethods == [method])
        #expect(session.setupState == .needsAuth(methods: [method], reason: "auth_required: 401"))
        #expect(session.lastError?.contains("auth_required: 401") == true)
        if case .failed(let message) = session.agentState {
            #expect(message == "auth_required: 401")
        } else {
            Issue.record("Expected failed agent state")
        }
    }

    @Test("pending queued prompt waits for transcript recovery after load fallback")
    func queuedPromptWaitsForTranscriptRecoveryAfterLoadFallback() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        try appendMessage(
            .user(id: UUID(), text: "Prior context", attachments: []),
            to: store,
            seq: 0
        )
        try store.upsertQueue(sessionId: "local", items: [
            QueuedPrompt(blocks: [.text("queued prompt")])
        ])
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/new"])
        #expect(session.queue.count == 1)
        #expect(session.contextRestoreWarning?.canSendTranscript == true)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == true)

        let accepted = manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent")

        #expect(accepted)
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.queue.isEmpty
                && session.contextRestoreWarning == nil
        }
        let prompts = client.sent.compactMap { $0.params as? ACPSessionPromptParams }
        #expect(prompts.count == 2)
        let firstBlock = try #require(prompts.first?.prompt.first)
        guard case .text(let recovery) = firstBlock else {
            Issue.record("Expected transcript recovery prompt first")
            return
        }
        #expect(recovery.contains("Prior context"))
        #expect(prompts.last?.prompt == [.text("queued prompt")])
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
    }

    @Test("missing remote id falls back to session/new with no-transcript warning")
    func missingRemoteIdFallsBackToNewWithWarning() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: nil))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        let methods = client.sent.map(\.method)
        #expect(methods == ["initialize", "session/new"])
        #expect(session.remoteSessionId == "remote-new")
        let warning = try #require(session.contextRestoreWarning)
        #expect(!warning.canSendTranscript)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("pending context recovery survives restart after fallback remote id is persisted")
    func pendingContextRecoverySurvivesRestart() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        try appendMessage(
            .user(id: UUID(), text: "Context before restart", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        let warning = try #require(session.contextRestoreWarning)
        #expect(warning.canSendTranscript)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == true)
    }

    @Test("attach retry clears stale warning before setup failure")
    func attachRetryClearsStaleWarningBeforeSetupFailure() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .missing(reason: "missing") }
        )
        let session = manager.createSession(agentId: "claude")
        session.contextRestoreWarning = .init(
            message: "old warning",
            canSendTranscript: true
        )

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .needsSetup(reason: "missing"))
        #expect(session.agentState == .failed("missing"))
        #expect(session.contextRestoreWarning == nil)
    }

    @Test("load failure followed by new failure leaves stale warning cleared")
    func loadFailureFollowedByNewFailureLeavesStaleWarningCleared() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            throw JSONRPCError(code: -32601, message: "Method not found", data: nil)
        }
        client.script(method: "session/new") { _ in
            throw JSONRPCError(code: -32000, message: "new failed", data: nil)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        session.contextRestoreWarning = .init(
            message: "old warning",
            canSendTranscript: true
        )
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/new"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.contextRestoreWarning == nil)
        if case .failed(let message) = session.agentState {
            #expect(message.contains("new failed"))
        } else {
            Issue.record("Expected failed agent state")
        }
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-old")
    }

    @Test("send transcript context clears warning")
    func sendTranscriptContextClearsWarning() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        try appendMessage(
            .agent(id: UUID(), StreamingText("We changed persistence.")),
            to: store,
            seq: 1
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            #expect(params.prompt.count == 1)
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("The previous agent context for this pane could not be restored."))
            #expect(text.contains("## You\n\nWhat changed?"))
            #expect(text.contains("## Agent\n\nWe changed persistence."))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        let messageCountBefore = session.transcript.messages.count

        let accepted = manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent")

        #expect(accepted)
        try await waitUntil { session.contextRestoreWarning == nil }
        #expect(session.transcript.messages.count == messageCountBefore)
        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"])
    }

    @Test("send transcript context clears persisted recovery pending flag")
    func sendTranscriptContextClearsPersistedPendingFlag() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.contextRestoreWarning?.canSendTranscript == true)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        try await waitUntil { session.contextRestoreWarning == nil }
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
    }

    @Test("failed transcript context send keeps warning and transcript")
    func failedTranscriptContextSendKeepsWarningAndTranscript() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in
            throw ACPClientError.noScript(method: "session/prompt")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let warning = ACPSession.ContextRestoreWarning(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        session.contextRestoreWarning = warning
        let messageCountBefore = session.transcript.messages.count

        let accepted = manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent")

        #expect(accepted)
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 1
                && session.transcript.streamingState == .idle
        }
        #expect(session.contextRestoreWarning == warning)
        #expect(session.transcript.messages.count == messageCountBefore)
    }

    @Test("cancelled recovery context send reports not delivered")
    func cancelledRecoveryContextSendReportsNotDelivered() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let gate = PromptGate()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            await gate.waitInPrompt()
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        let warning = ACPSession.ContextRestoreWarning(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )
        session.contextRestoreWarning = warning
        var delivered: Bool?

        runner.sendRecoveryContext("recovery context") { result in
            delivered = result
        }
        try await waitUntilAsync { await gate.hasEntered }
        await runner.userCancel()
        await gate.release()
        try await waitUntil { delivered != nil }
        #expect(delivered == false)
        #expect(session.transcript.streamingState == .idle)
        #expect(session.contextRestoreWarning == warning)
    }

    @Test("recovery context completion drains queued prompt")
    func recoveryContextCompletionDrainsQueuedPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let gate = PromptGate()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            await gate.waitInPrompt()
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])

        runner.sendRecoveryContext("recovery context")
        try await waitUntilAsync { await gate.hasEntered }
        runner.send(blocks: [.text("normal prompt")], intent: .auto)

        #expect(session.queue.count == 1)
        await gate.release()
        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.queue.isEmpty
                && session.transcript.streamingState == .idle
        }

        let prompts = client.sent.filter { $0.method == "session/prompt" }
        let second = try #require(prompts.last?.params as? ACPSessionPromptParams)
        #expect(second.prompt == [.text("normal prompt")])
    }

    @Test("transcript context prompt requires conversation")
    func transcriptContextPromptRequiresConversation() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        session.appendSystemNotice("Agent context could not be restored.")

        #expect(manager.transcriptContextPrompt(for: session, agentName: "Agent") == nil)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent") == false)
    }

    @Test("send transcript context rejects unavailable states")
    func sendTranscriptContextRejectsUnavailableStates() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp/wt", store: store)
        let session = manager.createSession(agentId: "claude")
        session.recordUserPrompt(text: "What changed?", attachments: [])

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.contextRestoreWarning = .init(message: "warning", canSendTranscript: false)
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.contextRestoreWarning = .init(message: "warning", canSendTranscript: true)
        session.agentState = .ready
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.transcript.streamingState = .streaming
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)

        session.transcript.streamingState = .idle
        session.enqueue(blocks: [.text("queued")])
        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: nil) == false)
    }

    private func tmpStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mgr-attach-restore-\(UUID()).sqlite").path
    }

    private func appendMessage(
        _ message: ACPMessage,
        to store: ACPSessionStore,
        seq: Int64
    ) throws {
        try store.appendMessage(
            sessionId: "local",
            id: "m\(seq)",
            kind: message.kind,
            seq: seq,
            payload: ACPMessageCodec.encode(message),
            createdAt: seq
        )
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
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilAsync(
        timeoutNanos: UInt64 = 500_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanos {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func row(remoteSessionId: String?) -> ACPSessionRow {
        ACPSessionRow(
            id: "local",
            agentId: "claude",
            title: "Stored session",
            titleSource: .placeholder,
            remoteSessionId: remoteSessionId,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        )
    }

    private func manager(store: ACPSessionStore, client: ACPMockClient) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _ in ACPConnection(client: client) }
        )
    }

    private func scriptInitialize(
        _ client: ACPMockClient,
        authMethods: [ACPInitializeResult.ACPAuthMethod] = []
    ) {
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: authMethods
            ))
        }
    }

    private func terminalAuthMethod() -> ACPInitializeResult.ACPAuthMethod {
        ACPInitializeResult.ACPAuthMethod(
            id: "claude-login",
            name: "Claude Login",
            kind: .terminal
        )
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

    private actor PromptGate {
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func waitInPrompt() async {
            if released { return }
            entered = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}
