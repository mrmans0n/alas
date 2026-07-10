import Foundation
import Testing
@testable import Alas

@Suite("ACP session discovery")
struct ACPSessionDiscoveryTests {
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
        #expect(model.sessions.first?.title == "Local title")
        #expect(model.sessions.first?.localSessionId == "local-1")
        #expect(model.canLoadMore)

        try await model.loadMore()
        #expect(model.sessions.map(\.remoteSessionId) == ["remote-1", "remote-2"])
        #expect(!model.canLoadMore)
        #expect(client.shutdownCount == 0)
        await model.stop()
        #expect(client.shutdownCount == 1)
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
    func materializationRejectsAdditionalDirectories() throws {
        let store = try temporaryStore()
        let manager = manager(store: store, client: ACPMockClient())
        let discovered = ACPDiscoveredSession(
            agentId: "claude",
            remoteSessionId: "remote-extra-roots",
            cwd: "/tmp/wt",
            title: "Shared roots",
            updatedAt: nil,
            additionalDirectories: ["/tmp/shared"],
            localSessionId: nil
        )

        #expect(manager.materializeDiscoveredSession(discovered) == nil)
        #expect(try store.loadSession(agentId: "claude", remoteSessionId: "remote-extra-roots") == nil)
    }

    private func temporaryStore() throws -> ACPSessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-discovery-\(UUID().uuidString).sqlite")
        return try ACPSessionStore(path: url.path)
    }

    @MainActor
    private func manager(store: ACPSessionStore, client: ACPMockClient) -> ACPSessionManager {
        ACPSessionManager(
            worktreeId: "wt",
            worktreePath: "/tmp/wt",
            store: store,
            setupEvaluator: { _ in .ready },
            connectionFactory: { _ in ACPConnection(client: client) }
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
