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
