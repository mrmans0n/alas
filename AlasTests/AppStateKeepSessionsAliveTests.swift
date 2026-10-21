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

        let restored = try await state.restoreTerminalTabIfNeededAsync(
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
        _ = try? await state.restoreTerminalTabIfNeededAsync(
            worktreeId: trees[0].id, tabId: tab.id
        )

        #expect(state.tabs.tabs(forWorktree: trees[0].id).map(\.id) == [tab.id])
    }

    @Test func restoreWaitsForRepoHookApprovalBeforeOpeningSessions() async throws {
        let repo = try await makeRepo(name: "hook-restore")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id
        state.config.terminal.keepSessionsAlive = true
        state.repoHookLoader = RepoHookLoader { _, _, _ in
            .data(Data("echo repo hook".utf8))
        }
        let tab = state.tabs.appendTerminal(
            worktreeId: worktree.id, title: "main", sessionId: "leaf-hook"
        )

        let restoreTask = Task {
            try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
        }
        let deadline = Date().addingTimeInterval(10)
        while state.repoHookApprovalQueue.activeRequest == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let approvalRequest = state.repoHookApprovalQueue.activeRequest
        #expect(approvalRequest?.hook?.event == .sessionOpen)
        #expect(state.terminal.registry.session(for: "leaf-hook") == nil)
        if approvalRequest != nil {
            state.repoHookApprovalQueue.decide(.cancel)
        } else {
            restoreTask.cancel()
        }
        var wasCancelled = false
        do {
            _ = try await restoreTask.value
        } catch RepoHookPreflightError.cancelled {
            wasCancelled = true
        }
        #expect(wasCancelled)
        #expect(state.terminal.registry.session(for: "leaf-hook") == nil)
    }

    /// A persisted session must not be attached, or killed, while pre-freeze
    /// daemons are still being stopped: attaching one shows a stuck terminal.
    /// With keep-alive off the restore closes the tab, so the tab surviving
    /// while the migration runs shows the restore is waiting on it. While the
    /// bundled zmx is itself pre-freeze there is nothing to migrate: the
    /// runner never runs and the restore goes ahead at once.
    @Test(.timeLimit(.minutes(1)), arguments: [ZmxIPC.Wire.v1, .preFreeze])
    func terminalRestoreWaitsForTheZmxMigration(bundledWire: ZmxIPC.Wire) async throws {
        let repo = try await makeRepo(name: "zmx-migration")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id
        state.config.terminal.keepSessionsAlive = false
        let migration = ZmxMigrationGate(blocked: true)
        defer { migration.release() }
        state.zmxMigrationRunner = migration.runner
        state.bundledZmxWire = bundledWire
        let tab = state.tabs.appendTerminal(
            worktreeId: worktree.id, title: "main", sessionId: "leaf-migration"
        )

        guard bundledWire == .v1 else {
            _ = try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
            #expect(migration.runCount == 0)
            #expect(state.tabs.tabs(forWorktree: worktree.id).isEmpty)
            return
        }
        let restoreTask = Task {
            try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
        }
        await migration.untilARunStarts()
        #expect(migration.runCount == 1)
        #expect(state.tabs.tabs(forWorktree: worktree.id).map(\.id) == [tab.id])

        migration.release()
        _ = try await restoreTask.value
        #expect(state.tabs.tabs(forWorktree: worktree.id).isEmpty)
    }

    @Test func zmxMigrationRunsOncePerAppState() async {
        let state = AppState()
        let migration = ZmxMigrationGate(blocked: false)
        state.zmxMigrationRunner = migration.runner
        state.bundledZmxWire = .v1

        state.reloadTabs()
        state.reloadTabs()
        await state.awaitZmxMigration()

        #expect(migration.runCount == 1)
    }

    /// A daemon another (pre-freeze) Alas is still attached to stays
    /// pre-freeze, and the bundled zmx would attach it as a stuck terminal:
    /// the restore leaves that pane without a session. Asking for it again
    /// re-runs the migration for that session alone and, once it restarted,
    /// restores the pane. A daemon that did not answer at launch but answers
    /// v1 on the re-run is current, and its pane restores too.
    @Test(arguments: ZmxRetryRecovery.allCases)
    func restoreSkipsAPaneLeftPreFreezeUntilAReRunClearsIt(recovery: ZmxRetryRecovery) async throws {
        let repo = try await makeRepo(name: "zmx-in-use")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id
        state.config.terminal.keepSessionsAlive = true
        let leafId = "leaf-in-use"
        let name = ZmxSessionName.derive(worktreeId: worktree.id, leafId: leafId)
        let migration = ZmxMigrationGate(blocked: false, results: recovery.results(name))
        state.zmxMigrationRunner = migration.runner
        let vanishes = recovery.socketVanishesOnRetry
        state.zmxSocketExists = { _ in !(vanishes && migration.runNames.count > 1) }
        state.bundledZmxWire = .v1
        let tab = state.tabs.appendTerminal(worktreeId: worktree.id, title: "main", sessionId: leafId)

        _ = try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
        #expect(migration.runNames == [nil])
        #expect(state.terminal.registry.session(for: leafId) == nil)
        #expect(state.tabs.tabs(forWorktree: worktree.id).map(\.id) == [tab.id])

        // The recover path. `openSession` itself can throw in this host (no
        // bundled Ghostty.App); reaching it is what shows the pane restores.
        var reachedOpenSession = false
        do {
            _ = try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
            reachedOpenSession = state.terminal.registry.session(for: leafId) != nil
        } catch {
            reachedOpenSession = true
        }
        #expect(migration.runNames == [nil, [name]])
        #expect(reachedOpenSession)
        if state.terminal.registry.session(for: leafId) != nil {
            state.terminal.closeSession(id: leafId, worktreeId: worktree.id)
            state.terminal.waitForPendingKills(timeout: 20)
        }
    }

    /// A daemon that accepted the probe but never answered may be
    /// pre-freeze: the restore leaves its pane without a session. A re-run
    /// that can neither restart the daemon nor find its socket gone, such as
    /// one whose probe timed out again, has not shown the session is safe:
    /// the pane stays without a session.
    @Test func restoreKeepsAPaneBlockedWhenAReRunCannotClassifyIt() async throws {
        let repo = try await makeRepo(name: "zmx-unclassified")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id
        state.config.terminal.keepSessionsAlive = true
        let leafId = "leaf-unclassified"
        let name = ZmxSessionName.derive(worktreeId: worktree.id, leafId: leafId)
        let migration = ZmxMigrationGate(blocked: false, results: [
            ZmxPreFreezeMigration.Result(unresponsive: [name]),
            ZmxPreFreezeMigration.Result(),
        ])
        state.zmxMigrationRunner = migration.runner
        state.zmxSocketExists = { _ in true }
        state.bundledZmxWire = .v1
        let tab = state.tabs.appendTerminal(worktreeId: worktree.id, title: "main", sessionId: leafId)

        _ = try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)
        _ = try await state.restoreTerminalTabIfNeededAsync(worktreeId: worktree.id, tabId: tab.id)

        #expect(migration.runNames == [nil, [name]])
        #expect(state.terminal.registry.session(for: leafId) == nil)
        #expect(state.tabs.tabs(forWorktree: worktree.id).map(\.id) == [tab.id])
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
        _ = await workspaces.load(spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let tabs = TabsManager(store: TestPersistenceStore(ProjectsFile(projects: [])))
        _ = tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-leaf")
        let state = AppState(
            store: TestPersistenceStore(ProjectsFile(projects: [])),
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
        _ = await workspaces.load(spacesFile: SpacesFile(activeSpaceId: "main", spaces: []))
        let state = AppState(
            store: TestPersistenceStore(ProjectsFile(projects: [project])),
            tabsManager: TabsManager(store: TestPersistenceStore(ProjectsFile(projects: []))),
            workspacesManager: workspaces,
            workspaceStore: workspaceStore
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectID)
        state.selectWorkspaceCheckout(id: checkout.id)
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let shared = state.tabs.appendTerminal(owner: owner, title: "Shared", sessionId: "checkout-shared")
        #expect(state.tabs.activeTabId(for: owner) == shared.id)

        let opened = state.openWorkspaceCheckoutSearchResult(
            relativePath: "README.md",
            worktreeId: worktree.id,
            checkoutID: checkout.id,
            memberID: checkoutMemberID
        )

        #expect(opened)
        #expect(state.workspaceNavigationState.selectedCheckoutID == checkout.id)
        #expect(state.workspaceNavigationState.focusedCheckoutMemberID == checkoutMemberID)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.tabs.activeTabId(for: owner) == shared.id)
        #expect(state.tabs.activeTabId(forWorktree: worktree.id) != nil)
    }
}

/// A zmx migration runner that records the socket names of each run and
/// returns the scripted results in order (then empty ones). When blocked it
/// parks runs until `release()`; `untilARunStarts()` awaits a run's entry.
/// Declared outside the main-actor suite so the runner is not main-actor
/// isolated when it runs on its own thread.
private final class ZmxMigrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: DispatchSemaphore
    private var runs: [Set<String>?] = []
    private var results: [ZmxPreFreezeMigration.Result]
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(blocked: Bool, results: [ZmxPreFreezeMigration.Result] = []) {
        gate = DispatchSemaphore(value: blocked ? 0 : 1)
        self.results = results
    }

    var runCount: Int { lock.withLock { runs.count } }
    /// The `names` filter of every run so far; nil for a run over every socket.
    var runNames: [Set<String>?] { lock.withLock { runs } }

    func release() { gate.signal() }

    /// Returns once a run has started, even while the gate parks it.
    func untilARunStarts() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let started = lock.withLock { () -> Bool in
                if !runs.isEmpty { return true }
                startWaiters.append(continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }

    var runner: AppState.ZmxMigrationRunner {
        { _, names in
            let (result, waiters) = self.lock.withLock {
                () -> (ZmxPreFreezeMigration.Result, [CheckedContinuation<Void, Never>]) in
                self.runs.append(names)
                let waiters = self.startWaiters
                self.startWaiters = []
                return (self.results.isEmpty ? ZmxPreFreezeMigration.Result() : self.results.removeFirst(), waiters)
            }
            for waiter in waiters { waiter.resume() }
            self.gate.wait()
            self.gate.signal()
            return result
        }
    }
}

/// How a session left blocked by the launch migration is cleared by a
/// re-run: the first result blocks it, the second unblocks it.
enum ZmxRetryRecovery: CaseIterable, Sendable {
    case inUseThenRestarted
    case unresponsiveThenCurrent
    /// The re-run still gets no answer, but the socket is gone by the time
    /// it is checked: `zmx attach` is safe, so that wins.
    case unresponsiveThenVanished

    func results(_ name: String) -> [ZmxPreFreezeMigration.Result] {
        switch self {
        case .inUseThenRestarted:
            [ZmxPreFreezeMigration.Result(inUse: [name]), ZmxPreFreezeMigration.Result(restarted: [name])]
        case .unresponsiveThenCurrent:
            [ZmxPreFreezeMigration.Result(unresponsive: [name]), ZmxPreFreezeMigration.Result(current: [name])]
        case .unresponsiveThenVanished:
            [ZmxPreFreezeMigration.Result(unresponsive: [name]), ZmxPreFreezeMigration.Result(unresponsive: [name])]
        }
    }

    var socketVanishesOnRetry: Bool { self == .unresponsiveThenVanished }
}
