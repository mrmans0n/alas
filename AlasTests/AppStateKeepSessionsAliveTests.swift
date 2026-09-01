import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateKeepSessionsAliveTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-keepalive-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    /// On relaunch with `keepSessionsAlive = false`, a persisted terminal
    /// tab whose leaves have no live session must be pruned instead of
    /// resurrected with a fresh plain shell. Otherwise the toggle only
    /// strips the `zmx attach` wrapper while still reopening shells in the
    /// same tab slot on every relaunch.
    @Test func restoreDropsPersistedTerminalTabWhenKeepAliveFalse() async throws {
        let repo = try await makeRepo(name: "drop")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id
        state.config.terminal.keepSessionsAlive = false

        // Simulate a persisted terminal tab whose underlying session is
        // gone (post-relaunch — registry is empty for this leaf id).
        let tab = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "main", sessionId: "leaf-orphan"
        )

        let restored = try state.restoreTerminalTabIfNeeded(
            worktreeId: trees[0].id, tabId: tab.id
        )

        #expect(restored == nil)
        #expect(state.tabs.tabs(forWorktree: trees[0].id).isEmpty)
    }

    /// Same scenario but with the setting on: the persisted tab must be
    /// kept and the standard restore path must run (the open-session call
    /// itself may fail in this test environment without Ghostty.App, but
    /// the tab must NOT be pruned).
    @Test func restoreKeepsPersistedTerminalTabWhenKeepAliveTrue() async throws {
        let repo = try await makeRepo(name: "keep")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id
        state.config.terminal.keepSessionsAlive = true

        let tab = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "main", sessionId: "leaf-keep"
        )

        // openSession can throw in this test env (no bundled Ghostty.App).
        // The contract under test is "tab is not pruned", which happens
        // before any openSession call — assert that regardless of throw.
        _ = try? state.restoreTerminalTabIfNeeded(
            worktreeId: trees[0].id, tabId: tab.id
        )

        #expect(state.tabs.tabs(forWorktree: trees[0].id).map(\.id) == [tab.id])
    }

    /// `reloadTabs` runs once on launch and is the only path that touches
    /// every persisted terminal tab across every worktree. When
    /// `keepSessionsAlive` is off, it must prune them all — including
    /// inactive tabs and tabs in worktrees the user isn't viewing — so
    /// orphan daemon sessions get killed and stale tabs don't linger.
    @Test func reloadTabsPrunesAllTerminalTabsWhenKeepAliveFalse() async throws {
        let repo = try await makeRepo(name: "reload-prune")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id

        // Persist two terminal tabs and one non-terminal tab. The
        // non-terminal one must survive the prune.
        _ = state.tabs.appendTerminal(worktreeId: trees[0].id, title: "a", sessionId: "leaf-a")
        _ = state.tabs.appendTerminal(worktreeId: trees[0].id, title: "b", sessionId: "leaf-b")
        let editor = state.tabs.appendEditor(
            worktreeId: trees[0].id, title: "c.txt", relativePath: "c.txt"
        )

        state.config.terminal.keepSessionsAlive = false
        state.reloadTabs()

        let remaining = state.tabs.tabs(forWorktree: trees[0].id)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == editor.id)
    }

    /// Counter-test: with the setting on, `reloadTabs` must not prune
    /// terminal tabs.
    @Test func reloadTabsKeepsTerminalTabsWhenKeepAliveTrue() async throws {
        let repo = try await makeRepo(name: "reload-keep")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id

        let term = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "a", sessionId: "leaf-a"
        )

        state.config.terminal.keepSessionsAlive = true
        state.reloadTabs()

        #expect(state.tabs.tabs(forWorktree: trees[0].id).map(\.id) == [term.id])
    }

    @Test func topologyRefreshDoesNotPruneUnrelatedTerminalTabsWhenKeepAliveFalse() async throws {
        let repo = try await makeRepo(name: "topology-keep")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id
        state.config.terminal.keepSessionsAlive = false

        let term = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "a", sessionId: "leaf-a"
        )

        await state.refreshProjectTopology(projectId: project.id)

        #expect(state.tabs.tabs(forWorktree: trees[0].id).map(\.id) == [term.id])
    }

    @Test func terminateAllTerminalSessionsClosesCheckoutOwnedTerminalTabs() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-terminate-checkout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: "/checkouts/release",
            members: []
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let bridge = WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore)
        let workspaces = WorkspacesManager(bridge: bridge)
        _ = await workspaces.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tabs = TabsManager(store: MemoryStore())
        _ = tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-leaf")
        let state = AppState(
            store: MemoryStore(),
            tabsManager: tabs,
            workspacesManager: workspaces,
            workspaceStore: workspaceStore
        )

        state.terminateAllTerminalSessionsAfterConfirmationForTesting()

        #expect(tabs.tabs(for: owner).isEmpty)
    }

    @Test func workspaceCheckoutSearchActivationPreservesCheckoutFocus() async throws {
        let repo = try await makeRepo(name: "checkout-search")
        let root = repo.deletingLastPathComponent()
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-search-checkout-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        let projectID = "project"
        let worktree = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: projectID,
            name: "main",
            branch: "main",
            path: repo,
            isMainWorktree: true,
            status: .clean,
            lastActivity: .distantPast
        )
        let project = ProjectConfig(
            id: projectID,
            name: "Project",
            path: repo.path,
            color: "#000000",
            addedAt: .distantPast,
            cachedWorktrees: [worktree]
        )
        let memberID = UUID()
        let checkoutMemberID = UUID()
        let lineage = try #require(WorktreeService.localLineageID(forWorktreeAt: repo, candidateID: "lineage"))
        let member = WorkspaceCheckoutMember(
            id: checkoutMemberID,
            workspaceMemberID: memberID,
            projectID: projectID,
            fallbackProjectName: "Project",
            fallbackRepositoryRoot: repo.path,
            worktreePath: repo.path,
            gitLineageID: lineage,
            availability: .available,
            checkpoint: .setupComplete,
            cleanupOwnership: .init(worktreeCreated: true, branchOwnership: .reused),
            plan: .init(
                checkoutMemberID: checkoutMemberID,
                projectID: projectID,
                sourceRepositoryPath: repo.path,
                destinationPath: repo.path,
                baseReference: "main",
                baseCommit: "base",
                branchIntent: .reuse
            )
        )
        let checkout = WorkspaceCheckout(
            workspaceID: nil,
            fallbackWorkspaceName: "Release",
            executionLocation: .local,
            branch: "release/1091",
            rootPath: root.path,
            members: [member]
        )
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        let workspaces = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await workspaces.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: MemoryStore(projectsFile: .init(projects: [project])),
            tabsManager: TabsManager(store: MemoryStore()),
            workspacesManager: workspaces,
            workspaceStore: workspaceStore
        )
        state.config.workspacesEnabled = true
        try await state.projectsManager.refreshWorktrees(projectId: projectID)
        state.selectWorkspaceCheckout(id: checkout.id)

        state.openWorkspaceCheckoutSearchResult(
            relativePath: "README.md",
            worktreeId: worktree.id,
            memberID: checkoutMemberID
        )

        #expect(state.workspaceNavigationState.selectedCheckoutID == checkout.id)
        #expect(state.workspaceNavigationState.focusedCheckoutMemberID == checkoutMemberID)
        #expect(state.selectedWorktreeId == worktree.id)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile = .init(projects: [])

        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            return nil
        }
    }
}
