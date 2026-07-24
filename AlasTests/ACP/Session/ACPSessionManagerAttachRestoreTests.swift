import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager attach restore")
struct ACPSessionManagerAttachRestoreTests {
    @Test("new session attaches the current project MCP plan")
    func newSessionAttachesCurrentProjectMCPPlan() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        let params = try #require(client.sent.last?.params as? ACPSessionNewParams)
        #expect(params.mcpServers == [.stdio(name: "filesystem", command: "mcp-files", args: [], env: [])])
        let summary = try #require(session.mcpAttachmentSummary)
        #expect(summary.statuses == [.init(id: "0", name: "filesystem", transport: .stdio, disposition: .requested)])
        #expect(summary.configurationFingerprint == MCPAttachmentPlanner.configurationFingerprint(for: configuredServers))
    }

    @Test("local attach uses broker client and persists durable broker state")
    func localAttachUsesBrokerClientAndPersistsDurableState() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let broker = ManagerBrokerService()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )
        let session = manager.createSession(id: "local-session-1", agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        await manager.flushAllPersistence()

        let openParams = try await #require(broker.opened.first)
        #expect(openParams.brokerId == ACPBrokerID(rawValue: "local-local-session-1"))
        #expect(openParams.sessionId == "local-session-1")
        #expect(openParams.command.isEmpty == false)
        #expect(openParams.cwd == "/tmp/wt")
        #expect(openParams.env["PATH"] != nil)
        #expect(await broker.sent.map(\.method) == ["initialize", "session/new"])
        #expect(session.remoteSessionId == "remote-broker")
        #expect(session.agentState == .ready)

        let row = try #require(try store.loadSession(id: "local-session-1"))
        #expect(row.remoteSessionId == "remote-broker")
        #expect(row.acpBrokerId == "local-local-session-1")
        #expect(row.acpBrokerGeneration == 7)
        #expect(row.acpBrokerAcknowledgedCursor == 0)
    }

    @Test("reopened local broker session attaches from persisted cursor")
    func reopenedLocalBrokerSessionAttachesFromPersistedCursor() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(.init(
            id: "local-session-1",
            agentId: "claude",
            title: "Stored session",
            titleSource: .placeholder,
            remoteSessionId: "remote-old",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            acpBrokerId: "broker-existing",
            acpBrokerGeneration: 7,
            acpBrokerAcknowledgedCursor: 4,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        let broker = ManagerBrokerService()
        await broker.setSnapshotResults(
            initializeResult: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object(["resume": .object([:])])
                ]),
                "authMethods": .array([])
            ]),
            remoteSessionResult: .object([
                "sessionId": .string("remote-restored"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        )
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            brokerServiceFactory: { broker }
        )

        let session = try #require(manager.placeholderSession(id: "local-session-1"))
        await manager.hydrateIfNeeded(id: session.id)
        await manager.attach(to: session.id, freshlyCreated: false)
        await manager.flushAllPersistence()

        let openParams = try await #require(broker.opened.first)
        #expect(openParams.brokerId == ACPBrokerID(rawValue: "broker-existing"))
        let attachParams = try await #require(broker.attached.first)
        #expect(attachParams.acknowledgedCursor == ACPBrokerEventCursor(rawValue: 4))
        #expect(await broker.sent.isEmpty)
        #expect(session.remoteSessionId == "remote-restored")
        #expect(session.agentState == .ready)

        let row = try #require(try store.loadSession(id: "local-session-1"))
        #expect(row.acpBrokerId == "broker-existing")
        #expect(row.acpBrokerGeneration == 7)
        #expect(row.acpBrokerAcknowledgedCursor == 4)
    }

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

    @Test("fresh session/new sets a pending MCP preamble when servers attach")
    func freshSessionSetsPendingPreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(session.pendingMCPPreamble?.contains("filesystem") == true)
        #expect(session.mcpPreambleSent == false)
    }

    @Test("loaded session does not reset the MCP preamble")
    func loadedSessionDoesNotResetPreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")
        let configuredServers = [ProjectMCPServer.stdio(name: "filesystem", command: "mcp-files")]
        let manager = manager(store: store, client: client, mcpProjectContextProvider: {
            MCPProjectContext(projectDirectory: "/tmp/project", configuredServers: configuredServers)
        })

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.pendingMCPPreamble == nil)
    }

    @Test("fresh remote session preamble omits built-in but names a surviving user server")
    func freshRemoteSessionPreambleOmitsBuiltInButNamesUserServer() async throws {
        let root = "/srv/task4-remote-preamble-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(mcpCapabilities: .init(http: true)),
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [
            ProjectMCPServer(
                id: UUID().uuidString,
                name: "docs",
                transport: .http(url: "https://mcp.example.com/docs", headers: [])
            )
        ]
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: {
                MCPProjectContext(projectDirectory: root, configuredServers: configuredServers)
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("(built-in)") == false)
        #expect(preamble.contains("docs") == true)
        #expect(session.mcpPreambleSent == false)
    }

    @Test("local attach merges alas CLI env into the launch spec")
    func localAttachMergesCLIEnv() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        var capturedSpec: ACPLaunchSpec?
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { spec, _, _ in
                capturedSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "claude")
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let spec = try #require(capturedSpec)
        #expect(spec.extraEnv["ALAS_SESSION_ID"] == session.id)
        #expect(spec.extraEnv["PATH"] == "/managed/bin:/usr/bin")
        #expect(session.terminalHost.sessionEnv["ALAS_SESSION_ID"] == session.id)
        #expect(session.terminalHost.sessionEnv["PATH"] == "/managed/bin:/usr/bin")
    }

    @Test("remote attach skips alas CLI env")
    func remoteAttachSkipsCLIEnv() async throws {
        let root = "/srv/task3-remote-cli-env-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        var capturedSpec: ACPLaunchSpec?
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { spec, _, _ in
                capturedSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "codex")
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let spec = try #require(capturedSpec)
        #expect(spec.extraEnv["ALAS_SESSION_ID"] == nil)
        #expect(spec.extraEnv["PATH"] != "/managed/bin:/usr/bin")
    }

    @Test("fresh pi attach with CLI env active produces a CLI-mode preamble")
    func freshPiAttachProducesCLIModePreamble() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("alas open"))
        #expect(!preamble.contains("MCP server \"alas\""))
    }

    @Test("local pi attach invokes the external MCP status provider")
    func localPiAttachInvokesExternalMCPStatusProvider() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        var providerCalled = false
        manager.externalMCPStatusProvider = { _ in
            providerCalled = true
            return (adapterState: .installed, configOutcome: .wrote, userServerNames: [], skippedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(providerCalled)
        #expect(session.mcpExternalStatus?.adapterState == .installed)
        #expect(session.mcpExternalStatus?.configOutcome == .wrote)
    }

    @Test("pi attach preamble names http/sse-only servers from the external plan")
    func piAttachPreambleNamesExternalPlanServers() async throws {
        // Regression guard: `wireMCPServers` is planned against pi's real
        // (http/sse-less) ACP capabilities and would drop an http/sse-only
        // server, but `.pi/mcp.json` is written from the external plan's
        // all-transports resolution and DOES include it. The preamble must
        // use the external status's resolved names, not `wireMCPServers`,
        // or it silently omits the `mcp()` hint for exactly the servers
        // this feature exists to surface.
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        manager.alasCLIEnvProvider = { _, sessionId in
            ["ALAS_SESSION_ID": sessionId, "PATH": "/managed/bin:/usr/bin"]
        }
        manager.externalMCPStatusProvider = { _ in
            (adapterState: .installed, configOutcome: .wrote, userServerNames: ["docs-http"], skippedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("docs-http"))
        #expect(preamble.contains("mcp()"))
    }

    @Test("remote pi attach skips the external MCP status provider")
    func remotePiAttachSkipsExternalMCPStatusProvider() async throws {
        let root = "/srv/task5-remote-external-mcp-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/pi/bin/pi-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)
        var providerCalled = false
        manager.externalMCPStatusProvider = { _ in
            providerCalled = true
            return (adapterState: .installed, configOutcome: .wrote, userServerNames: [], skippedServerStatuses: [])
        }

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(!providerCalled)
        #expect(session.mcpExternalStatus?.adapterState == .unknown)
        #expect(session.mcpExternalStatus?.cliActive == false)
        #expect(session.mcpExternalStatus?.configOutcome == nil)
    }

    @Test("remote pi attach preserves configured MCP server names as unavailable")
    func remotePiAttachPreservesConfiguredMCPServerNames() async throws {
        let root = "/srv/task5-remote-external-mcp-names-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let configuredServers = [
            ProjectMCPServer.stdio(name: "linear", command: "linear-mcp")
        ]
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .ready(.init(adapterPath: "/home/dev/.alas/acp/pi/bin/pi-acp", nodeBinDirectory: ""))
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: {
                MCPProjectContext(projectDirectory: root, configuredServers: configuredServers)
            }
        )
        let session = manager.createSession(agentId: ACPLaunchCatalog.spec(for: "pi")!.agentID)

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(session.mcpExternalStatus?.userServerNames == ["linear"])
        #expect(session.mcpExternalStatus?.adapterServerAvailability == .notInstalled)
        #expect(session.mcpExternalStatus?.canInstallAdapterLocally == false)
        let preamble = try #require(session.pendingMCPPreamble)
        #expect(preamble.contains("linear"))
        #expect(preamble.contains("cannot be reached"))
    }

    @Test("Codex-style load response without session id restores normally")
    func codexStyleLoadResponseWithoutSessionIdRestoresNormally() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        client.script(method: "session/load") { _ in
            Data("""
            {
              "models": {
                "currentModelId": "gpt-5",
                "availableModels": []
              },
              "modes": {
                "currentModeId": "default",
                "availableModes": []
              },
              "configOptions": []
            }
            """.utf8)
        }
        client.script(method: "session/new") { _ in
            Issue.record("session/new should not be called when session/load succeeds without a sessionId")
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(client.sent.map(\.method) == ["initialize", "session/load"])
        #expect(session.remoteSessionId == "remote-old")
        #expect(session.currentModel == "gpt-5")
        #expect(session.currentMode == "default")
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.remoteSessionId == "remote-old")
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
        guard case .user(_, _, let text, let attachments, _) = session.transcript.messages[0] else {
            Issue.record("Expected hydrated user message to remain first")
            return
        }
        #expect(text == "look at this")
        #expect(attachments == [
            .init(uri: "file:///tmp/shot.png", name: "shot.png", mimeType: "image/png")
        ])

        client.emit(.init(sessionId: "remote-restored", update: .agentMessageChunk(.text("live follow-up"))))
        try await waitUntil { session.transcript.messages.count == 4 }
        guard case .agent(_, _, let liveText) = session.transcript.messages[3] else {
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

    @Test("mirror refresh syncs generated title metadata")
    func mirrorRefreshSyncsGeneratedTitleMetadata() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(.init(
            id: "local",
            agentId: "claude",
            title: "Old generated",
            titleSource: ACPSessionTitleSource.generated,
            remoteSessionId: "remote-old",
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 0,
            updatedAt: 0,
            lastOpenedAt: 0,
            archived: false
        ))
        var titleCallbacks: [(ACPSession.ID, String)] = []
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            onSessionTitleUpdated: { titleCallbacks.append(($0, $1)) },
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: ACPMockClient()) }
        )

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        #expect(session.title == "Old generated")
        #expect(session.titleSource == ACPSessionTitleSource.generated)

        #expect(try store.updateGeneratedTitleIfNotManual(
            id: "local",
            title: "Adapter Title",
            updatedAt: 10
        ))

        await manager.refreshMirror(sessionId: "local")

        #expect(session.title == "Adapter Title")
        #expect(session.titleSource == .generated)
        #expect(manager.recent.first?.title == "Adapter Title")
        #expect(titleCallbacks.count == 1)
        #expect(titleCallbacks.first?.0 == "local")
        #expect(titleCallbacks.first?.1 == "Adapter Title")
    }

    @Test("fresh attach exposes initializing phase while initialize is pending")
    func freshAttachExposesInitializingPhaseWhileInitializeIsPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "initialize") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: nil,
                authMethods: []
            ))
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == .initializing)

        await gate.release()
        await attachTask.value
        #expect(session.firstRunConnectingPhase == nil)
        #expect(session.agentState == .ready)
    }

    @Test("fresh attach exposes creating session phase while session new is pending")
    func freshAttachExposesCreatingSessionPhaseWhileNewIsPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "session/new") { _ in
            await gate.enterAndWait()
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

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: true) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == .creatingSession)

        await gate.release()
        await attachTask.value
        #expect(session.firstRunConnectingPhase == nil)
        #expect(session.agentState == .ready)
    }

    @Test("restored attach does not expose first-run phase")
    func restoredAttachDoesNotExposeFirstRunPhase() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let client = ACPMockClient()
        scriptInitialize(client)
        let gate = AttachPhaseGate()
        client.scriptAsync(method: "session/load") { _ in
            await gate.enterAndWait()
            return try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-old",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        let manager = manager(store: store, client: client)
        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")

        let attachTask = Task { await manager.attach(to: session.id, freshlyCreated: false) }
        try await waitUntilAsync { await gate.hasEntered }

        #expect(session.firstRunConnectingPhase == nil)

        await gate.release()
        await attachTask.value
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

        guard case .agent(_, _, let text) = session.transcript.messages[0] else {
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
        guard case .user(_, _, let text, _, _) = session.transcript.messages[1] else {
            Issue.record("Expected queued prompt to append after hydrated transcript")
            return
        }
        #expect(text == "queued prompt")
    }

    @Test("load failure falls back to session/new and auto-sends transcript context")
    func loadFailureFallsBackToNewAndAutoSendsTranscriptContext() async throws {
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
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("prior prompt"))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/new", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.remoteSessionId == "remote-new")
        #expect(session.contextRecoveryStatus == .restored)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
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
        try appendMessage(
            .user(id: UUID(), text: "prior prompt", attachments: []),
            to: store,
            seq: 0
        )
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
        #expect(session.contextRecoveryStatus == nil)
        if case .failed(let message) = session.agentState {
            #expect(message == "auth_required: 401")
        } else {
            Issue.record("Expected failed agent state")
        }
    }

    @Test("pending auth method authenticates before creating session")
    func pendingAuthMethodAuthenticatesBeforeSessionCreate() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        client.script(method: "authenticate") { req in
            let params = try #require(req.params as? ACPAuthenticateParams)
            #expect(params.methodId == method.id)
            return Data()
        }
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")
        session.pendingAuthMethodId = method.id

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(client.sent.map(\.method) == ["initialize", "authenticate", "session/new"])
        #expect(session.pendingAuthMethodId == nil)
        #expect(session.agentState == .ready)
    }

    @Test("prompt auth failure removes runner and blocks queue retry on failed connection")
    func promptAuthFailureRemovesRunnerAndBlocksQueueRetryOnFailedConnection() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in
            throw JSONRPCError(code: -32000, message: "login required", data: nil)
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        let runner = try #require(manager.runners[session.id])
        session.enqueue(blocks: [.text("queued")])
        runner.persistQueue()

        runner.flushQueueIfIdle()
        try await waitUntil {
            manager.runners[session.id] == nil
                && session.setupState == .needsAuth(methods: [method], reason: "login required")
        }

        #expect(client.shutdownCount == 1)
        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError == nil)
        #expect(session.transcript.streamingState == .idle)

        session.queue[0].lastError = nil
        manager.persistQueue(for: session)
        manager.runners[session.id]?.flushQueueIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
    }

    @Test("direct auth failure leaves queued follow-up pending")
    func directAuthFailureLeavesQueuedFollowUpPending() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        let gate = AuthPromptFailureGate()
        let method = terminalAuthMethod()
        scriptInitialize(client, authMethods: [method])
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            try await gate.handlePrompt()
        }
        let manager = manager(store: store, client: client)
        let session = manager.createSession(agentId: "claude")

        await manager.attach(to: session.id, freshlyCreated: true)
        let runner = try #require(manager.runners[session.id])
        runner.send(blocks: [.text("first")], intent: .auto)
        try await waitUntilAsync { await gate.hasEntered }
        runner.send(blocks: [.text("follow-up")], intent: .auto)

        await gate.release()
        try await waitUntil {
            manager.runners[session.id] == nil
                && session.setupState == .needsAuth(methods: [method], reason: "login required")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"])
        #expect(session.queue.count == 1)
        #expect(session.queue[0].status == .pending)
        #expect(session.queue[0].lastError == nil)
        #expect(session.queue[0].blocks == [.text("follow-up")])
        #expect(session.transcript.streamingState == .idle)
    }

    @Test("submit while needsAuth rejects prompt and preserves draft")
    func submitWhileNeedsAuthRejectsPromptAndPreservesDraft() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = manager(store: store, client: ACPMockClient())
        let session = manager.createSession(agentId: "claude")
        let method = terminalAuthMethod()
        let draft = ACPComposerDraft(segments: [.text("do not clear me")])
        session.authMethods = [method]
        session.setupState = .needsAuth(methods: [method], reason: "login required")
        session.agentState = .failed("login required")
        session.replaceComposerDraft(draft)
        var completed: Bool?

        let accepted = manager.submit(
            sessionId: session.id,
            text: "do not clear me",
            attachments: [],
            intent: .auto,
            draft: draft
        ) { succeeded in
            completed = succeeded
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(accepted == false)
        #expect(completed == nil)
        #expect(session.queue.isEmpty)
        #expect(session.composerDraft == draft)
        #expect(session.setupState == .needsAuth(methods: [method], reason: "login required"))
    }

    @Test("load fallback automatically sends transcript recovery before queued prompt")
    func loadFallbackAutomaticallySendsTranscriptRecoveryBeforeQueuedPrompt() async throws {
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

        try await waitUntil {
            client.sent.filter { $0.method == "session/prompt" }.count == 2
                && session.queue.isEmpty
        }
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
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

    @Test("load fallback keeps pending fork context out of generic recovery")
    func loadFallbackDefersPendingForkContextUntilFirstPrompt() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        let inherited = try ACPSessionForkSnapshot(
            sourceBoundarySequence: 0,
            messages: [.init(role: .user, text: "Prior context")]
        ).copiedMessages(targetSessionID: "local", createdAt: 0)
        let fork = ACPSessionForkRecord(
            targetSessionID: "local",
            sourceSessionID: "source",
            sourceAgentID: "claude",
            sourceBoundarySequence: 0,
            inheritedMessageCount: 1,
            phase: .ready,
            mechanism: .transcriptTransfer,
            contextDeliveryPending: true
        )
        try store.createFork(session: row(remoteSessionId: "remote-old"), messages: inherited, record: fork)

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

        #expect(client.sent.map(\.method) == ["initialize", "session/load", "session/new"])
        #expect(session.contextRecoveryStatus != .sendingTranscript)
        #expect(session.contextRestoreWarning == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
        #expect(session.forkRecord?.contextDeliveryPending == true)
    }

    @Test("failed automatic transcript recovery keeps queued prompt blocked")
    func failedAutomaticTranscriptRecoveryKeepsQueuedPromptBlocked() async throws {
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
        client.script(method: "session/prompt") { _ in
            throw ACPClientError.noScript(method: "session/prompt")
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            session.contextRecoveryStatus == .failed("Transcript recovery failed.")
                && session.transcript.streamingState == .idle
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.sent.filter { $0.method == "session/prompt" }.count == 1)
        #expect(session.queue.count == 1)
        #expect(session.queue.first?.status == .pending)
        #expect(session.queue.first?.lastError == nil)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == true)
    }

    @Test("missing remote id falls back to session/new without warning for empty session")
    func missingRemoteIdFallsBackToNewWithoutWarningForEmptySession() async throws {
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
        #expect(session.contextRestoreWarning == nil)
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("missing remote id warns and sends transcript recovery for nonempty session")
    func missingRemoteIdWarnsAndSendsTranscriptRecoveryForNonemptySession() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: nil))
        try appendMessage(
            .user(id: UUID(), text: "Recover this context", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        client.script(method: "session/prompt") { _ in Data("null".utf8) }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/new", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.remoteSessionId == "remote-new")
        #expect(session.contextRecoveryStatus == .restored)
        let prompt = try #require(client.sent.last?.params as? ACPSessionPromptParams)
        let block = try #require(prompt.prompt.first)
        guard case .text(let recovery) = block else {
            Issue.record("Expected recovery prompt")
            return
        }
        #expect(recovery.contains("Recover this context"))
        let row = try #require(try store.loadSession(id: "local"))
        #expect(row.remoteSessionId == "remote-new")
        #expect(!row.contextRecoveryPending)
    }

    @Test("pending context recovery auto-sends after restart")
    func pendingContextRecoveryAutoSendsAfterRestart() async throws {
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
        client.script(method: "session/prompt") { request in
            let params = try #require(request.params as? ACPSessionPromptParams)
            #expect(params.sessionId == "remote-new")
            let block = try #require(params.prompt.first)
            guard case .text(let text) = block else {
                Issue.record("Expected text prompt block")
                return Data("null".utf8)
            }
            #expect(text.contains("Context before restart"))
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)

        try await waitUntil {
            client.sent.map(\.method) == ["initialize", "session/load", "session/prompt"]
                && session.contextRestoreWarning == nil
        }
        #expect(session.contextRecoveryStatus == .restored)
        #expect(try store.loadSession(id: "local")?.contextRecoveryPending == false)
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

    @Test("remote managed adapter absence maps to needs setup")
    func remoteManagedAdapterAbsenceMapsToNeedsSetup() async throws {
        let root = "/srv/task4-missing-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .missing(reason: "codex-acp is not installed on devbox.")
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .needsSetup(reason: "codex-acp is not installed on devbox."))
        #expect(session.agentState == .failed("codex-acp is not installed on devbox."))
    }

    @Test("remote prerequisite failure maps to setup error")
    func remotePrerequisiteFailureMapsToSetupError() async throws {
        let root = "/srv/task4-error-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, _, _ in
                .error(message: "Node.js and npm are unavailable.")
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: false)

        #expect(session.setupState == .setupError(reason: "Node.js and npm are unavailable."))
        #expect(session.agentState == .failed("Node.js and npm are unavailable."))
    }

    @Test("remote setup resolution is reused for absolute launch")
    func remoteSetupResolutionIsReusedForAbsoluteLaunch() async throws {
        let root = "/srv/task4-ready-\(UUID().uuidString)"
        RemoteHostRegistry.shared.register(root: root, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root) }
        let store = try ACPSessionStore(path: tmpStorePath())
        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/new", sessionId: "remote-new")
        final class Capture {
            var resolverCalls = 0
            var launchSpec: ACPLaunchSpec?
        }
        let capture = Capture()
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: root,
            store: store,
            remoteAdapterResolver: { _, descriptor, _ in
                capture.resolverCalls += 1
                #expect(descriptor == .codex)
                return .ready(.init(
                    adapterPath: "/home/dev/.alas/acp/codex/bin/codex-acp",
                    nodeBinDirectory: "/home/dev/node/v22/bin"
                ))
            },
            connectionFactory: { spec, host, _ in
                #expect(host == "devbox")
                capture.launchSpec = spec
                return ACPConnection(client: client)
            }
        )
        let session = manager.createSession(agentId: "codex")

        await manager.attach(to: session.id, freshlyCreated: true)

        #expect(capture.resolverCalls == 1)
        #expect(capture.launchSpec?.command == "/home/dev/.alas/acp/codex/bin/codex-acp")
        #expect(capture.launchSpec?.remoteNodeBinDirectory == "/home/dev/node/v22/bin")
        #expect(session.setupState == .ready)
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
        try store.setContextRecoveryPending(sessionId: "local", pending: true)
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

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
        #expect(session.contextRecoveryStatus == .failed("Transcript recovery failed."))
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

    @Test("recovery context superseded by a steer clears the restoring status")
    func recoveryContextSupersededBySteerClearsStatus() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let recoveryGate = PromptGate()
        let steerGate = PromptGate()
        let promptCount = PromptCounter()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        // Gate the first (recovery) prompt so it stays in flight while the
        // user steers, and hold the steer's replacement prompt so it still
        // owns the transport when the recovery RPC finally returns.
        client.scriptAsync(method: "session/prompt") { _ in
            switch await promptCount.next() {
            case 1: await recoveryGate.waitInPrompt()
            case 2: await steerGate.waitInPrompt()
            default: break
            }
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        #expect(session.contextRecoveryStatus == .sendingTranscript)
        try await waitUntilAsync { await recoveryGate.hasEntered }

        // User steers a new prompt while the recovery context is still in
        // flight — the steer's replacement prompt takes over the transport.
        runner.steer(blocks: [.text("actually do this instead")])
        try await waitUntilAsync { await steerGate.hasEntered }

        // The recovery RPC now returns, superseded by the steer. The
        // "Restoring…" spinner must resolve rather than strand forever.
        await recoveryGate.release()
        try await waitUntil { session.contextRecoveryStatus != .sendingTranscript }

        await steerGate.release()
    }

    @Test("recovery context superseded by a newer prompt clears the restoring status")
    func recoveryContextSupersededByNewerPromptClearsStatus() async throws {
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-new"))
        try appendMessage(
            .user(id: UUID(), text: "What changed?", attachments: []),
            to: store,
            seq: 0
        )
        let client = ACPMockClient()
        let recoveryGate = PromptGate()
        let newerPromptGate = PromptGate()
        let promptCount = PromptCounter()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-new")
        client.scriptAsync(method: "session/prompt") { _ in
            switch await promptCount.next() {
            case 1: await recoveryGate.waitInPrompt()
            case 2: await newerPromptGate.waitInPrompt()
            default: break
            }
            return Data("null".utf8)
        }
        let manager = manager(store: store, client: client)

        let session = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        await manager.attach(to: session.id, freshlyCreated: false)
        let runner = try #require(manager.runners[session.id])
        session.contextRestoreWarning = .init(
            message: "Agent context could not be restored.",
            canSendTranscript: true
        )

        #expect(manager.sendTranscriptAsContext(sessionId: session.id, agentName: "Agent"))
        #expect(session.contextRecoveryStatus == .sendingTranscript)
        try await waitUntilAsync { await recoveryGate.hasEntered }

        runner.sendNow(blocks: [.text("actually do this instead")], queuedItemId: nil)
        try await waitUntilAsync { await newerPromptGate.hasEntered }

        await recoveryGate.release()
        try await waitUntil { session.contextRecoveryStatus != .sendingTranscript }

        await newerPromptGate.release()
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

    @Test("attach waits for tail-first hydration backfill before runner setup")
    func attachWaitsForBackfill() async throws {
        // Persist enough messages that hydration splits into a tail-first
        // apply + background backfill — otherwise the bug being guarded
        // against (runner constructed against a partial transcript) can't
        // even materialise.
        let store = try ACPSessionStore(path: tmpStorePath())
        try store.upsertSession(row(remoteSessionId: "remote-old"))
        let total = ACPTranscript.tailWindow * 3
        for i in 0..<total {
            try appendMessage(
                .user(id: UUID(), text: "m\(i)", attachments: []),
                to: store, seq: Int64(i))
        }

        let client = ACPMockClient()
        scriptInitialize(client)
        scriptSessionResult(client, method: "session/load", sessionId: "remote-restored")

        // Capture the in-memory transcript length at the moment attach decides
        // setup is ready. With the fix in place, attach awaits backfill first,
        // so the captured count matches the full persisted length. Without
        // the fix, only the tail window has been applied.
        final class Captured { var count: Int = -1 }
        let captured = Captured()
        let mgrBox: UnsafeMutablePointer<ACPSessionManager?> = .allocate(capacity: 1)
        mgrBox.initialize(to: nil)
        defer { mgrBox.deinitialize(count: 1)
        mgrBox.deallocate() }
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in
                captured.count = mgrBox.pointee?.sessions["local"]?.transcript.messages.count ?? -2
                return .ready
            },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        mgrBox.pointee = manager

        _ = try #require(manager.placeholderSession(id: "local"))
        await manager.hydrateIfNeeded(id: "local")
        // Sanity check: hydrateIfNeeded returned with only the tail applied.
        #expect(manager.sessions["local"]?.transcript.messages.count == ACPTranscript.tailWindow)

        await manager.attach(to: "local", freshlyCreated: false)

        #expect(captured.count == total,
                "setup evaluator must observe the fully-materialised transcript")
        #expect(manager.sessions["local"]?.transcript.messages.count == total)
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

    private func manager(
        store: ACPSessionStore,
        client: ACPMockClient,
        mcpProjectContextProvider: ACPSessionManager.MCPProjectContextProvider? = nil
    ) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) },
            mcpProjectContextProvider: mcpProjectContextProvider
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

    private actor AttachPhaseGate {
        private var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func enterAndWait() async {
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

    private actor PromptCounter {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor AuthPromptFailureGate {
        private var entered = false
        private var released = false
        private var attempts = 0
        private var continuation: CheckedContinuation<Void, Never>?

        var hasEntered: Bool { entered }

        func handlePrompt() async throws -> Data {
            attempts += 1
            guard attempts == 1 else {
                return Data("null".utf8)
            }
            if !released {
                entered = true
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
            throw JSONRPCError(code: -32000, message: "login required", data: nil)
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private actor ManagerBrokerService: ACPBrokerServicing {
    var opened: [ACPBrokerOpenParams] = []
    var attached: [ACPBrokerAttachParams] = []
    var sent: [ACPBrokerSendParams] = []
    var notified: [ACPBrokerNotifyParams] = []
    var responded: [ACPBrokerRespondParams] = []
    var acks: [ACPBrokerAckParams] = []
    var detached: [ACPBrokerDetachParams] = []
    var closed: [ACPBrokerCloseParams] = []
    var snapshotInitializeResult: ACPBrokerJSONValue?
    var snapshotRemoteSessionResult: ACPBrokerJSONValue?

    func setSnapshotResults(
        initializeResult: ACPBrokerJSONValue?,
        remoteSessionResult: ACPBrokerJSONValue?
    ) {
        snapshotInitializeResult = initializeResult
        snapshotRemoteSessionResult = remoteSessionResult
    }

    func open(_ params: ACPBrokerOpenParams) async throws -> ACPBrokerOpenResult {
        opened.append(params)
        return ACPBrokerOpenResult(snapshot: snapshot(params: params), adopted: false)
    }

    func attach(_ params: ACPBrokerAttachParams) async throws -> ACPBrokerAttachResult {
        attached.append(params)
        return ACPBrokerAttachResult(
            snapshot: snapshot(brokerId: params.brokerId, acknowledgedCursor: params.acknowledgedCursor),
            events: []
        )
    }

    func send(_ params: ACPBrokerSendParams) async throws -> ACPBrokerSendResult {
        sent.append(params)
        let result: ACPBrokerJSONValue
        switch params.method {
        case "initialize":
            result = .object([
                "protocolVersion": .number(1),
                "authMethods": .array([])
            ])
        case "session/new":
            result = .object([
                "sessionId": .string("remote-broker"),
                "availableModels": .array([]),
                "availableModes": .array([]),
                "promptSuggestions": .array([]),
                "configOptions": .array([])
            ])
        default:
            throw ACPClientError.noScript(method: params.method)
        }
        return ACPBrokerSendResult(
            requestId: ACPBrokerAdapterRequestID(rawValue: UInt64(sent.count)),
            replayed: false,
            result: result,
            pending: nil
        )
    }

    func notify(_ params: ACPBrokerNotifyParams) async throws -> ACPBrokerSimpleOK {
        notified.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func respond(_ params: ACPBrokerRespondParams) async throws -> ACPBrokerSimpleOK {
        responded.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func ack(_ params: ACPBrokerAckParams) async throws -> ACPBrokerSimpleOK {
        acks.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func detach(_ params: ACPBrokerDetachParams) async throws -> ACPBrokerSimpleOK {
        detached.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    func close(_ params: ACPBrokerCloseParams) async throws -> ACPBrokerSimpleOK {
        closed.append(params)
        return ACPBrokerSimpleOK(ok: true)
    }

    private func snapshot(params: ACPBrokerOpenParams) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: params.brokerId,
                generation: ACPBrokerGeneration(rawValue: 7),
                alasSessionId: params.sessionId,
                adapterProgram: params.command,
                adapterArgs: params.args,
                cwd: params.cwd,
                envKeys: params.env.keys.sorted(),
                createdAtMillis: 10
            ),
            initializeResult: snapshotInitializeResult,
            remoteSessionResult: snapshotRemoteSessionResult,
            turnState: .idle,
            acknowledgedCursor: ACPBrokerEventCursor(rawValue: 0),
            journalTail: ACPBrokerEventCursor(rawValue: 0),
            pendingRequests: [],
            operations: []
        )
    }

    private func snapshot(
        brokerId: ACPBrokerID,
        acknowledgedCursor: ACPBrokerEventCursor
    ) -> ACPBrokerSnapshot {
        ACPBrokerSnapshot(
            metadata: ACPBrokerMetadata(
                brokerId: brokerId,
                generation: ACPBrokerGeneration(rawValue: 7),
                alasSessionId: "local-session-1",
                adapterProgram: "mock",
                adapterArgs: [],
                cwd: "/tmp/wt",
                envKeys: [],
                createdAtMillis: 10
            ),
            initializeResult: snapshotInitializeResult,
            remoteSessionResult: snapshotRemoteSessionResult,
            turnState: .idle,
            acknowledgedCursor: acknowledgedCursor,
            journalTail: ACPBrokerEventCursor(rawValue: 0),
            pendingRequests: [],
            operations: []
        )
    }
}
