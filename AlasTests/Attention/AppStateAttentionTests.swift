import Foundation
import Testing
@testable import Alas

@Suite("AppState attention", .serialized)
@MainActor
struct AppStateAttentionTests {
    @Test func recoveredHistorySuppressesOnlyInitialRightPaneSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        let conflicts = RightPaneAttentionSnapshot(mergeOperation: nil, conflictedPaths: ["file.swift"], review: nil)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.isEmpty)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: .init(mergeOperation: nil, conflictedPaths: [], review: nil))
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.count == 1)
        state.observeRightPaneAttention(worktreeID: "worktree", snapshot: conflicts)
        #expect(state.attentionStore.events.count == 1)
    }

    @Test func acpCompletionRecordsFinishedHistoryButRemovalDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        let bridge = ACPHarnessBridge(harness: state.harness)
        let session = ACPSession(id: "acp", agentId: "claude", worktreeId: "worktree", title: "Agent")
        session.agentState = .ready
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: session.id, title: "Agent")
        bridge.observe(session: session)
        #expect(state.attentionStore.events.isEmpty)

        session.transcript.streamingState = .streaming
        session.transcript.streamingState = .idle
        session.transcript.streamingState = .idle
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])
        #expect(state.harness.activityBySession[session.id] == nil)

        session.transcript.streamingState = .streaming
        session.agentState = .idle
        session.transcript.streamingState = .idle
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])

        session.agentState = .ready
        session.transcript.streamingState = .streaming
        bridge.forget(sessionId: session.id)
        #expect(state.attentionStore.events.map(\.kind) == [.agentFinished])
        #expect(state.harness.activityBySession[session.id] == nil)
    }

    @Test func corruptHistoryDoesNotSuppressFirstAttentionFromNewSessionAfterStartup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeStateWithWorktree()
        state.reconcileAttention(liveSignals: [])
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "New agent", sessionId: "new-session")
        state.harness.handleSocketEvent(
            AgentHookEvent(version: 1, event: .awaitingInput, agent: .claude,
                           sessionId: "new-session", pid: nil, timestamp: nil, body: "New question"),
            stateLookup: { _ in nil }, shouldNotifyOnAwaiting: { false }
        )

        #expect(state.attentionStore.loadError != nil)
        #expect(state.attentionAggregation.unresolvedCount == 1)
        #expect(state.attentionStore.events.first?.jumpTarget == .session(sessionID: "new-session"))
    }

    @Test func harnessChangesRecordHistoryAndUseLiveStateForPresentation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        _ = state.tabs.appendTerminal(worktreeId: worktree.id, title: "Agent", sessionId: "session")

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "First question")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput, body: "Second question")
        #expect(state.attentionStore.events.count == 2)
        #expect(state.attentionStore.events.last?.body == "Second question")
        #expect(state.attentionAggregation.items.first?.presentation == .live)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .permissionRequest)
        #expect(state.attentionAggregation.unresolvedCount == 2)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .idle)

        #expect(state.attentionStore.events.map(\.kind) == [.agentAwaiting, .agentAwaiting, .agentPermission, .agentFinished])
        #expect(state.attentionAggregation.items.allSatisfy { $0.presentation == .historical })
        #expect(state.attentionAggregation.items.contains { $0.title == "Claude Code waited for input" })
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == false)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:permission")]?.isActive == false)
    }

    @Test func acknowledgedActiveOccurrenceDoesNotReturnAfterAppStateRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.store.observe(.active(fixture.signal), at: fixture.now)
        let event = try #require(fixture.store.events.first)
        fixture.store.acknowledge(eventID: event.id, at: fixture.now)

        let state = fixture.makeState()
        state.reconcileAttention(liveSignals: [fixture.signal])

        #expect(state.attentionStore.events.count == 1)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        #expect(state.attentionAggregation.history.first?.eventID == event.id)
    }

    @Test func unreadableHistorySuppressesStartupUntilSourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        state.reconcileAttention(liveSignals: [fixture.signal])
        state.observeAttention(.active(fixture.signal))

        #expect(state.attentionStore.loadError != nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)

        state.observeAttention(.inactive(sourceKey: fixture.signal.sourceKey))
        state.observeAttention(.active(fixture.signal))
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func corruptHistorySuppressesFirstRestoredHarnessStateButAcceptsLaterTransition() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("broken history".utf8).write(to: fixture.url)
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let session = ACPSession(id: "session", agentId: "claude", worktreeId: worktree.id, title: "Agent")
        _ = state.tabs.appendACP(owner: .worktree(worktree.id), sessionId: session.id, title: "Agent")
        session.transcript.streamingState = .awaitingInput
        let bridge = ACPHarnessBridge(harness: state.harness)
        bridge.observe(session: session)
        #expect(state.attentionAggregation.unresolvedCount == 0)
        session.transcript.streamingState = .streaming
        session.transcript.streamingState = .awaitingInput
        #expect(state.attentionAggregation.unresolvedCount == 1)
    }

    @Test func restoredHarnessSnapshotAppliesInactiveObservations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeStateWithWorktree()
        _ = state.tabs.appendACP(owner: .worktree("worktree"), sessionId: "session", title: "Agent")
        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .awaitingInput)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == true)

        state.harness.setExternalActivity(sessionId: "session", agent: .claude, state: .busy, isSnapshot: true)

        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:awaiting")]?.isActive == false)
        #expect(state.attentionStore.document.observations[.init(rawValue: "session:session:permission")] == nil)
    }

    @Test func inboxRestoresOriginalTabAfterRepeatedOpen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let first = state.tabs.appendTerminal(worktreeId: "worktree", title: "First", sessionId: "first")
        state.selectedWorktreeId = "worktree"
        state.openAttentionInbox()
        _ = state.tabs.appendTerminal(worktreeId: "worktree", title: "Second", sessionId: "second")
        state.openAttentionInbox()
        state.closeAttentionInbox()

        #expect(!state.isAttentionInboxOpen)
        #expect(state.selectedWorktreeId == "worktree")
        #expect(state.tabs.activeTabId(forWorktree: "worktree") == first.id)
    }

    @Test func stoppedRightPaneStatesDoNotContributeLiveAttentionSignals() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let first = Worktree(id: "first", projectId: project.id, name: "first", branch: "main",
                             path: URL(fileURLWithPath: "/repo/first"), status: .clean, lastActivity: fixture.now)
        let second = Worktree(id: "second", projectId: project.id, name: "second", branch: "main",
                              path: URL(fileURLWithPath: "/repo/second"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)

        _ = state.rightPaneStore.state(for: first, baseBranch: "", comparisonMode: state.config.changes.comparisonMode)
        #expect(state.rightPaneStore.isActiveState(worktreeId: first.id))
        _ = state.rightPaneStore.state(for: second, baseBranch: "", comparisonMode: state.config.changes.comparisonMode)

        #expect(!state.rightPaneStore.isActiveState(worktreeId: first.id))
        #expect(state.rightPaneStore.isActiveState(worktreeId: second.id))
        state.rightPaneStore.deactivate()
        #expect(!state.rightPaneStore.isActiveState(worktreeId: second.id))
    }

    @Test func checkoutOwnedACPAttentionOpensSharedTabAndClears() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let workspacesManager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: fixture.now)
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "topic",
            rootPath: "/repo",
            members: [
                WorkspaceCheckoutMember(
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: project.name,
                    fallbackRepositoryRoot: project.path,
                    worktreePath: worktree.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(WorkspaceStateFile(checkouts: [checkout]))
        _ = await workspacesManager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: MemoryStore(),
            attentionStore: AttentionStore(url: fixture.url),
            workspacesManager: workspacesManager,
            workspaceStore: workspaceStore
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktree.id
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tab = state.tabs.appendACP(owner: owner, sessionId: "shared-acp", title: "Shared agent")

        state.harness.setExternalActivity(sessionId: "shared-acp", owner: owner, agent: .claude, state: .awaitingInput)
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.tabs.activeTabId(for: owner) == tab.id)
        #expect(state.tabs.activeTabId(forWorktree: worktree.id) == nil)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    @Test func recoveredHostEventOpensWorktreeAndClearsAfterHostRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let state = fixture.makeState()
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue",
                                    addedAt: fixture.now, host: "buildbox")
        let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: fixture.now)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let owner = AttentionWorktreeIdentity.make(worktree: worktree, project: project)
        let signal = try #require(AttentionProducer.host(
            host: "buildbox",
            isDisconnected: true,
            owner: owner,
            display: AttentionWorktree(worktree: worktree, project: project).resolved.display
        ).compactMap(\.activeSignal).first)
        state.attentionStore.observe(.active(signal), at: fixture.now)
        let item = try #require(state.attentionAggregation.items.first)

        let result = await state.openAttentionItem(item)

        #expect(result == .opened)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.attentionAggregation.unresolvedCount == 0)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @MainActor
    private struct Fixture {
        let now = Date()
        let url: URL
        let store: AttentionStore
        let signal = AttentionSignal(
            sourceKey: .init(rawValue: "session:session:awaiting"), fingerprint: "awaitingInput",
            owner: .init(projectID: "project", location: .local, lineageID: nil, legacyPath: "/repo"),
            kind: .agentAwaiting, title: "Claude Code is waiting for input", body: nil,
            jumpTarget: .session(sessionID: "session"),
            display: .init(projectName: "Project", branch: "main", path: "/repo", host: nil)
        )

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("attention-events.json")
            store = AttentionStore(url: url)
        }

        func makeState() -> AppState {
            AppState(store: MemoryStore(), attentionStore: AttentionStore(url: url))
        }

        func makeStateWithWorktree() -> AppState {
            let state = makeState()
            let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: now)
            let worktree = Worktree(id: "worktree", projectId: project.id, name: "main", branch: "main",
                                    path: URL(fileURLWithPath: "/repo"), status: .clean, lastActivity: now)
            state.projectsManager = ProjectsManager(persistedProjects: [project])
            state.projectsManager.insertOptimisticWorktree(worktree)
            return state
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
