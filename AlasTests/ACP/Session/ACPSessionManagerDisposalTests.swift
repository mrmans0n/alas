import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSessionManager disposal")
struct ACPSessionManagerDisposalTests {
    private enum TestError: Error { case closeFailed }

    @Test("supported attached disposal closes once and keeps the persisted session resumable")
    func supportedDisposalClosesAndPreservesPersistence() async throws {
        let client = ACPMockClient()
        let resumeClient = ACPMockClient()
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        let (manager, store, session) = try await attachedManager(
            client: client,
            supportsClose: true,
            resumeClient: resumeClient
        )

        try await manager.disposeSession(id: session.id)
        await manager.flushPersistence()

        #expect(client.sent.map(\.method).filter { $0 == "session/close" }.count == 1)
        #expect(manager.runners[session.id] == nil)
        #expect(try store.loadSession(id: session.id)?.remoteSessionId == "remote")

        let restored = try #require(manager.placeholderSession(id: session.id))
        await manager.attach(to: restored.id, freshlyCreated: false)
        #expect(resumeClient.sent.contains { $0.method == "session/resume" })
        #expect(manager.runners[restored.id] != nil)
        await manager.detach(sessionId: restored.id)
    }

    @Test("unsupported and disconnected sessions do not close remotely")
    func unsupportedAndDisconnectedSessionsDoNotClose() async throws {
        let unsupportedClient = ACPMockClient()
        let (unsupportedManager, _, unsupportedSession) = try await attachedManager(
            client: unsupportedClient,
            supportsClose: false
        )
        try await unsupportedManager.disposeSession(id: unsupportedSession.id)

        let disconnectedClient = ACPMockClient()
        let (disconnectedManager, _, disconnectedSession) = try await attachedManager(
            client: disconnectedClient,
            supportsClose: true
        )
        disconnectedSession.agentState = .disconnected
        try await disconnectedManager.disposeSession(id: disconnectedSession.id)

        #expect(!unsupportedClient.sent.contains { $0.method == "session/close" })
        #expect(!disconnectedClient.sent.contains { $0.method == "session/close" })
    }

    @Test("duplicate disposal sends at most one close")
    func duplicateDisposalClosesOnce() async throws {
        let client = ACPMockClient()
        let closeStarted = AsyncStream<Void>.makeStream()
        let releaseClose = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/close") { _ in
            closeStarted.continuation.yield()
            for await _ in releaseClose.stream { break }
            return Data("{}".utf8)
        }
        let (manager, _, session) = try await attachedManager(client: client, supportsClose: true)

        let first = Task { @MainActor in try await manager.disposeSession(id: session.id) }
        for await _ in closeStarted.stream { break }
        let second = Task { @MainActor in try await manager.disposeSession(id: session.id) }
        await Task.yield()
        releaseClose.continuation.yield()
        try await first.value
        try await second.value

        #expect(client.sent.map(\.method).filter { $0 == "session/close" }.count == 1)
    }

    @Test("failed close still removes the runner and shuts down the connection")
    func failedCloseStillTearsDown() async throws {
        let client = ACPMockClient()
        client.script(method: "session/close") { _ in throw TestError.closeFailed }
        let (manager, _, session) = try await attachedManager(client: client, supportsClose: true)

        await #expect(throws: TestError.closeFailed) {
            try await manager.disposeSession(id: session.id)
        }

        #expect(manager.runners[session.id] == nil)
        #expect(client.shutdownCount == 1)
    }

    @Test("unresponsive close times out and still tears down")
    func unresponsiveCloseTimesOutAndTearsDown() async throws {
        let client = ACPMockClient()
        client.scriptAsync(method: "session/close") { _ in
            try await Task.sleep(for: .seconds(3))
            return Data("{}".utf8)
        }
        let (manager, _, session) = try await attachedManager(client: client, supportsClose: true)

        await #expect(throws: (any Error).self) {
            try await manager.disposeSession(id: session.id)
        }

        #expect(manager.runners[session.id] == nil)
        #expect(client.shutdownCount == 1)
    }

    @Test("view release and local cache eviction never close a session")
    func viewReleaseAndCacheEvictionDoNotClose() async throws {
        let client = ACPMockClient()
        let (manager, _, session) = try await attachedManager(client: client, supportsClose: true)

        manager.retainSession(id: session.id)
        manager.releaseSession(id: session.id)
        #expect(manager.runners[session.id] != nil)
        #expect(!client.sent.contains { $0.method == "session/close" })

        await manager.detach(sessionId: session.id)
        #expect(manager.liveSession(for: session.id) == nil)
        #expect(!client.sent.contains { $0.method == "session/close" })
    }

    @Test("delete preparation uses disposal before deleting agent history")
    func deletePreparationUsesDisposal() async throws {
        let client = ACPMockClient()
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        let (manager, _, session) = try await attachedManager(client: client, supportsClose: true)

        try await manager.closeActiveSessionForDeletion(
            localSessionId: session.id,
            agentId: session.agentId,
            remoteSessionId: "remote"
        )

        #expect(client.sent.map(\.method).filter { $0 == "session/close" }.count == 1)
        #expect(manager.runners[session.id] == nil)
    }

    @Test("local history deletion disposes an attached session")
    func localHistoryDeletionUsesDisposal() async throws {
        let client = ACPMockClient()
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        let (manager, store, session) = try await attachedManager(client: client, supportsClose: true)

        try await manager.deleteSession(id: session.id)

        #expect(client.sent.map(\.method).filter { $0 == "session/close" }.count == 1)
        #expect(manager.runners[session.id] == nil)
        #expect(try store.loadSession(id: session.id) == nil)
    }

    @Test("disposing while attach waits for providers closes the created remote session")
    func disposalClosesRemoteSessionBeforeRunnerRegistration() async throws {
        let client = ACPMockClient()
        let providersStarted = AsyncStream<Void>.makeStream()
        let releaseProviders = AsyncStream<Void>.makeStream()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    sessionCapabilities: .init(close: .init()),
                    providerCapabilities: .init()
                ),
                authMethods: []
            ))
        }
        client.script(method: "session/new") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.scriptAsync(method: "providers/list") { _ in
            providersStarted.continuation.yield()
            for await _ in releaseProviders.stream { break }
            return Data("{\"providers\":[]}".utf8)
        }
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-disposal-attach-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: path.path)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let session = manager.createSession(agentId: "claude")
        let attach = Task { @MainActor in
            await manager.attach(to: session.id, freshlyCreated: true)
        }
        for await _ in providersStarted.stream { break }

        try await manager.disposeSession(id: session.id)
        releaseProviders.continuation.yield()
        await attach.value

        #expect(client.sent.map(\.method).filter { $0 == "session/close" }.count == 1)
        #expect(client.shutdownCount >= 1)
        #expect(manager.runners[session.id] == nil)
    }

    private func attachedManager(
        client: ACPMockClient,
        supportsClose: Bool,
        resumeClient: ACPMockClient? = nil
    ) async throws -> (ACPSessionManager, ACPSessionStore, ACPSession) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-disposal-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: path.path)
        let clients = resumeClient.map { [client, $0] } ?? [client]
        for client in clients {
            client.script(method: "initialize") { _ in
                try JSONEncoder().encode(ACPInitializeResult(
                    protocolVersion: 1,
                    agentCapabilities: .init(sessionCapabilities: .init(
                        resume: supportsClose ? .init() : nil,
                        close: supportsClose ? .init() : nil
                    )),
                    authMethods: []
                ))
            }
            client.script(method: "session/new") { _ in
                try JSONEncoder().encode(ACPSessionNewResult(
                    sessionId: "remote",
                    availableModels: [],
                    availableModes: [],
                    currentModel: nil,
                    currentMode: nil,
                    promptSuggestions: []
                ))
            }
            client.script(method: "session/resume") { _ in
                try JSONEncoder().encode(ACPSessionNewResult(
                    sessionId: "remote",
                    availableModels: [],
                    availableModes: [],
                    currentModel: nil,
                    currentMode: nil,
                    promptSuggestions: []
                ))
            }
        }
        var connectionIndex = 0
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in
                defer { connectionIndex += 1 }
                return ACPConnection(client: clients[min(connectionIndex, clients.count - 1)])
            }
        )
        let session = manager.createSession(agentId: "claude")
        await manager.attach(to: session.id, freshlyCreated: true)
        _ = try #require(manager.runners[session.id])
        return (manager, store, session)
    }
}
