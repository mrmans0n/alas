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
        let spacesFile: SpacesFile?

        init(projectsFile: ProjectsFile, spacesFile: SpacesFile? = nil) {
            self.projectsFile = projectsFile
            self.spacesFile = spacesFile
        }

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == SpacesFile.self {
                return spacesFile as? T
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

    @Test func remoteRenameSessionUpdatesManualSessionTitleAndOpenTab() async throws {
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
        try await seedStoredSession(
            id: tab.sessionId,
            title: "New session",
            titleSource: .placeholder,
            updatedAt: 1,
            in: manager
        )
        try await seedStoredSession(
            id: "historical-copy",
            title: "Actual Remote Title",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            updatedAt: 2,
            in: manager
        )

        let summaries = await state.sessionSummaries()

        #expect(summaries.count == 1)
        #expect(summaries.first?.id == tab.sessionId)
        #expect(summaries.first?.title == "Actual Remote Title")
        #expect(summaries.first?.isActive == true)
        #expect(summaries.first?.updatedAt == 2)
    }

    @Test func remoteSessionSummariesMarkStoredRowsWithoutTabsInactive() async throws {
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
        try await seedStoredSession(
            id: "historical-\(UUID().uuidString)",
            title: "Historical",
            titleSource: .manual,
            updatedAt: 42,
            in: manager
        )

        let summaries = await state.sessionSummaries()
        let historical = try #require(summaries.first { $0.title == "Historical" })

        #expect(!historical.isActive)
        #expect(historical.projectId == state.projects.first?.id)
        #expect(historical.updatedAt == 42)
    }

    @Test func openingUncachedStoredSessionUsesPersistedTitleForTab() async throws {
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
        let id = "uncached-\(UUID().uuidString)"
        let now = Int64(Date().timeIntervalSince1970)
        try await manager.persistence.upsertSession(.init(
            id: id,
            agentId: "test-agent",
            title: "Persisted Title",
            titleSource: .manual,
            currentModel: nil,
            currentMode: nil,
            autoRun: false,
            createdAt: now,
            updatedAt: now,
            lastOpenedAt: now,
            archived: false
        ))
        #expect(!manager.sessionRows.contains { $0.id == id })

        await state.openExistingACPSession(sessionId: id)

        let tab = try #require(acpTabs(in: state).first { $0.sessionId == id })
        #expect(tab.title == "Persisted Title")
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
        await manager.flushPersistence()
        let mirrorOwner = try ACPSessionManager(
            worktreeId: worktreeId,
            worktreePath: "/tmp/mirror-owner",
            store: ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path),
            instanceId: "mirror-owner",
            pid: Int64(getpid())
        )
        _ = try #require(mirrorOwner.placeholderSession(id: tab.sessionId))
        #expect(await mirrorOwner.acquireWriterLease(sessionId: tab.sessionId))
        #expect(!(await manager.acquireWriterLease(sessionId: tab.sessionId)))
        #expect(manager.isMirror(sessionId: tab.sessionId))
        try await seedStoredSession(
            id: tab.sessionId,
            title: "New session",
            titleSource: .placeholder,
            updatedAt: 1,
            lastOpenedAt: 1,
            in: manager
        )
        try await seedStoredSession(
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
        await mirrorOwner.releaseWriterLease(sessionId: tab.sessionId)
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
        try await seedStoredSession(
            id: "codex-session",
            agentId: "codex",
            title: "Codex Session",
            titleSource: .manual,
            remoteSessionId: "remote-shared",
            in: manager
        )
        try await seedStoredSession(
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

    @Test func remoteRenameSessionRejectsEmptyAndUnknownSession() async throws {
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

    @Test func remoteRenameSessionUpdatesNonLiveRecentSession() async throws {
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
            try await seedStoredSession(id: sessionId, title: "Recent", in: manager)

            let renamed = state.renameSession(for: sessionId, title: "Recent Remote")

            #expect(renamed)
            let session = try #require(manager.liveSession(for: sessionId))
            #expect(session.title == "Recent Remote")
            #expect(session.titleSource == .manual)
            let summaries = await state.sessionSummaries()
            #expect(summaries.first(where: { $0.id == sessionId })?.isActive == false)
        }
        do {
            let store = try ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path)
            let row = try #require(try store.loadSession(id: sessionId))
            #expect(row.title == "Recent Remote")
            #expect(row.titleSource == .manual)
        }
    }

    @Test func remoteRenameSessionRejectsArchivedSession() async throws {
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
            try await seedStoredSession(id: sessionId, title: "Archived", archived: true, in: manager)

            #expect(!state.renameSession(for: sessionId, title: "Remote Title"))
            #expect(manager.liveSession(for: sessionId) == nil)
        }
    }

    @Test func remoteRenameSessionUpdatesMirrorSessionWithoutWriterLease() async throws {
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
            await manager.flushPersistence()
            let mirrorOwner = try ACPSessionManager(
                worktreeId: worktreeId,
                worktreePath: "/tmp/mirror-owner",
                store: ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path),
                instanceId: "mirror-owner",
                pid: Int64(getpid())
            )
            let writerSession = try #require(mirrorOwner.placeholderSession(id: sessionId))
            #expect(await mirrorOwner.acquireWriterLease(sessionId: sessionId))
            #expect(!(await manager.acquireWriterLease(sessionId: sessionId)))
            #expect(manager.isMirror(sessionId: sessionId))

            let renamed = state.renameSession(for: sessionId, title: "Mirror Title")
            await manager.flushPersistence()

            #expect(renamed)
            #expect(session.title == "Mirror Title")
            #expect(session.titleSource == .manual)
            #expect(state.tabs.tabs(forWorktree: worktreeId).first?.title == "Mirror Title")
            #expect(writerSession.title == "New session")
            writerSession.autoRunEnabled = true
            mirrorOwner.persist(writerSession)
            await mirrorOwner.releaseWriterLease(sessionId: sessionId)
        }

        do {
            let store = try ACPSessionStore(path: Paths.acpSessionsDB(forWorktreeId: worktreeId).path)
            let row = try #require(try store.loadSession(id: sessionId))
            #expect(row.title == "Mirror Title")
            #expect(row.titleSource == .manual)
            #expect(row.autoRun)
        }
    }

    @Test func remoteWorktreesIncludeVisibleProjectWorktrees() async throws {
        let state = makeRemoteRenameState()
        let worktreeId = try #require(state.selectedWorktreeId)

        let worktrees = await state.remoteWorktrees()

        #expect(worktrees.contains { $0.id == worktreeId })
        #expect(worktrees.first { $0.id == worktreeId }?.projectName == "test")
    }

    @Test func remoteWorktreesFilterTransientOperationStates() async throws {
        let state = makeRemoteRenameState()
        let baseWorktree = try #require(state.selectedWorktreeId.flatMap { selected in
            state.projectsManager.visibleWorktrees(projectId: state.projects[0].id).first { $0.id == selected }
        })
        let creating = remoteWorktreeCopy(baseWorktree, id: "creating", name: "creating")
        let deleting = remoteWorktreeCopy(baseWorktree, id: "deleting", name: "deleting")
        let createFailed = remoteWorktreeCopy(baseWorktree, id: "create-failed", name: "create-failed")
        let deleteFailed = remoteWorktreeCopy(baseWorktree, id: "delete-failed", name: "delete-failed")
        state.projectsManager.insertOptimisticWorktree(creating)
        state.projectsManager.insertOptimisticWorktree(deleting)
        state.projectsManager.insertOptimisticWorktree(createFailed)
        state.projectsManager.insertOptimisticWorktree(deleteFailed)
        state.projectsManager.setOperationState(id: creating.id, state: .creating)
        state.projectsManager.setOperationState(id: deleting.id, state: .deleting)
        state.projectsManager.setOperationState(
            id: createFailed.id,
            state: .createFailed(
                projectId: createFailed.projectId,
                message: "failed",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .none,
                issueAttachment: nil
            )
        )
        state.projectsManager.setOperationState(id: deleteFailed.id, state: .deleteFailed(message: "failed"))

        let ids = Set(await state.remoteWorktrees().map(\.id))

        #expect(!ids.contains(creating.id))
        #expect(!ids.contains(deleting.id))
        #expect(!ids.contains(createFailed.id))
        #expect(ids.contains(deleteFailed.id))
    }

    @Test func remoteAgentsIncludeEnabledACPCapableAgentsOnly() async throws {
        let state = makeRemoteRenameState()
        let customAgent = AgentDefinition(
            id: "custom-agent",
            displayName: "Custom Agent",
            binary: "custom-agent",
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil),
                "codex": BuiltinAgentState(isEnabled: false, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [customAgent],
            installedIds: ["claude", "codex", "custom-agent"]
        )
        let claudeName = try #require(state.agentRegistry.enabled().first { $0.id == "claude" }?.displayName)

        let agents = state.remoteAgents()

        #expect(agents == [RemoteAgentOption(id: "claude", name: claudeName, isDefault: true)])
    }

    @Test func remoteAgentsPreserveNativeACPLaunchOrder() async throws {
        let state = makeRemoteRenameState()
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: false, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [],
            installedIds: ["codex", "gemini"]
        )

        let agents = state.remoteAgents()

        #expect(agents.map(\.id) == ["gemini", "codex"])
        #expect(agents.map(\.isDefault) == [true, false])
    }

    @Test func createRemoteSessionSelectsWorktreeAppendsTabAndReturnsSummary() async throws {
        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }

        let state = makeRemoteRenameState()
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [],
            installedIds: ["claude"]
        )
        var scheduledAttach: (managerWorktreeId: String, sessionId: String)?
        state.remoteSessionAttachScheduler = { (manager: ACPSessionManager, sessionId: ACPSession.ID) in
            scheduledAttach = (manager.worktreeId, sessionId)
        }
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId

        let result = await state.createRemoteSession(worktreeId: worktreeId, agentId: "claude")

        guard case .success(let summary) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(summary.agentId == "claude")
        #expect(summary.title == "New session")
        #expect(summary.worktree?.worktreeName != nil)
        #expect(summary.worktree?.metricsAvailable == false)
        #expect(state.selectedWorktreeId == worktreeId)
        let tab = try #require(firstACPTab(in: state, worktreeId: worktreeId))
        #expect(tab.sessionId == summary.id)
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == tab.id)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        #expect(manager.liveSession(for: summary.id) != nil)
        let row = try #require(manager.sessionRows.first { $0.id == summary.id })
        #expect(summary.projectId == state.projects.first?.id)
        #expect(summary.updatedAt == row.updatedAt)
        #expect(scheduledAttach?.managerWorktreeId == worktreeId)
        #expect(scheduledAttach?.sessionId == summary.id)
    }

    @Test func createRemoteSessionSwitchesSpaceBeforeSelectingWorktree() async throws {
        var cleanupWorktreeIds: [String] = []
        defer {
            cleanupWorktreeIds.forEach(cleanupRemoteRenameFiles)
        }

        let firstProject = ProjectConfig(
            id: UUID().uuidString,
            name: "first",
            path: "/tmp/first-\(UUID().uuidString)",
            color: "blue",
            addedAt: Date()
        )
        let secondProject = ProjectConfig(
            id: UUID().uuidString,
            name: "second",
            path: "/tmp/second-\(UUID().uuidString)",
            color: "green",
            addedAt: Date()
        )
        let firstSpaceId = "space-\(UUID().uuidString)"
        let secondSpaceId = "space-\(UUID().uuidString)"
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: firstSpaceId,
            spaces: [
                SpaceConfig(
                    id: firstSpaceId,
                    name: "First",
                    emoji: "1",
                    projectIds: [firstProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date()
                ),
                SpaceConfig(
                    id: secondSpaceId,
                    name: "Second",
                    emoji: "2",
                    projectIds: [secondProject.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date()
                ),
            ]
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [firstProject, secondProject]),
            spacesFile: spaces
        ))
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [],
            installedIds: ["claude"]
        )
        var scheduledAttach: (managerWorktreeId: String, sessionId: String)?
        state.remoteSessionAttachScheduler = { manager, sessionId in
            scheduledAttach = (manager.worktreeId, sessionId)
        }
        let firstWorktree = Worktree(
            id: UUID().uuidString,
            projectId: firstProject.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: firstProject.path),
            status: .clean,
            lastActivity: Date()
        )
        let secondWorktree = Worktree(
            id: UUID().uuidString,
            projectId: secondProject.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: secondProject.path),
            status: .clean,
            lastActivity: Date()
        )
        cleanupWorktreeIds = [firstWorktree.id, secondWorktree.id]
        state.projectsManager.insertOptimisticWorktree(firstWorktree)
        state.projectsManager.insertOptimisticWorktree(secondWorktree)
        state.selectedWorktreeId = firstWorktree.id

        let result = await state.createRemoteSession(worktreeId: secondWorktree.id, agentId: "claude")

        guard case .success(let summary) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(state.spacesManager.activeSpaceId == secondSpaceId)
        #expect(state.selectedWorktreeId == secondWorktree.id)
        #expect(state.spacesManager.space(id: secondSpaceId)?.lastSelectedWorktreeId == secondWorktree.id)
        #expect(summary.worktree?.metricsAvailable == false)
        let tab = try #require(firstACPTab(in: state, worktreeId: secondWorktree.id))
        #expect(tab.sessionId == summary.id)
        #expect(state.tabs.activeTabId(forWorktree: secondWorktree.id) == tab.id)
        #expect(scheduledAttach?.managerWorktreeId == secondWorktree.id)
        #expect(scheduledAttach?.sessionId == summary.id)
    }

    @Test func createRemoteSessionRejectsMissingWorktree() async throws {
        let state = makeRemoteRenameState()

        let result = await state.createRemoteSession(worktreeId: "missing", agentId: "claude")

        #expect(result == .failure("Worktree is no longer available."))
    }

    @Test func createRemoteSessionRejectsMissingAgent() async throws {
        let state = makeRemoteRenameState()
        let worktreeId = try #require(state.selectedWorktreeId)

        let result = await state.createRemoteSession(worktreeId: worktreeId, agentId: "missing")

        #expect(result == .failure("Agent is no longer available."))
    }

    @Test func createRemoteSessionRejectsDisabledOrNonACPAgent() async throws {
        let state = makeRemoteRenameState()
        let customAgent = AgentDefinition(
            id: "custom-agent",
            displayName: "Custom Agent",
            binary: "custom-agent",
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: false, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [customAgent],
            installedIds: ["claude", "custom-agent"]
        )
        let worktreeId = try #require(state.selectedWorktreeId)

        let disabled = await state.createRemoteSession(worktreeId: worktreeId, agentId: "claude")
        let nonACP = await state.createRemoteSession(worktreeId: worktreeId, agentId: "custom-agent")

        #expect(disabled == .failure("Agent is no longer available."))
        #expect(nonACP == .failure("Agent is no longer available."))
    }

    @Test func remoteProjectsPreserveConfiguredProjectIDsAndNames() async {
        let firstProject = ProjectConfig(
            id: "project-first",
            name: "First Project",
            path: "/tmp/first-project",
            color: "blue",
            addedAt: Date()
        )
        let secondProject = ProjectConfig(
            id: "project-second",
            name: "Second Project",
            path: "/tmp/second-project",
            color: "green",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [firstProject, secondProject])
        ))

        let projects = await state.remoteProjects()

        #expect(projects == [
            RemoteProjectOption(id: "project-first", name: "First Project"),
            RemoteProjectOption(id: "project-second", name: "Second Project"),
        ])
    }

    @Test func remoteBranchesReturnsBranchesAndPrefersMain() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let project = ProjectConfig(
            id: "project-branches",
            name: "Branch Project",
            path: repository.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))

        let result = await state.remoteBranches(projectId: project.id)

        guard case let .success(branches, preferredBase) = result else {
            Issue.record("expected branch list success, got \(result)")
            return
        }
        #expect(branches.contains("main"))
        #expect(branches.contains("feature/remote"))
        #expect(preferredBase == "main")
    }

    @Test func remoteBranchesRejectsMissingProject() async {
        let state = AppState(store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [])))

        let result = await state.remoteBranches(projectId: "missing-project")

        #expect(result == .failure("Repository is no longer available."))
    }

    @Test func remoteSessionsProviderCreatesWorktreeSessionAndFocusesIt() async throws {
        let repository = try await makeRemoteBranchesRepository()
        let worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-create-root-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: worktreeRoot)
            try? FileManager.default.removeItem(at: repository)
        }
        let project = ProjectConfig(
            id: "project-remote-create",
            name: "Remote Create",
            path: repository.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))
        state.config.worktrees.rootPath = worktreeRoot.path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}-{branch}"
        state.agentRegistry = enabledClaudeRegistry()
        state.remoteSessionAttachScheduler = { _, _ in }

        let provider: RemoteSessionsProvider = state
        let result = await provider.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "feature/phone",
            agentId: "claude"
        )

        guard case let .success(summary) = result else {
            Issue.record("expected combined creation success, got \(result)")
            return
        }
        let worktree = try #require(summary.worktree)
        let worktreeId = Worktree.makeId(path: URL(fileURLWithPath: worktree.path))
        defer { cleanupRemoteRenameFiles(worktreeId: worktreeId) }
        #expect(worktree.branch == "feature/phone")
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(state.selectedWorktreeId == worktreeId)
        let tab = try #require(firstACPTab(in: state, worktreeId: worktreeId))
        #expect(tab.sessionId == summary.id)
        #expect(state.tabs.activeTabId(forWorktree: worktreeId) == tab.id)
    }

    @Test func remoteCreateWorktreeSessionRejectsMissingProjectAndInvalidBranchSafely() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let project = ProjectConfig(
            id: "project-remote-reject",
            name: "Remote Reject",
            path: repository.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))
        state.agentRegistry = enabledClaudeRegistry()
        var branchLookupCount = 0
        state.remoteWorktreeBranchLoader = { _ in
            branchLookupCount += 1
            return ["main"]
        }

        let missing = await state.createRemoteWorktreeSession(
            projectId: "missing",
            base: "main",
            branch: "feature/phone",
            agentId: "claude"
        )
        let invalid = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "bad..branch",
            agentId: "claude"
        )
        let invalidAgent = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "feature/phone",
            agentId: "missing-agent"
        )
        #expect(branchLookupCount == 0)

        let missingBase = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "missing-base",
            branch: "feature/phone",
            agentId: "claude"
        )
        let invalidBase = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "bad..base",
            branch: "feature/phone",
            agentId: "claude"
        )

        #expect(missing == .failure(
            stage: .worktree,
            message: "Repository is no longer available.",
            worktreeId: nil
        ))
        #expect(invalid == .failure(
            stage: .worktree,
            message: "Could not create worktree.",
            worktreeId: nil
        ))
        #expect(invalidAgent == .failure(
            stage: .worktree,
            message: "Could not create worktree.",
            worktreeId: nil
        ))
        #expect(missingBase == .failure(
            stage: .worktree,
            message: "Could not create worktree.",
            worktreeId: nil
        ))
        #expect(invalidBase == .failure(
            stage: .worktree,
            message: "Could not create worktree.",
            worktreeId: nil
        ))
    }

    @Test func remoteCreateWorktreeSessionRejectsRemoteDestinationBeforeCreating() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer {
            RemoteHostRegistry.shared.unregister(root: repository.path)
            try? FileManager.default.removeItem(at: repository)
        }
        let project = ProjectConfig(
            id: "project-remote-collision",
            name: "Remote Collision",
            path: repository.path,
            color: "blue",
            addedAt: Date(),
            host: "remote.test"
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))
        state.agentRegistry = enabledClaudeRegistry()
        state.config.worktrees.rootPath = "/remote worktrees"
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}-{branch}"
        state.remoteWorktreeBranchLoader = { _ in ["main"] }
        state.remoteWorktreeDestinationPreparer = { _, destination in destination }
        var command: (host: String, cwd: String?, command: String)?
        state.remoteWorktreeCommandRunner = { host, cwd, commandToRun in
            command = (host, cwd, commandToRun)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        var sessionCreationAttempted = false
        state.remoteSessionCreator = { _, _ in
            sessionCreationAttempted = true
            return .failure("should not be reached")
        }

        let result = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "feature/phone",
            agentId: "claude"
        )

        #expect(result == .failure(
            stage: .worktree,
            message: "A worktree already exists at this path.",
            worktreeId: nil
        ))
        #expect(command?.host == "remote.test")
        #expect(command?.cwd == nil)
        #expect(command?.command == "test -e '/remote worktrees/Remote Collision-feature-phone'")
        #expect(state.projectsManager.visibleWorktrees(projectId: project.id).isEmpty)
        #expect(!sessionCreationAttempted)
    }

    @Test func remoteCreateWorktreeSessionPreservesWorktreeWhenSessionCreationFails() async throws {
        let repository = try await makeRemoteBranchesRepository()
        let worktreeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-session-failure-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: worktreeRoot)
            try? FileManager.default.removeItem(at: repository)
        }
        let project = ProjectConfig(
            id: "project-remote-session-failure",
            name: "Remote Session Failure",
            path: repository.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(
            projectsFile: ProjectsFile(projects: [project])
        ))
        state.config.worktrees.rootPath = worktreeRoot.path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}-{branch}"
        state.agentRegistry = enabledClaudeRegistry()
        state.remoteSessionCreator = { _, _ in .failure("internal details") }

        let result = await state.createRemoteWorktreeSession(
            projectId: project.id,
            base: "main",
            branch: "feature/phone",
            agentId: "claude"
        )

        guard case let .failure(stage, message, worktreeId) = result else {
            Issue.record("expected session creation failure, got \(result)")
            return
        }
        #expect(stage == .session)
        #expect(message == "Worktree created, but the session could not be created.")
        let createdWorktreeId = try #require(worktreeId)
        defer { cleanupRemoteRenameFiles(worktreeId: createdWorktreeId) }
        let createdWorktree = try #require(state.worktree(withId: createdWorktreeId))
        #expect(FileManager.default.fileExists(atPath: createdWorktree.path.path))
    }

    @Test func remoteChangeListReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteChangeList(sessionId: "no-such-session")
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileDiffReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileDiff(sessionId: "no-such-session", path: "a.txt")
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileTreeReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileTree(sessionId: "no-such-session", path: nil)
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileContentsReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileContents(sessionId: "no-such-session", path: "a.txt")
        #expect(result == .failure(reason: .sessionUnknown, byteSize: nil, message: nil))
    }

    @Test func remoteChangeListReportsWorktreeUnavailableWhenProjectAndWorktreeReturnsNil() async throws {
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

        // Simulate worktree deletion while manager still holds session reference.
        // First ensure the session is in the manager's rows.
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))
        #expect(manager.sessionRows.contains(where: { $0.id == tab.sessionId }))

        // Now delete the worktree from projectsManager, making projectAndWorktree return nil
        let project = try #require(state.projects.first)
        let visibleWorktrees = state.projectsManager.visibleWorktrees(projectId: project.id)
        for wt in visibleWorktrees {
            state.projectsManager.removeOptimisticWorktree(id: wt.id, projectId: project.id)
        }

        let result = await state.remoteChangeList(sessionId: tab.sessionId)
        #expect(result == .failure(reason: .worktreeUnavailable, message: nil))
    }

    @Test func remoteFileContentsAndDiffRejectAGitignoredFile() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "secret.env\n".write(
            to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "TOKEN=abc\n".write(
            to: repository.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)
        let contentsResult = await state.remoteFileContents(sessionId: tab.sessionId, path: "secret.env")
        #expect(contentsResult == .failure(reason: .pathRejected, byteSize: nil, message: nil))

        let diffResult = await state.remoteFileDiff(sessionId: tab.sessionId, path: "secret.env")
        #expect(diffResult == .failure(reason: .pathRejected, message: nil))
    }

    /// `normalizedRelativePath` used to trim the path before resolving it,
    /// which happened to close this bypass for the wrong reason (a real
    /// file legitimately named with leading/trailing whitespace would have
    /// been silently misrouted to a different, trimmed path). Now that
    /// resolution preserves the client's exact bytes, the padded path
    /// simply doesn't name the real `secret.env` file — it fails to resolve
    /// to anything, rather than being caught by the ignore check — so the
    /// outcome shape changes (not-found / empty diff instead of path
    /// rejected), but the actual security guarantee (the real, ignored
    /// content is never served) must still hold.
    @Test func remoteFileContentsAndDiffRejectAGitignoredFileWithAWhitespacePaddedPath() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "secret.env\n".write(
            to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "TOKEN=abc\n".write(
            to: repository.appendingPathComponent("secret.env"), atomically: true, encoding: .utf8)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)
        let contentsResult = await state.remoteFileContents(sessionId: tab.sessionId, path: " secret.env")
        if case .success(let text, _) = contentsResult {
            Issue.record("secret content must never be served for a whitespace-padded path, got: \(text)")
        }
        #expect(contentsResult == .failure(reason: .notFound, byteSize: nil, message: nil))

        let diffResult = await state.remoteFileDiff(sessionId: tab.sessionId, path: " secret.env")
        if case .success(let hunks, _) = diffResult {
            let text = hunks.flatMap(\.lines).map(\.text).joined()
            #expect(!text.contains("abc"), "secret content must never be served for a whitespace-padded path")
        }
    }

    /// A TRACKED symlink whose own name doesn't match any ignore pattern
    /// (`public-env`) but whose target does (`.env`) must not have the
    /// target's content served. `isPathIgnored("public-env")` correctly
    /// reports "not ignored" — the check runs against the alias's own name,
    /// which is the whole point of a symlink alias — so the read/diff path
    /// itself must independently reject any symlink rather than trusting
    /// the ignore check alone.
    @Test func remoteFileContentsAndDiffRejectATrackedSymlinkAliasingAGitignoredTarget() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try ".env\n".write(
            to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "TOKEN=super-secret\n".write(
            to: repository.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repository.appendingPathComponent("public-env"),
            withDestinationURL: repository.appendingPathComponent(".env"))
        _ = try await Process.git(["add", "public-env"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "-m", "add public-env symlink"], cwd: repository)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)

        // Confirm the premise: the alias's own name is genuinely not ignored.
        let ignored = try await GitService().isPathIgnored(worktreePath: repository, path: "public-env")
        #expect(!ignored)

        let contentsResult = await state.remoteFileContents(sessionId: tab.sessionId, path: "public-env")
        #expect(contentsResult == .failure(reason: .notFound, byteSize: nil, message: nil))
        if case .success(let text, _) = contentsResult {
            Issue.record("secret content must never be served through a symlink alias, got: \(text)")
        }

        let diffResult = await state.remoteFileDiff(sessionId: tab.sessionId, path: "public-env")
        #expect(diffResult == .failure(reason: .notFound, message: nil))
        if case .success(let hunks, _) = diffResult {
            let text = hunks.flatMap(\.lines).map(\.text).joined()
            #expect(!text.contains("super-secret"), "secret content must never be served through a symlink alias diff")
        }
    }

    @Test func remoteFileContentsAndDiffServeATrackedFileNormally() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "hello\n".write(to: repository.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "visible.txt"], cwd: repository)
        _ = try await Process.git(["commit", "-m", "add visible file"], cwd: repository)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)

        let contentsResult = await state.remoteFileContents(sessionId: tab.sessionId, path: "visible.txt")
        #expect(contentsResult == .success(text: "hello\n", truncated: false))
    }

    /// Reproduces the race `remoteWorktreeContext` used to lose: a manager's
    /// own background `refreshRecentNow()` (fired from `init` before any
    /// session exists) can land its `recentSessions()` read after
    /// `createSession()` has already installed the session live but before
    /// that session's own `upsertSession` write is visible to a fresh read —
    /// overwriting `sessionRows` with a snapshot that omits the new session.
    /// Forcing an extra `refreshRecentNow()` here — without first flushing
    /// the just-created session's write — reproduces exactly that ordering.
    /// Whether or not `sessionRows` actually loses the row on a given run,
    /// the session is live either way, so the assertion must hold
    /// regardless — this is what distinguishes the fix (checking
    /// `liveSession` too) from the old `sessionRows`-only lookup.
    @Test func remoteFileContentsSucceedsWhenLiveSessionRacesAheadOfPersistedSessionRows() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "hello\n".write(to: repository.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "visible.txt"], cwd: repository)
        _ = try await Process.git(["commit", "-m", "add visible file"], cwd: repository)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)
        let manager = try #require(state.acpManager(forWorktreeId: worktreeId))

        await manager.refreshRecentNow()

        let contentsResult = await state.remoteFileContents(sessionId: tab.sessionId, path: "visible.txt")
        #expect(contentsResult == .success(text: "hello\n", truncated: false))
    }

    /// `AppState.readRemoteWorktreeFileRaw` must go over the (attempted) SSH
    /// transport for a worktree whose root is registered in
    /// `RemoteHostRegistry` — never silently fall back to reading local
    /// disk. There is no reachable SSH server in this environment, so this
    /// test can't drive a real end-to-end remote read; instead it proves the
    /// negative that matters: given a local directory that genuinely
    /// contains the requested file with known content, reading it through
    /// the "remote" branch does NOT return that local content. A regression
    /// that reintroduced a local-disk fallback would make this test fail by
    /// returning `.data(...)` with the real bytes.
    ///
    /// Uses `nonexistent-host.invalid` rather than `127.0.0.1`: `127.0.0.1`
    /// is a real, routable address that would silently exercise an actual
    /// local SSH server on any machine with Remote Login enabled, making
    /// this test pass for the wrong reason (or fail outright) instead of
    /// proving the no-fallback invariant it's named for. `.invalid` is an
    /// IANA-reserved TLD (RFC 2606) guaranteed never to resolve, and DNS
    /// resolution failure is fast — unlike a non-routable IP (e.g.
    /// TEST-NET-1), which would instead hang for the configured SSH
    /// `ConnectTimeout` (10-30s) waiting for packets nothing ever answers.
    @Test func readRemoteWorktreeFileRawDoesNotFallBackToLocalDiskWhenTheHostIsUnreachable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-raw-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "local content that a remote read must never return\n"
        try marker.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let state = AppState(store: MemoryStore())
        let outcome = await state.readRemoteWorktreeFileRaw(
            host: "nonexistent-host.invalid", worktreeRoot: root.path, relativePath: "a.txt")

        switch outcome {
        case .data(let data):
            Issue.record("remote read must not fall back to local disk, got local bytes: \(data)")
        case .notFound, .unreadable, .containmentRejected, .tooLarge:
            break // any failure kind is fine — the point is it did not read local disk
        }
    }

    /// Companion to the above: confirms the fixture actually would have
    /// produced a misleadingly "successful" local read had the code taken
    /// the local-disk branch instead — otherwise the test above would pass
    /// vacuously (any host, reachable or not, "not returning local content"
    /// is meaningless if there's no local content to begin with).
    @Test func readRemoteWorktreeFileRawFixtureWouldSucceedIfReadLocally() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-raw-read-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "local content that a remote read must never return\n"
        try marker.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let outcome = await RemoteWorktreeFileAccess.readFileContents(at: root.appendingPathComponent("a.txt"))
        #expect(outcome == .text(marker))
    }

    /// `AppState.remoteFileTree` must verify remote containment for a
    /// worktree registered in `RemoteHostRegistry` before listing a
    /// non-root directory — never trust `RemoteWorktreeFileAccess.resolve`
    /// alone, since that check only performs LOCAL symlink resolution and
    /// is a no-op when nothing exists locally at the worktree's path to
    /// escape from (the real vulnerability: a symlink inside the SSH
    /// worktree pointing outside it).
    ///
    /// As with `readRemoteWorktreeFileRawDoesNotFallBackToLocalDiskWhenTheHostIsUnreachable`,
    /// there is no reachable SSH server in this environment, so this can't
    /// drive a real end-to-end escape. Instead it proves the fix's
    /// fail-closed behavior directly: `repository` is a REAL local git repo
    /// with a real "alias" subdirectory tracked in git, so — absent the
    /// fix — `GitService.fileTreeChildren` would happily list its (real,
    /// local) contents once `resolve` vacuously passes. Registering
    /// `repository.path` with `RemoteHostRegistry` (as a real remote
    /// worktree root would be) makes `worktree.path.isRemoteAlasPath` true,
    /// so the new containment check runs and must fail closed against the
    /// unreachable host rather than falling through to the real local
    /// listing. `nonexistent-host.invalid` is used for the same reason as
    /// the sibling test: an IANA-reserved TLD guaranteed never to resolve.
    @Test func remoteFileTreeVerifiesRemoteContainmentBeforeListingANonRootDirectory() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer {
            RemoteHostRegistry.shared.unregister(root: repository.path)
            try? FileManager.default.removeItem(at: repository)
        }
        let aliasDir = repository.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        try "secret\n".write(to: aliasDir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "alias"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "-m", "add alias dir"], cwd: repository)

        RemoteHostRegistry.shared.register(root: repository.path, host: "nonexistent-host.invalid")

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)

        let result = await state.remoteFileTree(sessionId: tab.sessionId, path: "alias")

        guard case let .failure(reason, _) = result else {
            Issue.record("expected remote containment verification to fail closed, got \(result)")
            return
        }
        #expect(reason == .gitFailed)
    }

    /// LOCAL-worktree counterpart of the SSH-specific
    /// `shouldClassifyRemotelyDiscoveredEntry` fix: `GitService.fileTree`'s
    /// LOCAL root scan can mark a directory `.ignored` even though it holds
    /// a tracked, force-added descendant (gitignore rules don't un-track a
    /// path already in the index) — intentional, since the native desktop
    /// Files tab keeps such a directory visible via
    /// `FilesTabView.filteredNodes`'s recursive keep-if-has-visible-children
    /// check. `AppState.remoteFileNodes` used to do a flat, non-recursive
    /// `compactMap` that dropped the directory outright — since
    /// `RemoteFileNode` carries no `children`, once dropped from the ROOT
    /// listing the client could never issue the `listFiles` request that
    /// would reveal `generated/keep.txt`. This exercises the fix via the
    /// same seam other tests in this file use for the root-level remote file
    /// tree (`state.remoteFileTree(sessionId:path: nil)`), against a real
    /// LOCAL git repo (not registered with `RemoteHostRegistry`), so it
    /// actually drives `GitService.fileTree`'s local branch end-to-end.
    @Test func remoteFileTreeSurfacesAnIgnoredRootDirectoryWithATrackedDescendant() async throws {
        let repository = try await makeRemoteBranchesRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try "generated/\n".write(
            to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("generated"), withIntermediateDirectories: true)
        try "tracked\n".write(
            to: repository.appendingPathComponent("generated/keep.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", ".gitignore"], cwd: repository)
        _ = try await Process.git(["add", "-f", "generated/keep.txt"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "-m", "seed"], cwd: repository)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)

        let result = await state.remoteFileTree(sessionId: tab.sessionId, path: nil)

        guard case let .success(nodes) = result else {
            Issue.record("expected a successful root file tree listing, got \(result)")
            return
        }
        let generated = try #require(nodes.first { $0.path == "generated" })
        #expect(generated.kind == "dir")
    }

    /// End-to-end reproduction of the bug: a binary file that existed at the
    /// comparison ref but was deleted from the working tree since must still
    /// surface `.binary`, not an empty "successful" diff (the working-tree
    /// sniff alone can't tell — the file isn't there to sniff).
    @Test func remoteFileDiffReportsBinaryForABinaryFileDeletedSinceTheComparisonRef() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-binary-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repository)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: repository)
        _ = try await Process.git(["config", "user.name", "Test User"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: repository)

        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(
            to: repository.appendingPathComponent("image.bin"))
        _ = try await Process.git(["add", "image.bin"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "-m", "add binary"], cwd: repository)
        _ = try await Process.git(["branch", "start"], cwd: repository)

        _ = try await Process.git(["rm", "-q", "image.bin"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "-m", "remove binary"], cwd: repository)

        var cleanupWorktreeId: String?
        defer {
            if let cleanupWorktreeId {
                cleanupRemoteRenameFiles(worktreeId: cleanupWorktreeId)
            }
        }
        let state = makeRemoteGitBackedState(repositoryPath: repository)
        state.config.worktrees.baseBranch = "start"
        let worktreeId = try #require(state.selectedWorktreeId)
        cleanupWorktreeId = worktreeId
        state.openNewACPSession(agentID: "test-agent")
        let tab = try #require(acpTabs(in: state).first)

        let diffResult = await state.remoteFileDiff(sessionId: tab.sessionId, path: "image.bin")
        #expect(diffResult == .failure(reason: .binary, message: nil))
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
            name: "test",
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

    /// Like `makeRemoteRenameState()` but points the worktree at a real git
    /// repository (rather than a bare `/tmp` directory) so `remoteFileDiff`
    /// / `remoteFileContents`' git-backed checks (ignore status, diffing)
    /// have a real repo to work against.
    private func makeRemoteGitBackedState(repositoryPath: URL) -> AppState {
        let project = ProjectConfig(
            id: UUID().uuidString,
            name: "test",
            path: repositoryPath.path,
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [project])))
        let worktree = Worktree(
            id: UUID().uuidString,
            projectId: project.id,
            name: "main",
            branch: "main",
            path: repositoryPath,
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

    private func makeRemoteBranchesRepository() async throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-branches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repository)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: repository)
        _ = try await Process.git(["config", "user.name", "Test User"], cwd: repository)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: repository)
        _ = try await Process.git(["branch", "feature/remote"], cwd: repository)
        return repository
    }

    private func enabledClaudeRegistry() -> AgentRegistry {
        AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil),
            ],
            customs: [],
            installedIds: ["claude"]
        )
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

    private func firstACPTab(in state: AppState, worktreeId: String) -> ACPSessionTabState? {
        state.tabs.tabs(forWorktree: worktreeId).compactMap { tab in
            if case .acpSession(let session) = tab { return session }
            return nil
        }.first
    }

    private func remoteWorktreeCopy(_ source: Worktree, id: String, name: String) -> Worktree {
        Worktree(
            id: id,
            projectId: source.projectId,
            name: name,
            branch: name,
            path: source.path.appendingPathComponent(name),
            status: source.status,
            lastActivity: source.lastActivity
        )
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
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        try await manager.persistence.upsertSession(ACPSessionRow(
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
        await manager.refreshRecentNow()
    }

    private func cleanupRemoteRenameFiles(worktreeId: String) {
        try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId))
        let db = Paths.acpSessionsDB(forWorktreeId: worktreeId)
        try? FileManager.default.removeItem(at: db)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: db.path + "-shm"))
    }
}
