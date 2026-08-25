import Foundation
import Testing
@testable import Alas

@Suite("ACP session discovery")
struct ACPSessionDiscoveryTests {
    @MainActor
    @Test("unsupported discovery never sends session/delete")
    func unsupportedDeletionIsGated() async throws {
        let store = try temporaryStore()
        let client = discoveryClient(deleteCapability: false)
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        await #expect(throws: ACPSessionDiscoveryError.deletionUnsupported) {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)
        }
        #expect(!client.sent.contains { $0.method == "session/delete" })
    }

    @MainActor
    @Test("remote deletion uses the discovered wire id and refreshes discovery")
    func remoteDeletionRefreshes() async throws {
        let store = try temporaryStore()
        let client = discoveryClient(deleteCapability: true)
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)

        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)
        let request = try #require(client.sent.first { $0.method == "session/delete" })
        #expect(request.params as? ACPSessionDeleteParams == .init(sessionId: "remote-listed"))
        #expect(client.sent.map(\.method).filter { $0 == "session/list" }.count == 2)
        #expect(model.sessions.isEmpty)
    }

    @MainActor
    @Test("remote deletion failure preserves local and discovered history")
    func remoteDeletionFailurePreservesHistory() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "local-1", remoteSessionId: "remote-listed", title: "Local", origin: .alasCreated
        ))
        let client = discoveryClient(deleteCapability: true, deletionError: TestError.failed)
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        await #expect(throws: TestError.failed) {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: true, manager: manager)
        }

        #expect(model.sessions == [session])
        #expect(try store.loadSession(id: "local-1") != nil)
        #expect(client.sent.map(\.method).filter { $0 == "session/list" }.count == 1)
    }

    @MainActor
    @Test("local cleanup can be retried after remote deletion without another destructive request")
    func localCleanupRetryDoesNotRepeatRemoteDeletion() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "local-1", remoteSessionId: "remote-listed", title: "Local", origin: .alasCreated
        ))
        try store.db.exec("""
        CREATE TRIGGER fail_session_delete
        BEFORE DELETE ON sessions
        BEGIN
          SELECT RAISE(ABORT, 'forced local cleanup failure');
        END
        """)
        let client = discoveryClient(deleteCapability: true)
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        await #expect(throws: (any Error).self) {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: true, manager: manager)
        }
        #expect(model.sessions == [session])
        #expect(try store.loadSession(id: "local-1") != nil)
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)

        try store.db.exec("DROP TRIGGER fail_session_delete")
        try await model.removeLocalHistory(for: session, manager: manager)

        #expect(try store.loadSession(id: "local-1") == nil)
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)
        #expect(model.sessions.isEmpty)
    }

    @MainActor
    @Test("local deletion runs after already queued session upserts")
    func localDeletionRunsLastOnPersistenceQueue() async throws {
        let store = try temporaryStore()
        let manager = manager(store: store, client: ACPMockClient())
        let session = manager.createSession(id: "local-1", agentId: "claude")
        manager.renameSession(id: session.id, title: "Queued rename", source: .manual)

        try await manager.deletePersistedSession(id: session.id)
        await manager.flushPersistence()

        #expect(try store.loadSession(id: session.id) == nil)
    }

    @MainActor
    @Test("duplicate deletion is ignored while the first request is in flight")
    func duplicateDeletionIsIgnored() async throws {
        let client = discoveryClient(deleteCapability: true)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/delete") { _ in
            started.continuation.yield()
            for await _ in release.stream { break }
            return Data("{}".utf8)
        }
        let store = try temporaryStore()
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        let first = Task {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)
        }
        for await _ in started.stream { break }
        #expect(model.deletingSessionIds == ["remote-listed"])

        try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)

        release.continuation.yield()
        try await first.value
        #expect(model.deletingSessionIds.isEmpty)
    }

    @MainActor
    @Test("concurrent deletions serialize their discovery refreshes")
    func concurrentDeletionsSerializeRefreshes() async throws {
        let client = discoveryClient(deleteCapability: true)
        var deleted: Set<String> = []
        let firstDeleteStarted = AsyncStream<Void>.makeStream()
        let releaseFirstDelete = AsyncStream<Void>.makeStream()
        client.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(sessions: ["first", "second", "third"]
                .filter { !deleted.contains($0) }
                .map { .init(sessionId: $0, cwd: "/tmp/wt", title: $0) }))
        }
        client.scriptAsync(method: "session/delete") { request in
            let id = try #require(request.params as? ACPSessionDeleteParams).sessionId
            if id == "first" {
                firstDeleteStarted.continuation.yield()
                for await _ in releaseFirstDelete.stream { break }
            }
            deleted.insert(id)
            return Data("{}".utf8)
        }
        let store = try temporaryStore()
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let first = try #require(model.sessions.first { $0.remoteSessionId == "first" })
        let second = try #require(model.sessions.first { $0.remoteSessionId == "second" })
        let third = try #require(model.sessions.first { $0.remoteSessionId == "third" })

        let firstDeletion = Task {
            try await model.deleteAgentHistory(for: first, removeLocalHistory: false, manager: manager)
        }
        for await _ in firstDeleteStarted.stream { break }
        let secondDeletion = Task {
            try await model.deleteAgentHistory(for: second, removeLocalHistory: false, manager: manager)
        }
        let thirdDeletion = Task {
            try await model.deleteAgentHistory(for: third, removeLocalHistory: false, manager: manager)
        }
        await Task.yield()
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)

        releaseFirstDelete.continuation.yield()
        try await firstDeletion.value
        try await secondDeletion.value
        try await thirdDeletion.value

        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 3)
        #expect(model.sessions.isEmpty)
    }

    @MainActor
    @Test("stopping discovery waits for an in-flight deletion")
    func stopWaitsForDeletion() async throws {
        let client = discoveryClient(deleteCapability: true)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/delete") { _ in
            started.continuation.yield()
            for await _ in release.stream { break }
            return Data("{}".utf8)
        }
        let store = try temporaryStore()
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        let deletion = Task {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)
        }
        for await _ in started.stream { break }
        let stop = Task { await model.stop() }
        await Task.yield()
        #expect(client.shutdownCount == 0)

        release.continuation.yield()
        try await deletion.value
        await stop.value
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)
        #expect(client.shutdownCount == 1)
    }

    @MainActor
    @Test("retry after a post-delete list failure replaces the stale row")
    func refreshRetryReplacesStaleRow() async throws {
        let client = discoveryClient(deleteCapability: true)
        var listCall = 0
        client.script(method: "session/list") { _ in
            listCall += 1
            if listCall == 2 { throw TestError.failed }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: listCall == 1
                    ? [.init(sessionId: "remote-listed", cwd: "/tmp/wt", title: "Listed")]
                    : []
            ))
        }
        let store = try temporaryStore()
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let session = try #require(model.sessions.first)

        await #expect(throws: TestError.failed) {
            try await model.deleteAgentHistory(for: session, removeLocalHistory: false, manager: manager)
        }
        #expect(model.sessions == [session])

        try await model.loadMore()
        #expect(model.sessions.isEmpty)
        #expect(client.sent.map(\.method).filter { $0 == "session/delete" }.count == 1)
    }

    @MainActor
    @Test("active adapter session is closed before agent history is deleted")
    func activeSessionClosesBeforeDeletion() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "local-1", remoteSessionId: "remote-listed", title: "Local", origin: .agentImported
        ))
        let client = discoveryClient(deleteCapability: true)
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    loadSession: true,
                    sessionCapabilities: .init(list: .init(), delete: .init())
                ),
                authMethods: []
            ))
        }
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: "remote-listed",
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        let manager = manager(store: store, client: client)
        let local = try #require(manager.placeholderSession(id: "local-1"))
        await manager.attach(to: local.id, freshlyCreated: false)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let listed = try #require(model.sessions.first)
        let discovered = ACPDiscoveredSession(
            worktreeId: listed.worktreeId,
            agentId: listed.agentId,
            remoteSessionId: listed.remoteSessionId,
            cwd: listed.cwd,
            title: listed.title,
            updatedAt: listed.updatedAt,
            additionalDirectories: listed.additionalDirectories,
            localSessionId: nil
        )

        try await model.deleteAgentHistory(
            for: discovered,
            removeLocalHistory: false,
            manager: manager
        )

        let methods = client.sent.map(\.method)
        let closeIndex = try #require(methods.firstIndex(of: "session/close"))
        let deleteIndex = try #require(methods.firstIndex(of: "session/delete"))
        #expect(closeIndex < deleteIndex)
        #expect(manager.runners[local.id] == nil)
    }

    @MainActor
    @Test("active deletion fallback scopes a shared wire id by agent")
    func activeDeletionFallbackScopesAgent() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "claude-local",
            remoteSessionId: "shared-remote",
            title: "Claude",
            origin: .agentImported,
            agentId: "claude"
        ))
        try store.upsertSession(row(
            id: "pi-local",
            remoteSessionId: "shared-remote",
            title: "Pi",
            origin: .agentImported,
            agentId: "pi"
        ))
        let claudeClient = activeSessionClient(remoteSessionId: "shared-remote")
        let piClient = activeSessionClient(remoteSessionId: "shared-remote")
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { spec, _, _ in
                ACPConnection(client: spec.agentID == "pi" ? piClient : claudeClient)
            }
        )
        let claude = try #require(manager.placeholderSession(id: "claude-local"))
        let pi = try #require(manager.placeholderSession(id: "pi-local"))
        await manager.attach(to: claude.id, freshlyCreated: false)
        await manager.attach(to: pi.id, freshlyCreated: false)

        try await manager.closeActiveSessionForDeletion(
            localSessionId: nil,
            agentId: "pi",
            remoteSessionId: "shared-remote"
        )

        #expect(!claudeClient.sent.contains { $0.method == "session/close" })
        #expect(piClient.sent.contains { $0.method == "session/close" })
        #expect(manager.runners[claude.id] != nil)
        #expect(manager.runners[pi.id] == nil)
        await manager.detach(sessionId: claude.id)
    }

    @Test("deletion confirmations name the agent and session and explain retention semantics")
    func deletionConfirmationCopy() {
        let session = ACPDiscoveredSession(
            worktreeId: "wt",
            agentId: "pi",
            remoteSessionId: "remote-listed",
            cwd: "/tmp/wt",
            title: "Fix parser",
            updatedAt: nil,
            additionalDirectories: [],
            localSessionId: "local-1"
        )
        let remote = ACPSessionDeletionRequest(kind: .agentHistory, agentName: "Pi", session: session)
        #expect(remote.title.contains("Pi"))
        #expect(remote.title.contains("Fix parser"))
        #expect(remote.message.contains("soft or permanent"))
        #expect(remote.message.contains("no undo"))

        let local = ACPSessionDeletionRequest(kind: .localOnly, agentName: "Pi", session: session)
        #expect(local.message.contains("Only Alas’s local record"))
        #expect(local.message.contains("remains in Pi’s history"))
    }

    @Test("restore policy prefers resume locally and strict load for imported sessions")
    func restorePolicy() {
        #expect(ACPSessionRestorePolicy.operation(
            origin: .alasCreated, canLoad: true, canResume: true
        ) == .resume)
        #expect(ACPSessionRestorePolicy.operation(
            origin: .alasCreated, canLoad: false, canResume: false
        ) == .loadWithRecovery)
        #expect(ACPSessionRestorePolicy.operation(
            origin: .agentImported, canLoad: true, canResume: true
        ) == .loadStrict)
        #expect(ACPSessionRestorePolicy.operation(
            origin: .agentImported,
            canLoad: true,
            canResume: true,
            hasLocalTranscript: true
        ) == .resume)
        #expect(ACPSessionRestorePolicy.operation(
            origin: .agentForked, canLoad: false, canResume: true
        ) == .resume)
        #expect(ACPSessionRestorePolicy.operation(
            origin: .agentImported, canLoad: false, canResume: false
        ) == .unavailable)
    }

    @MainActor
    @Test("discovery filters by cwd, deduplicates local rows, and paginates on one connection")
    func discoveryMergeAndPagination() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "local-1",
            remoteSessionId: "remote-1",
            title: "Local title",
            origin: .alasCreated
        ))
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    loadSession: true,
                    sessionCapabilities: .init(list: .init(), resume: .init())
                ),
                authMethods: []
            ))
        }
        client.script(method: "session/list") { request in
            let params = try #require(request.params as? ACPSessionListParams)
            if params.cursor == nil {
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [
                        .init(sessionId: "remote-1", cwd: "/tmp/wt", title: "Remote title"),
                        .init(sessionId: "wrong-cwd", cwd: "/tmp/other", title: "Other")
                    ],
                    nextCursor: "next"
                ))
            }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: [.init(sessionId: "remote-2", cwd: "/tmp/wt", title: "Second")]
            ))
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()

        await model.start(manager: manager, agentId: "claude")
        #expect(model.phase == .ready)
        #expect(model.sessions.map(\.remoteSessionId) == ["remote-1"])
        #expect(model.sessions.first?.worktreeId == "wt")
        #expect(model.sessions.first?.title == "Local title")
        #expect(model.sessions.first?.localSessionId == "local-1")
        #expect(model.canLoadMore)

        try await model.loadMore()
        #expect(model.sessions.map(\.remoteSessionId) == ["remote-1", "remote-2"])
        #expect(!model.canLoadMore)
        #expect(client.shutdownCount == 0)
        await model.stop()
        #expect(client.shutdownCount == 1)
        #expect(!client.sent.contains { $0.method == "session/delete" })
    }

    @Test("store scopes remote identity by agent and preserves origin")
    func storeRemoteIdentityAndOrigin() throws {
        let store = try temporaryStore()
        try store.upsertSession(row(
            id: "claude-local",
            remoteSessionId: "shared-id",
            title: "Claude",
            origin: .agentImported,
            agentId: "claude"
        ))
        try store.upsertSession(row(
            id: "codex-local",
            remoteSessionId: "shared-id",
            title: "Codex",
            origin: .agentForked,
            agentId: "codex"
        ))

        #expect(try store.loadSession(agentId: "claude", remoteSessionId: "shared-id")?.id == "claude-local")
        #expect(try store.loadSession(agentId: "codex", remoteSessionId: "shared-id")?.id == "codex-local")
        #expect(try store.loadSession(id: "claude-local")?.origin == .agentImported)
        #expect(try store.loadSession(id: "codex-local")?.origin == .agentForked)
    }

    @MainActor
    @Test("materialization rejects sessions whose additional roots Alas cannot enforce")
    func materializationRejectsAdditionalDirectories() async throws {
        let store = try temporaryStore()
        let manager = manager(store: store, client: ACPMockClient())
        let discovered = ACPDiscoveredSession(
            worktreeId: "wt",
            agentId: "claude",
            remoteSessionId: "remote-extra-roots",
            cwd: "/tmp/wt",
            title: "Shared roots",
            updatedAt: nil,
            additionalDirectories: ["/tmp/shared"],
            localSessionId: nil
        )

        let materialized = await manager.materializeDiscoveredSession(discovered)
        #expect(materialized == nil)
        #expect(try store.loadSession(agentId: "claude", remoteSessionId: "remote-extra-roots") == nil)
    }

    @MainActor
    @Test("materialization rejects discovery from another worktree")
    func materializationRejectsAnotherWorktree() async throws {
        let store = try temporaryStore()
        let manager = manager(store: store, client: ACPMockClient())
        let discovered = ACPDiscoveredSession(
            worktreeId: "other-worktree",
            agentId: "claude",
            remoteSessionId: "remote-other-worktree",
            cwd: "/tmp/wt",
            title: "Wrong scope",
            updatedAt: nil,
            additionalDirectories: [],
            localSessionId: nil
        )

        let materialized = await manager.materializeDiscoveredSession(discovered)
        #expect(materialized == nil)
        #expect(try store.loadSession(agentId: "claude", remoteSessionId: "remote-other-worktree") == nil)
    }

    private func temporaryStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-discovery-\(UUID().uuidString).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    private enum TestError: Error { case failed }

    private func discoveryClient(
        deleteCapability: Bool,
        deletionError: Error? = nil
    ) -> ACPMockClient {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    sessionCapabilities: .init(
                        list: .init(),
                        delete: deleteCapability ? .init() : nil
                    )
                ),
                authMethods: []
            ))
        }
        var listed = false
        client.script(method: "session/list") { _ in
            defer { listed = true }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: listed ? [] : [.init(
                    sessionId: "remote-listed", cwd: "/tmp/wt", title: "Listed"
                )]
            ))
        }
        client.script(method: "session/delete") { _ in
            if let deletionError { throw deletionError }
            return Data("{}".utf8)
        }
        return client
    }

    private func activeSessionClient(remoteSessionId: String) -> ACPMockClient {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(loadSession: true),
                authMethods: []
            ))
        }
        client.script(method: "session/load") { _ in
            try JSONEncoder().encode(ACPSessionNewResult(
                sessionId: remoteSessionId,
                availableModels: [],
                availableModes: [],
                currentModel: nil,
                currentMode: nil,
                promptSuggestions: []
            ))
        }
        client.script(method: "session/close") { _ in Data("{}".utf8) }
        return client
    }

    @MainActor
    private func manager(store: ACPSessionStore, client: ACPMockClient) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
    }

    private func row(
        id: String,
        remoteSessionId: String,
        title: String,
        origin: ACPSessionOrigin,
        agentId: String = "claude"
    ) -> ACPSessionRow {
        .init(
            id: id,
            agentId: agentId,
            title: title,
            titleSource: .manual,
            remoteSessionId: remoteSessionId,
            origin: origin,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 1,
            lastOpenedAt: 1,
            archived: false
        )
    }
}
