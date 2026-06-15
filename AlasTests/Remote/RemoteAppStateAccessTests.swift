import Foundation
import Testing
import Darwin
@testable import Alas

@MainActor
struct RemoteAppStateAccessTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct ProjectMemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

    @Test func appStateRemoteServerPublishesAndRefreshesConfiguredAccessState() async throws {
        let port = try availableTCPPort()
        let state = AppState(store: MemoryStore())
        state.config.remote.enabled = true
        state.config.remote.port = port
        state.config.remote.allowedHosts = ["custom-a.example"]
        state.syncRemoteServer()
        defer {
            state.config.remote.enabled = false
            state.syncRemoteServer()
        }

        for _ in 0..<50 where state.remotePort != port {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.remotePort == port)
        #expect(state.remoteAdvertisedAddresses.contains {
            $0.host == "custom-a.example" && $0.port == port
        })
        #expect(try await statusCode(port: port, host: "custom-a.example", path: "/health") == 200)

        state.config.remote.allowedHosts = ["custom-b.example"]
        state.syncRemoteServer()

        #expect(state.remoteAdvertisedAddresses.contains {
            $0.host == "custom-b.example" && $0.port == port
        })
        #expect(!state.remoteAdvertisedAddresses.contains { $0.host == "custom-a.example" })
        #expect(try await statusCode(port: port, host: "custom-b.example", path: "/health") == 200)
        #expect(try await statusCode(port: port, host: "custom-a.example", path: "/health") == 403)

        let infoData = try await data(port: port, host: "custom-b.example", path: "/remote-info")
        let snapshot = try JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: infoData)
        #expect(snapshot.addresses == state.remoteAdvertisedAddresses)

        state.config.remote.enabled = false
        state.syncRemoteServer()
        #expect(state.remotePort == nil)
        #expect(state.remoteAdvertisedAddresses.isEmpty)
    }

    @Test func remoteRenameSessionUpdatesManualSessionTitleAndOpenTab() throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let worktreeId: String
        do {
            let state = makeRemoteRenameState()
            worktreeId = try #require(state.selectedWorktreeId)
            cleanupWorktreeId = worktreeId

            state.openNewACPSession(agentID: "test-agent")
            let tab = try #require(acpTabs(in: state).first)
            let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
            let session = try #require(manager.placeholderSession(id: tab.sessionId))

            let renamed = state.renameSession(for: tab.sessionId, title: "  Remote Title  ")

            #expect(renamed)
            #expect(session.title == "Remote Title")
            #expect(session.titleSource == .manual)
            #expect(state.tabs.tabs(forWorktree: worktreeId).first?.title == "Remote Title")
        }
    }

    @Test func remoteSessionSummariesCollapseRowsForSameRemoteSession() async throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let state = makeRemoteRenameState()
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let session = try #require(manager.placeholderSession(id: tab.sessionId))
        session.remoteSessionId = "remote-shared"
        try seedStoredSession(
            id: tab.sessionId,
            title: "New session",
            titleSource: .placeholder,
            in: manager
        )
        try seedStoredSession(
            id: "historical-copy",
            title: "Actual Remote Title",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            in: manager
        )

        let summaries = await state.sessionSummaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.id == tab.sessionId)
        #expect(summaries.first?.title == "Actual Remote Title")
    }

    @Test func remoteSessionSummariesPreferLivePlaceholderOverStoredDuplicate() async throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let state = makeRemoteRenameState()
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        let session = try #require(manager.placeholderSession(id: tab.sessionId))
        session.remoteSessionId = "remote-shared"
        let mirrorOwner = try ACPSessionManager(
            worktreeId: worktreeId,
            worktreePath: "/tmp/mirror-owner",
            store: ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path),
            instanceId: "mirror-owner",
            pid: Int64(getpid())
        )
        _ = try #require(mirrorOwner.placeholderSession(id: tab.sessionId))
        #expect(mirrorOwner.acquireWriterLease(sessionId: tab.sessionId))
        #expect(manager.isMirror(sessionId: tab.sessionId))
        defer {
            mirrorOwner.releaseWriterLease(sessionId: tab.sessionId)
        }
        try seedStoredSession(
            id: tab.sessionId,
            title: "New session",
            titleSource: .placeholder,
            updatedAt: 1,
            lastOpenedAt: 1,
            in: manager
        )
        try seedStoredSession(
            id: "historical-copy",
            title: "Actual Remote Title",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            updatedAt: 2,
            lastOpenedAt: 2,
            in: manager
        )

        let summaries = await state.sessionSummaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.id == tab.sessionId)
        #expect(summaries.first?.title == "Actual Remote Title")
    }

    @Test func remoteSessionSummariesKeepDifferentAgentsWithSameRemoteSessionId() async throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let state = makeRemoteRenameState()
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        try seedStoredSession(
            id: "codex-session",
            agentId: "codex",
            title: "Codex Session",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            in: manager
        )
        try seedStoredSession(
            id: "claude-session",
            agentId: "claude",
            title: "Claude Session",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            in: manager
        )

        let summaries = await state.sessionSummaries()

        #expect(summaries.map(\.id).contains("codex-session"))
        #expect(summaries.map(\.id).contains("claude-session"))
    }

    @Test func remoteRenameSessionRejectsEmptyAndUnknownSession() throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let worktreeId: String
        do {
            let state = makeRemoteRenameState()
            worktreeId = try #require(state.selectedWorktreeId)
            cleanupWorktreeId = worktreeId
            state.openNewACPSession(agentID: "test-agent")
            let tab = try #require(acpTabs(in: state).first)
            let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
            let session = try #require(manager.placeholderSession(id: tab.sessionId))

            #expect(!state.renameSession(for: tab.sessionId, title: " \n\t "))
            #expect(!state.renameSession(for: "missing", title: "Remote Title"))
            #expect(session.title == "New session")
            #expect(session.titleSource == .placeholder)
            #expect(state.tabs.tabs(forWorktree: worktreeId).first?.title == "New session")
        }
    }

    @Test func remoteRenameSessionUpdatesNonLiveRecentSession() throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let worktreeId: String
        let sessionId = "recent-\(UUID().uuidString)"
        do {
            let state = makeRemoteRenameState()
            worktreeId = try #require(state.selectedWorktreeId)
            cleanupWorktreeId = worktreeId
            state.openNewACPSession(agentID: "test-agent")
            let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
            try seedStoredSession(id: sessionId, title: "Recent", in: manager)

            let renamed = state.renameSession(for: sessionId, title: "Recent Remote")

            #expect(renamed)
            let session = try #require(manager.liveSession(for: sessionId))
            #expect(session.title == "Recent Remote")
            #expect(session.titleSource == .manual)
        }
        do {
            let store = try ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path)
            let row = try #require(try store.loadSession(id: sessionId))
            #expect(row.title == "Recent Remote")
            #expect(row.titleSource == .manual)
        }
    }

    @Test func remoteRenameSessionRejectsArchivedSession() throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let worktreeId: String
        let sessionId = "archived-\(UUID().uuidString)"
        do {
            let state = makeRemoteRenameState()
            worktreeId = try #require(state.selectedWorktreeId)
            cleanupWorktreeId = worktreeId
            state.openNewACPSession(agentID: "test-agent")
            let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
            try seedStoredSession(id: sessionId, title: "Archived", archived: true, in: manager)

            #expect(!state.renameSession(for: sessionId, title: "Remote Title"))
            #expect(manager.liveSession(for: sessionId) == nil)
        }
    }

    @Test func remoteRenameSessionUpdatesMirrorSessionWithoutWriterLease() throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let worktreeId: String
        let sessionId: String
        do {
            let state = makeRemoteRenameState()
            worktreeId = try #require(state.selectedWorktreeId)
            cleanupWorktreeId = worktreeId
            state.openNewACPSession(agentID: "test-agent")
            let tab = try #require(acpTabs(in: state).first)
            sessionId = tab.sessionId
            let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
            let session = try #require(manager.placeholderSession(id: sessionId))
            let mirrorOwner = try ACPSessionManager(
                worktreeId: worktreeId,
                worktreePath: "/tmp/mirror-owner",
                store: ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path),
                instanceId: "mirror-owner",
                pid: Int64(getpid())
            )
            let writerSession = try #require(mirrorOwner.placeholderSession(id: sessionId))
            #expect(mirrorOwner.acquireWriterLease(sessionId: sessionId))
            #expect(manager.isMirror(sessionId: sessionId))

            let renamed = state.renameSession(for: sessionId, title: "Mirror Title")

            #expect(renamed)
            #expect(session.title == "Mirror Title")
            #expect(session.titleSource == .manual)
            #expect(state.tabs.tabs(forWorktree: worktreeId).first?.title == "Mirror Title")
            #expect(writerSession.title == "New session")
            writerSession.autoRunEnabled = true
            mirrorOwner.persist(writerSession)
            mirrorOwner.releaseWriterLease(sessionId: sessionId)
        }

        do {
            let store = try ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path)
            let row = try #require(try store.loadSession(id: sessionId))
            #expect(row.title == "Mirror Title")
            #expect(row.titleSource == .manual)
            #expect(row.autoRun)
        }
    }

    private func statusCode(port: UInt16, host: String, path: String) async throws -> Int? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.setValue(host, forHTTPHeaderField: "Host")
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode
    }

    private func data(port: UInt16, host: String, path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.setValue(host, forHTTPHeaderField: "Host")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func availableTCPPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: bound.sin_port)
    }

    private func makeRemoteRenameState() -> AppState {
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: "Project",
            path: "/tmp/project-\(UUID().uuidString)",
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let worktree = Worktree(
            id: UUID().uuidString,
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: project.path),
            status: .clean,
            lastActivity: Date()
        )
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        state.config.changes.aiToolId = "test-agent"
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [
                AgentDefinition(
                    id: "test-agent",
                    displayName: "Test Agent",
                    binary: "test-agent",
                    binaryOverride: nil,
                    promptModeArgs: [],
                    bypassPermissionsFlag: nil,
                    extraTerminalArgs: nil,
                    isBuiltin: false,
                    isEnabled: true,
                    builtinLogoAssetName: nil
                ),
            ],
            installedIds: ["test-agent"]
        )
        return state
    }

    private func acpTabs(in state: AppState) -> [ACPSessionTabState] {
        guard let worktreeId = state.selectedWorktreeId else { return [] }
        return state.tabs.tabs(forWorktree: worktreeId).compactMap { tab in
            if case .acpSession(let tabState) = tab {
                return tabState
            }
            return nil
        }
    }

    private func seedStoredSession(
        id: String,
        agentId: String = "test-agent",
        title: String,
        titleSource: ACPSessionTitleSource = .placeholder,
        remoteSessionId: String? = nil,
        archived: Bool = false,
        updatedAt: Int64? = nil,
        lastOpenedAt: Int64? = nil,
        in manager: ACPSessionManager
    ) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try manager.store.upsertSession(ACPSessionRow(
            id: id,
            agentId: agentId,
            title: title,
            titleSource: titleSource,
            remoteSessionId: remoteSessionId,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: updatedAt ?? now,
            lastOpenedAt: lastOpenedAt ?? now,
            archived: archived
        ))
        manager.refreshRecent()
    }

    private func cleanupRemoteRenameFiles(worktreeId: String) {
        try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId))
        let db = Paths.acpSessionsDB(forWorktreeId: worktreeId)
        try? FileManager.default.removeItem(at: db)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-shm"))
    }
}
