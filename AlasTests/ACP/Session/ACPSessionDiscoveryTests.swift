import Foundation
import Testing
@testable import Alas

@Suite("ACP session discovery")
struct ACPSessionDiscoveryTests {
    private actor DeletedSessions {
        private var ids: Set<String> = []

        func remaining(from candidates: [String]) -> [String] {
            candidates.filter { !ids.contains($0) }
        }
        func insert(_ id: String) { ids.insert(id) }
    }

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
    @Test("only a missing adapter reports installable setup", arguments: [
        (ACPSetupResult.missing(reason: "adapter missing"), ACPSessionDiscoveryModel.Phase.needsSetup("adapter missing")),
        (ACPSetupResult.error(message: "host unreachable"), ACPSessionDiscoveryModel.Phase.failed("host unreachable")),
    ])
    func setupResultPhase(setup: ACPSetupResult, expected: ACPSessionDiscoveryModel.Phase) async throws {
        let store = try temporaryStore()
        let client = discoveryClient(deleteCapability: false)
        let manager = ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in setup },
            connectionFactory: { _, _, _ in ACPConnection(client: client) }
        )
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        #expect(model.phase == expected)
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
        let deleted = DeletedSessions()
        let firstDeleteStarted = AsyncStream<Void>.makeStream()
        let releaseFirstDelete = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/list") { _ in
            let remaining = await deleted.remaining(from: ["first", "second", "third"])
            return try JSONEncoder().encode(ACPSessionListResult(sessions: remaining.map {
                .init(sessionId: $0, cwd: "/tmp/wt", title: $0)
            }))
        }
        client.scriptAsync(method: "session/delete") { request in
            let id = try #require(request.params as? ACPSessionDeleteParams).sessionId
            if id == "first" {
                firstDeleteStarted.continuation.yield()
                for await _ in releaseFirstDelete.stream { break }
            }
            await deleted.insert(id)
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
                    sessionCapabilities: .init(list: .init(), delete: .init(), close: .init())
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

    @MainActor
    @Test("the session index lists linked worktrees, follows empty pages, and routes rows to their worktree")
    func sessionIndexScopeAndRouting() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        var listRequests: [ACPSessionListParams] = []
        client.script(method: "session/list") { request in
            let params = try #require(request.params as? ACPSessionListParams)
            listRequests.append(params)
            guard params.meta?.sessionIndex.list.includeWorktrees == true else {
                return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                    .init(sessionId: "own", cwd: "/tmp/wt", title: "Own", index: .init(archived: false)),
                ]))
            }
            // An empty page that still has a cursor is followed.
            guard params.cursor != nil else {
                return try JSONEncoder().encode(ACPSessionListResult(sessions: [], nextCursor: "page-2"))
            }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "own", cwd: "/tmp/wt", title: "Own", index: .init(archived: false)),
                .init(sessionId: "sibling", cwd: "/tmp/wt2/", title: "Sibling",
                      index: .init(archived: false, model: "gpt-5", state: "running")),
                .init(sessionId: "agent-made", cwd: "/tmp/agent-wt", title: "Agent worktree",
                      index: .init(archived: false, agentWorktree: true)),
            ]))
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        let stores = ["/tmp/wt": "wt", "/tmp/wt2": "wt2"]
        await model.start(manager: manager, agentId: "claude") { cwd in
            stores[URL(fileURLWithPath: cwd).standardizedFileURL.path].map { .init(worktreeId: $0, persistence: nil) }
        }

        #expect(model.sessionIndex == .init(archive: true, rename: true, listSubscribe: true, worktrees: true))
        #expect(model.sessions.map(\.remoteSessionId) == ["own"])
        #expect(listRequests.first?.meta?.sessionIndex.list == .init(includeWorktrees: false, archived: .unarchived))

        try await model.setFilter(.init(includeLinkedWorktrees: true))
        #expect(model.sessions.map(\.remoteSessionId) == ["own", "sibling", "agent-made"])
        #expect(model.sessions.map(\.worktreeId) == ["wt", "wt2", nil])
        #expect(listRequests.suffix(2).map(\.cursor) == [nil, "page-2"])
        let capabilities = try #require(model.capabilities)
        #expect(model.sessions.map { ACPSessionBrowserRowPolicy.canOpen($0, capabilities: capabilities) } == [true, true, false])
        await model.stop()
    }

    @MainActor
    @Test("overlapping filter changes show only the latest; a pending change blocks Load more; a failed one keeps the listed filter")
    func overlappingFilterChanges() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let staleStarted = AsyncStream<Void>.makeStream()
        let failGate = AsyncStream<Void>.makeStream()
        let failStarted = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/list") { request in
            let list = try #require((request.params as? ACPSessionListParams)?.meta?.sessionIndex.list)
            switch (list.includeWorktrees, list.archived) {
            case (true, .unarchived):
                // The older change: answers after the newer one finished.
                staleStarted.continuation.yield()
                for await _ in gate.stream { break }
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "stale", cwd: "/tmp/wt", index: .init(archived: false))],
                    nextCursor: "stale-cursor"))
            case (true, .archived):
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "latest", cwd: "/tmp/wt", index: .init(archived: true))]))
            case (false, .archived):
                failStarted.continuation.yield()
                for await _ in failGate.stream { break }
                throw TestError.failed
            default:
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "initial", cwd: "/tmp/wt", index: .init(archived: false))]))
            }
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude", worktreeResolver: Self.projectResolver)
        #expect(model.sessions.map(\.remoteSessionId) == ["initial"])

        let stale = Task { try await model.setFilter(.init(includeLinkedWorktrees: true)) }
        for await _ in staleStarted.stream { break }
        let latest = ACPSessionBrowserFilter(includeLinkedWorktrees: true, showArchived: true)
        try await model.setFilter(latest)
        // Arrives while the older load is still pending: buffered, and
        // replayed when that last load ends.
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "fresh", cwd: "/tmp/wt", index: .init(archived: true)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.map(\.remoteSessionId) == ["fresh", "latest"] })
        gate.continuation.yield()
        try await stale.value
        #expect(model.filter == latest)
        #expect(await awaitCondition { model.sessions.map(\.remoteSessionId) == ["fresh", "latest"] })
        #expect(!model.canLoadMore)

        let failing = Task { try await model.setFilter(.init(showArchived: true)) }
        for await _ in failStarted.stream { break }
        #expect(!model.canLoadMore)
        // The pending change replaces the rows anyway: no reconcile meanwhile.
        let listsBefore = client.sent.filter { $0.method == "session/list" }.count
        await model.reconcile()
        #expect(client.sent.filter { $0.method == "session/list" }.count == listsBefore)
        // Reduced with the listed (linked) filter, not the pending one.
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "linked-archived", cwd: "/tmp/elsewhere", index: .init(archived: true)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.map(\.remoteSessionId) == ["linked-archived", "fresh", "latest"] })
        failGate.continuation.yield()
        await #expect(throws: TestError.failed) { try await failing.value }
        #expect(model.filter == latest)
        #expect(model.sessions.map(\.remoteSessionId) == ["linked-archived", "fresh", "latest"])
        await model.stop()
    }

    @MainActor
    @Test("a list subscription that cannot be set up still leaves the first page reconciled")
    func reconcileWithoutSubscription() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        client.script(method: "_session/list/subscribe") { _ in throw TestError.failed }
        var lists = 0
        client.script(method: "session/list") { _ in
            lists += 1
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "s", cwd: "/tmp/wt", title: lists == 1 ? "First" : "Current", index: .init(archived: false)),
            ]))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        #expect(model.sessions.first?.title == "Current")
        await model.stop()
    }

    @MainActor
    @Test("a basic agent keeps the exact-cwd list and sends no session index metadata")
    func basicAgentFallback() async throws {
        let store = try temporaryStore()
        let client = discoveryClient(deleteCapability: false)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        #expect(model.sessionIndex == nil)
        #expect((client.sent.first { $0.method == "session/list" }?.params as? ACPSessionListParams)?.meta == nil)
        try await model.setFilter(.init(includeLinkedWorktrees: true))
        #expect(client.sent.filter { $0.method == "session/list" }.count == 1)
        let session = try #require(model.sessions.first)
        await #expect(throws: ACPSessionDiscoveryError.archiveUnsupported) {
            try await model.setArchived(true, for: session)
        }
        #expect(!client.sent.contains { $0.method.hasPrefix("_session/") })
    }

    @MainActor
    @Test("list changes update rows in place, insert new ones once, and the subscription ends with the browser")
    func listSubscriptionLifecycle() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        client.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "a", cwd: "/tmp/wt", title: "A", updatedAt: "2026-10-16T10:00:00Z", index: .init(archived: false)),
                .init(sessionId: "b", cwd: "/tmp/wt", title: "B", updatedAt: "2026-10-16T09:00:00Z", index: .init(archived: false)),
            ]))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let subscribe = try #require(client.sent.first { $0.method == "_session/list/subscribe" })
        #expect(subscribe.params as? ACPSessionListSubscribeParams == .init(cwd: "/tmp/wt"))
        // Without a project resolver (a workspace checkout) there is no linked scope.
        #expect(!model.canListLinkedWorktrees)
        let lists = client.sent.filter { $0.method == "session/list" }.count
        try await model.setFilter(.init(includeLinkedWorktrees: true))
        #expect(client.sent.filter { $0.method == "session/list" }.count == lists)

        let newer = ACPAgentSessionInfo(sessionId: "c", cwd: "/tmp/wt", title: "C", updatedAt: "2026-10-16T11:00:00Z", index: .init(archived: false))
        client.emitSessionListChanges(.init(subscriptionId: "other-subscription", sessions: [newer], removed: ["a"]))
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "b", cwd: "/tmp/wt", title: "B renamed", updatedAt: "2026-10-16T09:00:00Z", index: .init(archived: false, state: "running")),
            newer, newer,
        ], removed: []))
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "a", cwd: "/tmp/wt", title: "A", index: .init(archived: true)),
        ], removed: ["missing"]))
        #expect(await awaitCondition { model.sessions.map(\.remoteSessionId) == ["c", "b"] })
        #expect(model.sessions.last?.title == "B renamed")
        #expect(model.sessions.last?.index?.state == "running")

        await model.stop()
        let methods = client.sent.map(\.method)
        #expect(methods.contains("_session/list/unsubscribe"))
        #expect(client.shutdownCount == 1)
    }

    @MainActor
    @Test("rename and archive go to the agent; archive leaves the Alas session and a failure keeps the row")
    func renameAndArchive() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-1", remoteSessionId: "remote-1", title: "Local", origin: .agentImported))
        try store.upsertSession(row(id: "local-2", remoteSessionId: "remote-2", title: "Other", origin: .agentImported))
        let client = indexClient()
        client.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "remote-1", cwd: "/tmp/wt", title: "Remote", index: .init(archived: false)),
                .init(sessionId: "remote-2", cwd: "/tmp/wt", title: "Other", index: .init(archived: false)),
            ]))
        }
        var localTitles: [String] = []
        client.script(method: "_session/rename") { request in
            localTitles.append("rpc")
            guard (request.params as? ACPSessionRenameParams)?.sessionId == "remote-1" else { throw TestError.failed }
            return Data("{}".utf8)
        }
        client.script(method: "_session/archive") { request in
            guard (request.params as? ACPSessionArchiveParams)?.sessionId == "remote-1" else { throw TestError.failed }
            return Data("{}".utf8)
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let first = try #require(model.sessions.first)

        var renamedLocally: [String: String] = [:]
        try await model.rename(first, to: "  Renamed  ") { id, title in
            renamedLocally[id] = title
            localTitles.append(title)
            return {
                localTitles.append("restored")
                return "Local"
            }
        }
        // The Alas copy is renamed before the agent, so a notification the
        // rename triggers already reads the new Alas title.
        #expect(localTitles == ["Renamed", "rpc"])
        #expect(client.sent.first { $0.method == "_session/rename" }?.params as? ACPSessionRenameParams
            == .init(sessionId: "remote-1", title: "Renamed"))
        #expect(model.sessions.first?.title == "Renamed")
        #expect(renamedLocally == ["local-1": "Renamed"])

        // An Alas title that cannot be stored stops the agent rename.
        localTitles = []
        await #expect(throws: TestError.failed) {
            try await model.rename(try #require(model.sessions.first), to: "Unstored") { _, _ in throw TestError.failed }
        }
        #expect(localTitles.isEmpty)

        // A failed rename puts the Alas title back.
        localTitles = []
        await #expect(throws: TestError.failed) {
            try await model.rename(try #require(model.sessions.last), to: "Nope") { _, title in
                localTitles.append(title)
                return {
                    localTitles.append("restored")
                    return "Other"
                }
            }
        }
        // The restore puts back the previous title and its source.
        #expect(localTitles == ["Nope", "rpc", "restored"])
        #expect(model.sessions.last?.title == "Other")

        // A restore that cannot be stored leaves the new Alas title stored:
        // the row shows it too, and the agent's error is still reported.
        await #expect(throws: TestError.failed) {
            try await model.rename(try #require(model.sessions.last), to: "Stuck") { _, _ in
                { throw TestError.failed }
            }
        }
        #expect(model.sessions.last?.title == "Stuck")

        // A newer rename from elsewhere is kept by the rollback, and shown.
        await #expect(throws: TestError.failed) {
            try await model.rename(try #require(model.sessions.last), to: "Mine") { _, _ in
                { "Newer from elsewhere" }
            }
        }
        #expect(model.sessions.last?.title == "Newer from elsewhere")

        try await model.setArchived(true, for: try #require(model.sessions.first))
        #expect(model.sessions.map(\.remoteSessionId) == ["remote-2"])
        #expect(try store.loadSession(id: "local-1") != nil)
        #expect(!client.sent.contains { $0.method == "session/delete" })

        await #expect(throws: TestError.failed) {
            try await model.setArchived(true, for: try #require(model.sessions.first))
        }
        #expect(model.sessions.map(\.remoteSessionId) == ["remote-2"])
        await model.stop()
    }

    private static func reducerRow(
        _ id: String, _ minute: Int, archived: Bool = false, title: String? = nil, worktreeId: String = "wt"
    ) -> ACPDiscoveredSession {
        .init(worktreeId: worktreeId, agentId: "codex", remoteSessionId: id, cwd: "/tmp/\(worktreeId)", title: title ?? id,
              updatedAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)), additionalDirectories: [],
              localSessionId: nil, index: .init(archived: archived))
    }

    @Test("list changes reducer keeps ids unique and honors the archive filter and worktree scope", arguments: [false, true])
    func reducer(showArchived: Bool) {
        func row(_ id: String, _ minute: Int, archived: Bool = false, title: String? = nil, worktreeId: String = "wt") -> ACPDiscoveredSession {
            Self.reducerRow(id, minute, archived: archived, title: title, worktreeId: worktreeId)
        }
        let filter = ACPSessionBrowserFilter(showArchived: showArchived)
        let listed = [row("a", 30, archived: showArchived), row("b", 10, archived: showArchived)]
        let result = ACPSessionBrowserReducer.applying(
            changed: [
                row("b", 10, archived: showArchived, title: "B2"),
                row("c", 20, archived: showArchived),
                row("c", 20, archived: showArchived),
                row("a", 30, archived: !showArchived),
                row("d", 40, archived: !showArchived),
                // Subscriptions cover every linked worktree; this browser does not.
                row("e", 50, archived: showArchived, worktreeId: "wt2"),
            ],
            removed: ["c-gone"],
            to: listed + [row("c-gone", 5, archived: showArchived)],
            filter: filter,
            browsingWorktreeId: "wt"
        )
        #expect(result.map(\.remoteSessionId) == ["c", "b"])
        #expect(result.last?.title == "B2")
    }

    @Test("first-page reconciliation removes missed removals but keeps rows that may have moved to a later page",
          arguments: [false, true])
    func reconciliation(hasMorePages: Bool) {
        let filter = ACPSessionBrowserFilter()
        // Listed: first page a, b, c; then d from a later page.
        let rows = [Self.reducerRow("a", 40), Self.reducerRow("b", 30), Self.reducerRow("c", 20), Self.reducerRow("d", 10)]
        // Refreshed first page: a and c; b (newer than c) is gone. With more
        // pages, d and anything older than c may simply be on the next page.
        let result = ACPSessionBrowserReducer.reconciling(
            firstPage: [Self.reducerRow("a", 40, title: "A2"), Self.reducerRow("c", 20)],
            hasMorePages: hasMorePages,
            listedBefore: ["a", "b", "c"],
            rows: rows,
            filter: filter,
            browsingWorktreeId: "wt"
        )
        #expect(result.map(\.remoteSessionId) == ["a", "c", "d"])
        #expect(result.first?.title == "A2")
        let older = ACPSessionBrowserReducer.reconciling(
            firstPage: [Self.reducerRow("a", 40), Self.reducerRow("b", 30)],
            hasMorePages: hasMorePages,
            listedBefore: ["a", "b", "c"],
            rows: rows,
            filter: filter,
            browsingWorktreeId: "wt"
        )
        #expect(older.map(\.remoteSessionId) == (hasMorePages ? ["a", "b", "c", "d"] : ["a", "b", "d"]))
    }

    @MainActor
    @Test("a live change that the pending filter page predates is replayed after the page commits")
    func liveChangeDuringFilterLoad() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let archivedStarted = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/list") { request in
            let list = try #require((request.params as? ACPSessionListParams)?.meta?.sessionIndex.list)
            guard list.archived == .archived else {
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "x", cwd: "/tmp/wt", index: .init(archived: false))]))
            }
            // The archived page was read before "x" was archived.
            archivedStarted.continuation.yield()
            for await _ in gate.stream { break }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: []))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let change = Task { try await model.setFilter(.init(showArchived: true)) }
        for await _ in archivedStarted.stream { break }
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "x", cwd: "/tmp/wt", index: .init(archived: true)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.isEmpty })
        gate.continuation.yield()
        try await change.value
        #expect(model.sessions.map(\.remoteSessionId) == ["x"])
        await model.stop()
    }

    @MainActor
    @Test("a change made during a reconcile is not undone by the older page", arguments: ["push", "archive", "delete", "rename", "removeLocal", "pushThenRemoveLocal"])
    func liveChangeDuringReconcile(action: String) async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-1", remoteSessionId: "deleted", title: "Old", origin: .agentImported))
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let reconcileStarted = AsyncStream<Void>.makeStream()
        var lists = 0
        var deleted = false
        client.scriptAsync(method: "session/list") { _ in
            lists += 1
            // The first page at start and after subscribing; the third read is
            // the reconcile under test, whose page predates the removal.
            if lists == 3 {
                reconcileStarted.continuation.yield()
                for await _ in gate.stream { break }
            }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "kept", cwd: "/tmp/wt", index: .init(archived: false)),
                .init(sessionId: "deleted", cwd: "/tmp/wt", title: "Old", index: .init(archived: false)),
            ].filter { !(deleted && $0.sessionId == "deleted") }))
        }
        client.script(method: "_session/archive") { _ in Data("{}".utf8) }
        client.script(method: "_session/rename") { _ in Data("{}".utf8) }
        client.script(method: "session/delete") { _ in
            deleted = true
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let reconcile = Task { await model.reconcile() }
        for await _ in reconcileStarted.stream { break }
        let target = try #require(model.sessions.last)
        switch action {
        case "archive": try await model.setArchived(true, for: target)
        case "delete": try await model.deleteAgentHistory(for: target, removeLocalHistory: false, manager: manager)
        case "rename": try await model.rename(target, to: "Renamed") { _, _ in nil }
        case "removeLocal": try await model.removeLocalHistory(for: target, manager: manager)
        case "pushThenRemoveLocal":
            // The agent deleted it elsewhere, then Alas drops its copy.
            client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [], removed: ["deleted"]))
            #expect(await awaitCondition { !model.sessions.contains { $0.remoteSessionId == "deleted" } })
            deleted = true
            try await model.removeLocalHistory(for: target, manager: manager)
        default: client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [], removed: ["deleted"]))
        }
        let expected = ["rename", "removeLocal"].contains(action) ? ["kept", "deleted"] : ["kept"]
        #expect(await awaitCondition { model.sessions.map(\.remoteSessionId) == expected })
        gate.continuation.yield()
        await reconcile.value
        #expect(model.sessions.map(\.remoteSessionId) == expected)
        if action == "rename" { #expect(model.sessions.last?.title == "Renamed") }
        // The older page still had the Alas copy; it must not come back.
        if action == "removeLocal" { #expect(model.sessions.last?.localSessionId == nil) }
        await model.stop()
    }

    @MainActor
    @Test("deleting during a filter load that fails keeps the other rows; a failed local cleanup keeps its retry row")
    func deletionDuringPendingReads() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-b", remoteSessionId: "b", title: "B", origin: .agentImported))
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        var gated = false
        var deleted: Set<String> = []
        client.scriptAsync(method: "session/list") { request in
            let list = try #require((request.params as? ACPSessionListParams)?.meta?.sessionIndex.list)
            if gated {
                gated = false
                pending.continuation.yield()
                for await _ in gate.stream { break }
                if list.archived == .archived { throw TestError.failed }
            }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: ["a", "b", "c"]
                .filter { !deleted.contains($0) }
                .map { .init(sessionId: $0, cwd: "/tmp/wt", index: .init(archived: false)) }))
        }
        client.script(method: "session/delete") { request in
            deleted.insert((request.params as? ACPSessionDeleteParams)?.sessionId ?? "")
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        #expect(model.sessions.map(\.remoteSessionId) == ["a", "b", "c"])

        // A filter change whose page fails while "a" is deleted.
        gated = true
        let change = Task { try await model.setFilter(.init(showArchived: true)) }
        for await _ in pending.stream { break }
        try await model.deleteAgentHistory(for: model.sessions[0], removeLocalHistory: false, manager: manager)
        gate.continuation.yield()
        await #expect(throws: TestError.failed) { try await change.value }
        #expect(model.sessions.map(\.remoteSessionId) == ["b", "c"])

        // Agent-side delete of "b" succeeds, its local cleanup fails, during a reconcile.
        try store.db.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'no'); END")
        gated = true
        let reconcile = Task { await model.reconcile() }
        for await _ in pending.stream { break }
        await #expect(throws: (any Error).self) {
            try await model.deleteAgentHistory(for: model.sessions[0], removeLocalHistory: true, manager: manager)
        }
        gate.continuation.yield()
        await reconcile.value
        #expect(model.sessions.contains { $0.remoteSessionId == "b" })
        // The agent's own removal arrives after the failed cleanup: the retry
        // row stays (the title change shows the notification was applied).
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "c", cwd: "/tmp/wt", title: "Seen", index: .init(archived: false)),
        ], removed: ["b"]))
        #expect(await awaitCondition { model.sessions.last?.title == "Seen" })
        #expect(model.sessions.contains { $0.remoteSessionId == "b" })
        await model.stop()
    }

    @MainActor
    @Test("a Load more answering after a deletion refresh neither shows its rows nor moves the cursor")
    func loadMoreAfterDeletionRefresh() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-first", remoteSessionId: "first", title: "First", origin: .agentImported))
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let pageTwoStarted = AsyncStream<Void>.makeStream()
        var holdPageTwo = true
        client.scriptAsync(method: "session/list") { request in
            if (request.params as? ACPSessionListParams)?.cursor == "page-2" {
                // Only the first page-2 read is held: the stale Load more.
                if holdPageTwo {
                    holdPageTwo = false
                    pageTwoStarted.continuation.yield()
                    for await _ in gate.stream { break }
                }
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "second", cwd: "/tmp/wt", index: .init(archived: false))],
                    nextCursor: "page-3"))
            }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: [.init(sessionId: "first", cwd: "/tmp/wt", index: .init(archived: false))],
                nextCursor: "page-2"))
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude")
        let loadMore = Task { try await model.loadMore() }
        for await _ in pageTwoStarted.stream { break }
        try await model.removeLocalHistory(for: try #require(model.sessions.first), manager: manager)
        gate.continuation.yield()
        try await loadMore.value
        #expect(model.sessions.map(\.remoteSessionId) == ["first"])
        #expect(model.sessions.first?.localSessionId == nil)
        // The refreshed first page's cursor, not the stale page-3.
        let sentBefore = client.sent.count
        try await model.loadMore()
        #expect((client.sent.dropFirst(sentBefore).first?.params as? ACPSessionListParams)?.cursor == "page-2")
        await model.stop()
    }

    @MainActor
    @Test("a live change read from the store before Remove from Alas does not bring the copy back")
    func staleLiveChangeAfterLocalRemoval() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-1", remoteSessionId: "remote-1", title: "Local", origin: .agentImported))
        // The handle reads Alas copies from a store that still has the row,
        // as a notification materialized before the removal would.
        let staleURL = FileManager.default.temporaryDirectory.appendingPathComponent("acp-stale-\(UUID().uuidString).sqlite")
        let stale = try ACPSessionStore(path: staleURL.path)
        try stale.upsertSession(row(id: "local-1", remoteSessionId: "remote-1", title: "Local", origin: .agentImported))
        let stalePersistence = ACPSessionPersistence(path: staleURL.path)
        let client = indexClient()
        client.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "remote-1", cwd: "/tmp/wt", index: .init(archived: false)),
            ]))
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude") { cwd in
            Self.projectResolver(cwd).map { .init(worktreeId: $0.worktreeId, persistence: stalePersistence) }
        }
        #expect(model.sessions.first?.localSessionId == "local-1")
        try await model.removeLocalHistory(for: try #require(model.sessions.first), manager: manager)
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "remote-1", cwd: "/tmp/wt", title: "Renamed elsewhere", index: .init(archived: false)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.first?.title == "Local" || model.sessions.first?.title == "Renamed elsewhere" })
        #expect(model.sessions.first?.localSessionId == nil)
        await model.stop()
    }

    @MainActor
    @Test("an archive keeps the newer data its own notification brought, across a pending filter page")
    func archiveAfterItsNotification() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let archiveGate = AsyncStream<Void>.makeStream()
        let archiveStarted = AsyncStream<Void>.makeStream()
        let pageGate = AsyncStream<Void>.makeStream()
        let pageStarted = AsyncStream<Void>.makeStream()
        var holdArchivedPage = true
        client.scriptAsync(method: "session/list") { request in
            let list = try #require((request.params as? ACPSessionListParams)?.meta?.sessionIndex.list)
            guard list.archived == .archived else {
                return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                    .init(sessionId: "s", cwd: "/tmp/wt", title: "Original", index: .init(archived: false)),
                ]))
            }
            // The first read predates the archive: nothing archived yet. The
            // filter load reads again after the archive and gets the row.
            if holdArchivedPage {
                holdArchivedPage = false
                pageStarted.continuation.yield()
                for await _ in pageGate.stream { break }
                return try JSONEncoder().encode(ACPSessionListResult(sessions: []))
            }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "s", cwd: "/tmp/wt", title: "Fresh", index: .init(archived: true)),
            ]))
        }
        client.scriptAsync(method: "_session/archive") { _ in
            archiveStarted.continuation.yield()
            for await _ in archiveGate.stream { break }
            return Data("{}".utf8)
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let archive = Task { try await model.setArchived(true, for: try #require(model.sessions.first)) }
        for await _ in archiveStarted.stream { break }
        let filter = Task { try await model.setFilter(.init(showArchived: true)) }
        for await _ in pageStarted.stream { break }
        // The archive notification, with a newer title, before the RPC answers.
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "s", cwd: "/tmp/wt", title: "Fresh", index: .init(archived: true)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.isEmpty })
        archiveGate.continuation.yield()
        try await archive.value
        pageGate.continuation.yield()
        try await filter.value
        #expect(model.sessions.map(\.title) == ["Fresh"])
        await model.stop()
    }

    @Test("live rows read before their session's local action finished are left out", arguments: [
        (nil, true), (3, true), (4, false),
    ] as [(Int?, Bool)])
    func liveRowsPredatingLocalActions(lastAction: Int?, kept: Bool) {
        let stamp = ACPSessionBrowserStamp(localActions: 3, listReads: 5)
        let actions = lastAction.map { ["s": $0] } ?? [:]
        #expect(ACPSessionBrowserReducer.droppingRows(
            [Self.reducerRow("s", 1)], predating: stamp, lastLocalAction: actions
        ).isEmpty == !kept)
    }

    @Test("a live change is superseded only for the sessions a later-started page showed", arguments: [
        // Page read index that last showed "s"; the change started at read 5.
        (nil, true),
        (5, true),
        (6, false),
    ] as [(Int?, Bool)])
    func liveChangeSupersession(pageRead: Int?, kept: Bool) {
        let index = pageRead.map { ["s": $0] } ?? [:]
        let result = ACPSessionBrowserReducer.unsuperseded(
            changed: [Self.reducerRow("s", 1), Self.reducerRow("other", 1)],
            removed: ["s", "other-removed"],
            stamp: .init(localActions: 0, listReads: 5),
            pageReadIndex: index
        )
        #expect(result.changed.map(\.remoteSessionId) == (kept ? ["s", "other"] : ["other"]))
        #expect(result.removed == (kept ? ["s", "other-removed"] : ["other-removed"]))
    }

    @MainActor
    @Test("a failed rename of a session without an Alas copy keeps a title the agent reported meanwhile")
    func failedRemoteOnlyRename() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        client.script(method: "session/list") { _ in
            try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "s", cwd: "/tmp/wt", title: "Original", index: .init(archived: false)),
            ]))
        }
        client.scriptAsync(method: "_session/rename") { _ in
            started.continuation.yield()
            for await _ in gate.stream { break }
            throw TestError.failed
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let rename = Task { try await model.rename(try #require(model.sessions.first), to: "Mine") { _, _ in nil } }
        for await _ in started.stream { break }
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "s", cwd: "/tmp/wt", title: "External", index: .init(archived: false)),
        ], removed: []))
        #expect(await awaitCondition { model.sessions.first?.title == "External" })
        gate.continuation.yield()
        await #expect(throws: TestError.failed) { try await rename.value }
        #expect(model.sessions.first?.title == "External")
        await model.stop()
    }

    @MainActor
    @Test("a removal that lands while Load more is in flight is not undone by its page")
    func removalDuringLoadMore() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let pageTwoStarted = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/list") { request in
            guard (request.params as? ACPSessionListParams)?.cursor == "page-2" else {
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "first", cwd: "/tmp/wt", index: .init(archived: false))],
                    nextCursor: "page-2"))
            }
            pageTwoStarted.continuation.yield()
            for await _ in gate.stream { break }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "gone", cwd: "/tmp/wt", index: .init(archived: false)),
                .init(sessionId: "kept", cwd: "/tmp/wt", index: .init(archived: false)),
            ]))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        let loadMore = Task { try await model.loadMore() }
        for await _ in pageTwoStarted.stream { break }
        // The title change shows when the notification has been applied,
        // before page 2 resumes.
        client.emitSessionListChanges(.init(subscriptionId: "sub-1", sessions: [
            .init(sessionId: "first", cwd: "/tmp/wt", title: "Seen", index: .init(archived: false)),
        ], removed: ["gone"]))
        #expect(await awaitCondition { model.sessions.first?.title == "Seen" })
        gate.continuation.yield()
        try await loadMore.value
        #expect(model.sessions.map(\.remoteSessionId) == ["first", "kept"])
        await model.stop()
    }

    @Test("a missing row kept on a timestamp tie is removed once a page settles it")
    func reconciliationTieIsRechecked() {
        let filter = ACPSessionBrowserFilter()
        let rows = [Self.reducerRow("a", 40), Self.reducerRow("tie", 20), Self.reducerRow("c", 20)]
        // "tie" is missing and ties the new page's oldest row: kept for now.
        let page = [Self.reducerRow("a", 40), Self.reducerRow("c", 20)]
        let merged = ACPSessionBrowserReducer.reconciling(
            firstPage: page, hasMorePages: true, listedBefore: ["a", "tie", "c"], rows: rows,
            filter: filter, browsingWorktreeId: "wt"
        )
        #expect(merged.map(\.remoteSessionId) == ["a", "tie", "c"])
        // A later page with an older oldest row settles it.
        let later = ACPSessionBrowserReducer.reconciling(
            firstPage: page + [Self.reducerRow("d", 10)], hasMorePages: true, listedBefore: ["a", "tie", "c"], rows: merged,
            filter: filter, browsingWorktreeId: "wt"
        )
        #expect(!later.contains { $0.remoteSessionId == "tie" })
    }

    @MainActor
    @Test("a reconcile reads past the page boundary to settle a missing tied or undated row", arguments: [
        (false, false), (true, false), (false, true), (true, true),
    ])
    func reconcileReadsPastTiedBoundary(movedToNextPage: Bool, undated: Bool) async throws {
        let store = try temporaryStore()
        let client = indexClient()
        var reconciled = false
        let row = Self.listedRow
        client.script(method: "session/list") { request in
            let cursor = (request.params as? ACPSessionListParams)?.cursor
            if cursor == "page-2" {
                // Past the tie: an older row, and "t2" only if it merely moved.
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: (movedToNextPage ? [row("t2", undated ? nil : "2026-10-16T09:00:00Z")] : [])
                        + [row("old", "2026-10-16T08:00:00Z")]))
            }
            defer { reconciled = true }
            // The first page is full of sessions sharing one whole second.
            let tied = reconciled ? ["t1", "t3"] : ["t1", "t2"]
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: [
                    row("a", "2026-10-16T10:00:00Z"),
                    row(tied[0], "2026-10-16T09:00:00Z"),
                    // An undated "t2" has no known position at all.
                    row(tied[1], undated && tied[1] == "t2" ? nil : "2026-10-16T09:00:00Z"),
                ],
                nextCursor: "page-2"))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        await model.reconcile()
        #expect(model.sessions.contains { $0.remoteSessionId == "t2" } == movedToNextPage)
        #expect(model.sessions.contains { $0.remoteSessionId == "t3" })
        await model.stop()
    }

    @MainActor
    @Test("a deleted row pushed below the first page by newer activity is settled", arguments: [false, true])
    func displacedRowSettled(stillListed: Bool) async throws {
        let store = try temporaryStore()
        let client = indexClient()
        var reconciled = false
        let row = Self.listedRow
        // Renamed elsewhere while its notification was missed.
        let moved = ACPAgentSessionInfo(sessionId: "d", cwd: "/tmp/wt", title: "Renamed elsewhere",
                                        updatedAt: "2026-10-16T08:00:00Z", index: .init(archived: false))
        client.script(method: "session/list") { request in
            if (request.params as? ACPSessionListParams)?.cursor == "page-2" {
                // "d" is on page 2 only if it was not deleted.
                return try JSONEncoder().encode(ACPSessionListResult(sessions: (stillListed ? [moved] : [])
                    + [row("older", "2026-10-16T07:00:00Z")]))
            }
            defer { reconciled = true }
            // Newer sessions push "d" out of the first page.
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: reconciled
                    ? [row("n1", "2026-10-16T12:00:00Z"), row("n2", "2026-10-16T11:00:00Z")]
                    : [row("a", "2026-10-16T10:00:00Z"), row("d", "2026-10-16T08:00:00Z")],
                nextCursor: "page-2"))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        await model.reconcile()
        #expect(model.sessions.contains { $0.remoteSessionId == "d" } == stillListed)
        if stillListed { #expect(model.sessions.first { $0.remoteSessionId == "d" }?.title == "Renamed elsewhere") }
        await model.stop()
    }

    @MainActor
    @Test("a row loaded with Load more and deleted with its removal missed is settled by a reconcile")
    func reconcileSettlesLoadMoreRows() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        var deleted = false
        let row = Self.listedRow
        client.script(method: "session/list") { request in
            guard (request.params as? ACPSessionListParams)?.cursor == "page-2" else {
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [row("a", "2026-10-16T10:00:00Z")], nextCursor: "page-2"))
            }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: deleted ? [row("older", "2026-10-16T07:00:00Z")]
                    : [row("late", "2026-10-16T08:00:00Z"), row("older", "2026-10-16T07:00:00Z")]))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        try await model.loadMore()
        #expect(model.sessions.map(\.remoteSessionId) == ["a", "late", "older"])
        deleted = true
        await model.reconcile()
        #expect(model.sessions.map(\.remoteSessionId) == ["a", "older"])
        await model.stop()
    }

    @MainActor
    @Test("an undated missing row is settled at the end of a long history")
    func undatedRowSettledAtLongHistoryEnd() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        var reconciled = false
        let row = Self.listedRow
        client.script(method: "session/list") { request in
            guard let cursor = (request.params as? ACPSessionListParams)?.cursor else {
                defer { reconciled = true }
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [row("a", "2026-10-16T10:00:00Z"), row(reconciled ? "b" : "gone", nil)],
                    nextCursor: "page-2"))
            }
            // Sixty more pages, none holding "gone".
            let number = Int(cursor.dropFirst("page-".count)) ?? 0
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: [row("older-\(number)", "2026-10-15T10:00:00Z")],
                nextCursor: number < 61 ? "page-\(number + 1)" : nil))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude")
        await model.reconcile()
        #expect(!model.sessions.contains { $0.remoteSessionId == "gone" })
        await model.stop()
    }

    @MainActor
    @Test("a rename made during an older read keeps the newer data a later page brought")
    func renamePatchOverNewerPage() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let reconcileStarted = AsyncStream<Void>.makeStream()
        var lists = 0
        client.scriptAsync(method: "session/list") { request in
            lists += 1
            if lists == 3 {
                reconcileStarted.continuation.yield()
                for await _ in gate.stream { break }
            }
            let linked = (request.params as? ACPSessionListParams)?.meta?.sessionIndex.list.includeWorktrees == true
            return try JSONEncoder().encode(ACPSessionListResult(sessions: [
                .init(sessionId: "s", cwd: "/tmp/wt", title: "Agent title",
                      index: .init(archived: false, model: linked ? "newer-model" : "older-model")),
            ]))
        }
        client.script(method: "_session/rename") { _ in Data("{}".utf8) }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude", worktreeResolver: Self.projectResolver)
        let reconcile = Task { await model.reconcile() }
        for await _ in reconcileStarted.stream { break }
        try await model.rename(try #require(model.sessions.first), to: "Renamed") { _, _ in nil }
        try await model.setFilter(.init(includeLinkedWorktrees: true))
        gate.continuation.yield()
        await reconcile.value
        #expect(model.sessions.first?.title == "Renamed")
        #expect(model.sessions.first?.index?.model == "newer-model")
        await model.stop()
    }

    @MainActor
    @Test("a cleanup-retry row comes back after a filter page that left it out")
    func retryRowAfterFilterPage() async throws {
        let store = try temporaryStore()
        try store.upsertSession(row(id: "local-a", remoteSessionId: "a", title: "A", origin: .agentImported))
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let pageStarted = AsyncStream<Void>.makeStream()
        var deleted = false
        var holdFilterPage = true
        client.scriptAsync(method: "session/list") { request in
            // Only the first linked-scope read is held; the filter load reads
            // again after the delete.
            if (request.params as? ACPSessionListParams)?.meta?.sessionIndex.list.includeWorktrees == true,
               deleted, holdFilterPage {
                holdFilterPage = false
                pageStarted.continuation.yield()
                for await _ in gate.stream { break }
            }
            let b = ACPAgentSessionInfo(sessionId: "b", cwd: "/tmp/wt", index: .init(archived: false))
            let a = ACPAgentSessionInfo(sessionId: "a", cwd: "/tmp/wt", index: .init(archived: false))
            if (request.params as? ACPSessionListParams)?.cursor == "page-2" {
                return try JSONEncoder().encode(ACPSessionListResult(sessions: []))
            }
            return try JSONEncoder().encode(ACPSessionListResult(sessions: deleted ? [b] : [a, b], nextCursor: "page-2"))
        }
        client.script(method: "session/delete") { _ in
            deleted = true
            return Data("{}".utf8)
        }
        let manager = manager(store: store, client: client)
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager, agentId: "claude") { cwd in
            Self.projectResolver(cwd).map { .init(worktreeId: $0.worktreeId, persistence: manager.persistence) }
        }
        let target = try #require(model.sessions.first { $0.remoteSessionId == "a" })
        #expect(target.localSessionId == "local-a")
        try store.db.exec("CREATE TRIGGER fail_delete BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'no'); END")
        deleted = true
        let change = Task { try await model.setFilter(.init(includeLinkedWorktrees: true)) }
        for await _ in pageStarted.stream { break }
        await #expect(throws: (any Error).self) {
            try await model.deleteAgentHistory(for: target, removeLocalHistory: true, manager: manager)
        }
        gate.continuation.yield()
        try await change.value
        #expect(model.sessions.contains { $0.remoteSessionId == "a" })
        // Switching away and back: the agent's pages never list "a" again.
        try await model.setFilter(.init())
        #expect(model.sessions.contains { $0.remoteSessionId == "a" })
        // A reconcile does not scan the whole history for a row the agent
        // deleted: only the first page is read.
        let sent = client.sent.count
        await model.reconcile()
        #expect(!client.sent.dropFirst(sent).contains { ($0.params as? ACPSessionListParams)?.cursor == "page-2" })
        #expect(model.sessions.contains { $0.remoteSessionId == "a" })
        await model.stop()
    }

    @MainActor
    @Test("a Load more answering after a filter change neither shows its rows nor moves the cursor")
    func loadMoreAfterFilterChange() async throws {
        let store = try temporaryStore()
        let client = indexClient()
        let gate = AsyncStream<Void>.makeStream()
        let pageTwoStarted = AsyncStream<Void>.makeStream()
        client.scriptAsync(method: "session/list") { request in
            let params = try #require(request.params as? ACPSessionListParams)
            if params.cursor == "page-2" {
                pageTwoStarted.continuation.yield()
                for await _ in gate.stream { break }
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "old-page-2", cwd: "/tmp/wt", index: .init(archived: false))],
                    nextCursor: "page-3"))
            }
            if params.meta?.sessionIndex.list.includeWorktrees == true {
                return try JSONEncoder().encode(ACPSessionListResult(
                    sessions: [.init(sessionId: "linked", cwd: "/tmp/wt", index: .init(archived: false))]))
            }
            return try JSONEncoder().encode(ACPSessionListResult(
                sessions: [.init(sessionId: "first", cwd: "/tmp/wt", index: .init(archived: false))],
                nextCursor: "page-2"))
        }
        let model = ACPSessionDiscoveryModel()
        await model.start(manager: manager(store: store, client: client), agentId: "claude", worktreeResolver: Self.projectResolver)
        let loadMore = Task { try await model.loadMore() }
        for await _ in pageTwoStarted.stream { break }
        try await model.setFilter(.init(includeLinkedWorktrees: true))
        gate.continuation.yield()
        try await loadMore.value
        #expect(model.sessions.map(\.remoteSessionId) == ["linked"])
        #expect(!model.canLoadMore)
        await model.stop()
    }

    @Test("a listed cwd matches an SSH worktree by its real path, never resolved on this Mac", arguments: [
        ("/srv/repo-wt2", "/srv/repo-wt2", true),
        ("/srv/repo-wt2", "/srv/repo-wt2/", true),
        ("/srv/repo-wt2", "/srv/repo", false),
        // /var is a symlink on the Mac, not necessarily on the remote host.
        ("/var/repo-wt2", "/var/repo-wt2", true),
    ])
    func remoteBrowserPathKeys(realPath: String, listedCWD: String, matches: Bool) {
        let worktreePath = RemotePath.virtual(host: "devbox", realPath: realPath)
        let key = { ACPSessionBrowserPaths.key($0, context: worktreePath) }
        #expect((key(worktreePath) == key(listedCWD)) == matches)
    }

    @Test("a listed cwd with symlinks resolved matches the local worktree path")
    func localBrowserPathKeys() throws {
        // The temporary directory is under /var, a symlink to /private/var.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try #require(realpath(directory.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(resolved != directory.path)
        #expect(ACPSessionBrowserPaths.key(directory.path, context: directory.path)
            == ACPSessionBrowserPaths.key(resolved, context: directory.path))
    }

    @Test("the highlight follows its session when live updates reorder the rows", arguments: [
        (2, ["a", "b"], ["c", "a", "b"], 3),
        (1, ["a", "b"], ["b"], 0),
        (0, ["a"], ["b", "a"], 0),
        (3, ["a", "b"], ["a"], 1),
    ])
    func selectionRemap(index: Int, old: [String], new: [String], expected: Int) {
        #expect(ACPSessionBrowserSelection.remapped(index, from: old, to: new) == expected)
    }

    @Test("row detail names the linked worktree, state and model; archived rows are browse-only", arguments: [
        ("wt", nil, nil, false, "date", true),
        ("wt2", "running", "gpt-5", false, "feature · Running · date · gpt-5", true),
        (nil, "requires_action", nil, false, "Not an Alas worktree: agent-wt · Needs input · date", false),
        ("wt", "idle", nil, false, "date", true),
        ("wt", "idle", nil, true, "Archived, unarchive to open · date", false),
    ] as [(String?, String?, String?, Bool, String, Bool)])
    func rowDetail(worktreeId: String?, state: String?, model: String?, archived: Bool, expected: String, opens: Bool) {
        let session = ACPDiscoveredSession(
            worktreeId: worktreeId, agentId: "codex", remoteSessionId: "s", cwd: "/tmp/agent-wt", title: "S",
            updatedAt: Date(timeIntervalSince1970: 0), additionalDirectories: [], localSessionId: nil,
            index: .init(archived: archived, model: model, state: state)
        )
        let capabilities = ACPSessionDiscoveryCapabilities(canLoad: true, canResume: false, canFork: false, canDelete: false)
        let canOpen = ACPSessionBrowserRowPolicy.canOpen(session, capabilities: capabilities)
        #expect(canOpen == opens)
        #expect(ACPSessionBrowserRowPolicy.detail(
            for: session, browsingWorktreeId: "wt", worktreeName: worktreeId == "wt2" ? "feature" : nil,
            canOpen: canOpen, formatDate: { _ in "date" }
        ) == expected)
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

    /// A listed session at `time` in /tmp/wt; usable from mock handlers,
    /// which run off the main actor.
    private nonisolated static func listedRow(_ id: String, _ time: String?) -> ACPAgentSessionInfo {
        .init(sessionId: id, cwd: "/tmp/wt", updatedAt: time, index: .init(archived: false))
    }

    /// A project with only the browsing worktree at /tmp/wt: enables the
    /// linked-worktree scope, and anything else is outside Alas.
    @MainActor
    private static func projectResolver(_ cwd: String) -> ACPSessionBrowserTarget? {
        ACPSessionBrowserPaths.key(cwd, context: "/tmp/wt") == ACPSessionBrowserPaths.key("/tmp/wt", context: "/tmp/wt")
            ? .init(worktreeId: "wt", persistence: nil) : nil
    }

    /// An agent with the client-neutral session index and a list subscription.
    private func indexClient() -> ACPMockClient {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            Data(#"""
            {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{},"delete":{}}},
             "_meta":{"sessionIndex":{"version":1,"capabilities":["sessionArchive","sessionRename","sessionListSubscribe","sessionWorktrees"]}}}
            """#.utf8)
        }
        client.script(method: "_session/list/subscribe") { _ in Data(#"{"subscriptionId":"sub-1"}"#.utf8) }
        client.script(method: "_session/list/unsubscribe") { _ in Data("{}".utf8) }
        return client
    }

    private func activeSessionClient(remoteSessionId: String) -> ACPMockClient {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            try JSONEncoder().encode(ACPInitializeResult(
                protocolVersion: 1,
                agentCapabilities: .init(
                    loadSession: true,
                    sessionCapabilities: .init(close: .init())
                ),
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
