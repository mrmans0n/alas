import Testing
import Foundation
@testable import Alas

// Serialize: each test creates an ephemeral repo and shells out to git.
// Concurrent git invocations on macos-26 CI have produced flaky hangs.
@Suite(.serialized)
@MainActor
struct ProjectsManagerTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func addProjectAppendsToList() async throws {
        let repo = try await makeRepo(name: "alpha")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "alpha", color: "#5fb7c4")
        #expect(mgr.projects.count == 1)
        #expect(project.name == "alpha")
    }

    @Test func addProjectUsesProvidedIconAndMirrorsColor() async throws {
        let repo = try await makeRepo(name: "lambda")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let icon = ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀")

        let project = try await mgr.addProject(path: repo, displayName: "lambda", icon: icon)

        #expect(project.icon == icon)
        #expect(project.color == "#112233")
    }

    @Test func addProjectUsesProvidedIdForPreStagedIconStorage() async throws {
        let repo = try await makeRepo(name: "staged-icon")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let icon = ProjectIcon(mode: .image, color: "#112233", imagePath: "project-1/icon.png")

        let project = try await mgr.addProject(
            path: repo,
            displayName: "staged-icon",
            icon: icon,
            id: "project-1"
        )

        #expect(project.id == "project-1")
        #expect(project.icon.imagePath == "project-1/icon.png")
    }

    @Test func refreshWorktreesPopulatesIt() async throws {
        let repo = try await makeRepo(name: "beta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "beta", color: "#c89d6f")
        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        #expect(trees.first?.branch == "main")
    }

    @Test func refreshWorktreesFallsBackWhenConfiguredLinkedWorktreeDisappears() async throws {
        let repo = try await makeRepo(name: "linked-anchor")
        defer { try? FileManager.default.removeItem(at: repo) }
        let service = WorktreeService()
        let linkedPath = repo.appendingPathComponent("linked-anchor")
        let projectId = "linked-anchor-project"
        let linkedWorktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "linked-anchor-branch",
            destination: linkedPath,
            projectId: projectId
        )
        let project = ProjectConfig(
            id: projectId,
            name: "linked-anchor",
            path: linkedPath.path,
            color: "#5fb7c4",
            addedAt: Date()
        )
        let manager = ProjectsManager(persistedProjects: [project])
        try await manager.refreshWorktrees(projectId: projectId)
        #expect(manager.worktrees(projectId: projectId).count == 2)

        try await service.remove(
            repoPath: repo,
            worktree: linkedWorktree,
            deleteBranchIfMerged: false,
            force: false
        )
        let projectChanged = try await manager.refreshWorktrees(projectId: projectId)

        let remaining = manager.worktrees(projectId: projectId)
        #expect(projectChanged)
        #expect(remaining.count == 1)
        #expect(remaining.first?.path.standardizedFileURL == repo.standardizedFileURL)
        let persistedPath = manager.projects.first.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        #expect(persistedPath == repo.standardizedFileURL)

        let restartedManager = ProjectsManager(persistedProjects: manager.projects)
        try await restartedManager.refreshWorktrees(projectId: projectId)
        let restartedWorktrees = restartedManager.worktrees(projectId: projectId)
        #expect(restartedWorktrees.count == 1)
        #expect(restartedWorktrees.first?.path.standardizedFileURL == repo.standardizedFileURL)
    }

    @Test func linkedWorktreeRegistrationPreservesGitsMainWorktreeIdentity() async throws {
        let repo = try await makeRepo(name: "linked-registration")
        defer { try? FileManager.default.removeItem(at: repo) }
        let service = WorktreeService()
        let linkedPath = repo.appendingPathComponent("linked-registration")
        let projectId = "linked-registration-project"
        _ = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "linked-registration-branch",
            destination: linkedPath,
            projectId: projectId
        )
        let project = ProjectConfig(
            id: projectId,
            name: "linked-registration",
            path: linkedPath.path,
            color: "#5fb7c4",
            addedAt: Date()
        )
        let manager = ProjectsManager(persistedProjects: [project])

        try await manager.refreshWorktrees(projectId: projectId)

        let worktrees = manager.worktrees(projectId: projectId)
        let main = try #require(worktrees.first { $0.path.standardizedFileURL == repo.standardizedFileURL })
        let linked = try #require(worktrees.first { $0.path.standardizedFileURL == linkedPath.standardizedFileURL })
        #expect(manager.isMain(main, in: project))
        #expect(!manager.isMain(linked, in: project))
        #expect(worktrees.first?.id == main.id)
    }

    @Test func remoteRegistrationReconcileUnregistersRemovedWorktreeRoots() {
        let project = ProjectConfig(
            id: "remote-project",
            name: "remote",
            path: "/srv/remote",
            color: "#5fb7c4",
            addedAt: Date(),
            host: "devbox"
        )
        let removed = Worktree(
            id: "removed",
            projectId: project.id,
            name: "removed",
            branch: "main",
            path: URL(fileURLWithPath: "/srv/remote-removed"),
            status: .clean,
            lastActivity: Date()
        )
        let live = Worktree(
            id: "live",
            projectId: project.id,
            name: "live",
            branch: "main",
            path: URL(fileURLWithPath: "/srv/remote-live"),
            status: .clean,
            lastActivity: Date()
        )
        defer {
            RemoteHostRegistry.shared.unregister(root: project.path)
            RemoteHostRegistry.shared.unregister(root: removed.path.path)
            RemoteHostRegistry.shared.unregister(root: live.path.path)
        }
        let mgr = ProjectsManager(persistedProjects: [project])
        RemoteHostRegistry.shared.register(root: removed.path.path, host: "devbox")

        mgr.reconcileRemoteHostRegistrations(project: project, previous: [removed], reconciled: [live])

        #expect(RemoteHostRegistry.shared.host(forPath: removed.path.path) == nil)
        #expect(RemoteHostRegistry.shared.host(forPath: live.path.path) == "devbox")
    }

    @Test func removeProjectStripsItAndItsWorktrees() async throws {
        let repo = try await makeRepo(name: "gamma")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "gamma", color: "#9789c7")
        try await mgr.refreshWorktrees(projectId: project.id)
        mgr.removeProject(id: project.id)
        #expect(mgr.projects.isEmpty)
        #expect(mgr.worktrees(projectId: project.id).isEmpty)
    }

    @Test func updateProjectUpdatesNameIconAndStartupScriptsWhilePreservingMCPServers() {
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = ProjectConfig(
            id: "project-1",
            name: "Before",
            path: "/tmp/before",
            color: "#5fb7c4",
            addedAt: addedAt,
            hiddenWorktreePaths: ["/tmp/before/.worktree"],
            mcpServers: [.stdio(name: "filesystem", command: "npx")]
        )
        let other = ProjectConfig(
            id: "project-2",
            name: "Other",
            path: "/tmp/other",
            color: "#9789c7",
            addedAt: addedAt.addingTimeInterval(1),
            hiddenWorktreePaths: []
        )
        let mgr = ProjectsManager(persistedProjects: [project, other])
        let icon = ProjectIcon(mode: .symbol, color: "#d77b88", symbolName: "terminal")

        mgr.updateProject(
            id: project.id,
            update: ProjectUpdate(name: "After", icon: icon)
        )

        #expect(mgr.projects[0].id == project.id)
        #expect(mgr.projects[0].name == "After")
        #expect(mgr.projects[0].path == project.path)
        #expect(mgr.projects[0].icon == icon)
        #expect(mgr.projects[0].color == "#d77b88")
        #expect(mgr.projects[0].addedAt == project.addedAt)
        #expect(mgr.projects[0].hiddenWorktreePaths == project.hiddenWorktreePaths)
        #expect(mgr.projects[0].startupScripts == .defaults)
        #expect(mgr.projects[0].mcpServers == project.mcpServers)
        #expect(mgr.projects[1] == other)

        mgr.updateProject(
            id: "missing",
            update: ProjectUpdate(name: "Ignored", icon: ProjectIcon.default(color: "#7fb978"))
        )

        #expect(mgr.projects[0].name == "After")
        #expect(mgr.projects[0].icon == icon)
        #expect(mgr.projects[1] == other)
    }

    @Test func updateProjectReplacesMCPServersWhenExplicitlyProvided() {
        let original = ProjectMCPServer.stdio(name: "filesystem", command: "npx")
        let replacement = ProjectMCPServer(
            id: "linear",
            name: "linear",
            transport: .http(url: "https://mcp.linear.app/mcp", headers: [])
        )
        let project = ProjectConfig(
            id: "project-1",
            name: "Before",
            path: "/tmp/before",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            mcpServers: [original]
        )
        let manager = ProjectsManager(persistedProjects: [project])

        manager.updateProject(
            id: project.id,
            update: ProjectUpdate(
                name: "After",
                icon: project.icon,
                mcpServers: [replacement]
            )
        )

        #expect(manager.projects[0].mcpServers == [replacement])
    }

    @Test func setWorktreeLaunchDefaultsPersistsPerProject() {
        let project = ProjectConfig(
            id: "project-1",
            name: "Alpha",
            path: "/tmp/alpha",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let mgr = ProjectsManager(persistedProjects: [project])

        #expect(mgr.projects[0].worktreeOpenAfterCreate == nil)
        #expect(mgr.projects[0].worktreeDefaultLauncherMode == nil)

        mgr.setWorktreeLaunchDefaults(
            projectId: "project-1",
            openAfterCreate: false,
            launcherMode: .acp
        )

        #expect(mgr.projects[0].worktreeOpenAfterCreate == false)
        #expect(mgr.projects[0].worktreeDefaultLauncherMode == .acp)
    }

    @Test func setWorktreeLaunchDefaultsIgnoresMissingProject() {
        let mgr = ProjectsManager(persistedProjects: [])
        mgr.setWorktreeLaunchDefaults(
            projectId: "missing",
            openAfterCreate: true,
            launcherMode: .terminal
        )
        #expect(mgr.projects.isEmpty)
    }
}

extension ProjectsManagerTests {
    @Test func hidingAndUnhidingFlipsVisibilityAndArchive() async throws {
        let repo = try await makeRepo(name: "delta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "delta", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let mainPath = trees[0].path

        mgr.setWorktreeHidden(projectId: project.id, path: mainPath, hidden: true)
        #expect(mgr.isWorktreeHidden(projectId: project.id, path: mainPath))
        #expect(mgr.visibleWorktrees(projectId: project.id).isEmpty)
        #expect(mgr.archivedWorktrees(projectId: project.id).count == 1)

        mgr.setWorktreeHidden(projectId: project.id, path: mainPath, hidden: false)
        #expect(!mgr.isWorktreeHidden(projectId: project.id, path: mainPath))
        #expect(mgr.visibleWorktrees(projectId: project.id).count == 1)
        #expect(mgr.archivedWorktrees(projectId: project.id).isEmpty)
    }

    @Test func refreshGarbageCollectsOrphanHiddenPaths() async throws {
        let repo = try await makeRepo(name: "epsilon")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "epsilon", color: "#5fb7c4")
        // Pre-seed a hidden path that doesn't correspond to any live worktree.
        let bogus = URL(fileURLWithPath: "/nonexistent/orphan-worktree")
        mgr.setWorktreeHidden(projectId: project.id, path: bogus, hidden: true)
        #expect(mgr.isWorktreeHidden(projectId: project.id, path: bogus))

        let gcDropped = try await mgr.refreshWorktrees(projectId: project.id)

        // Refresh should drop the orphan since git worktree list doesn't include it.
        #expect(gcDropped)
        #expect(!mgr.isWorktreeHidden(projectId: project.id, path: bogus))
    }

    @Test func refreshPrunesOnlyMissingGGWorktreeOverrides() async throws {
        let repo = try await makeRepo(name: "gg-override-prune")
        defer { try? FileManager.default.removeItem(at: repo) }
        let projectId = "gg-override-prune-project"
        let linked = try await WorktreeService().add(
            repoPath: repo,
            base: "main",
            branch: "feature/archived",
            destination: repo.appendingPathComponent("wt-archived"),
            projectId: projectId
        )
        let mainId = Worktree.makeId(path: repo)
        let staleId = "missing-worktree"
        let project = ProjectConfig(
            id: projectId,
            name: "gg-override-prune",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: Date(),
            hiddenWorktreePaths: [linked.path.path],
            ggWorktreeModes: [mainId: .on, linked.id: .off, staleId: .on]
        )
        let manager = ProjectsManager(persistedProjects: [project])

        let changed = try await manager.refreshWorktrees(projectId: projectId)

        #expect(changed)
        #expect(manager.projects[0].ggWorktreeModes == [mainId: .on, linked.id: .off])
        #expect(manager.ggWorktreeMode(projectId: projectId, worktreeId: staleId) == .inherit)
        #expect(manager.archivedWorktrees(projectId: projectId).map(\.id) == [linked.id])
    }

    @Test func refreshAllPopulatesMultipleProjects() async throws {
        let repoA = try await makeRepo(name: "eta")
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try await makeRepo(name: "theta")
        defer { try? FileManager.default.removeItem(at: repoB) }

        let mgr = ProjectsManager(persistedProjects: [])
        let projectA = try await mgr.addProject(path: repoA, displayName: "eta", color: "#5fb7c4")
        let projectB = try await mgr.addProject(path: repoB, displayName: "theta", color: "#c89d6f")

        // Verify no worktrees are loaded yet.
        #expect(mgr.worktrees(projectId: projectA.id).isEmpty)
        #expect(mgr.worktrees(projectId: projectB.id).isEmpty)

        let gcDropped = await mgr.refreshAll()

        let treesA = mgr.worktrees(projectId: projectA.id)
        let treesB = mgr.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesA.first?.branch == "main")
        #expect(treesB.count == 1)
        #expect(treesB.first?.branch == "main")
        #expect(!gcDropped)
    }

    @Test func refreshAllReturnsTrueWhenAnyProjectGarbageCollects() async throws {
        let repoA = try await makeRepo(name: "iota")
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try await makeRepo(name: "kappa")
        defer { try? FileManager.default.removeItem(at: repoB) }

        let mgr = ProjectsManager(persistedProjects: [])
        let projectA = try await mgr.addProject(path: repoA, displayName: "iota", color: "#5fb7c4")
        let projectB = try await mgr.addProject(path: repoB, displayName: "kappa", color: "#c89d6f")

        // Seed an orphan hidden path only on projectA.
        let bogus = URL(fileURLWithPath: "/nonexistent/orphan-worktree")
        mgr.setWorktreeHidden(projectId: projectA.id, path: bogus, hidden: true)

        let gcDropped = await mgr.refreshAll()

        // Should return true because projectA GC'd the orphan.
        #expect(gcDropped)
        #expect(!mgr.isWorktreeHidden(projectId: projectA.id, path: bogus))
        // Both projects should still have their main worktree.
        #expect(mgr.worktrees(projectId: projectA.id).count == 1)
        #expect(mgr.worktrees(projectId: projectB.id).count == 1)
    }

    @Test func refreshWithNoOrphansReturnsFalse() async throws {
        let repo = try await makeRepo(name: "zeta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "zeta", color: "#5fb7c4")
        let gcDropped = try await mgr.refreshWorktrees(projectId: project.id)
        #expect(!gcDropped)
    }

    @Test func optimisticWorktreeAppearsImmediately() async throws {
        let repo = try await makeRepo(name: "optimistic")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "optimistic", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)
        let before = mgr.worktrees(projectId: project.id)
        #expect(before.count == 1)

        let dest = repo.appendingPathComponent("wt-new")
        let optimistic = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: project.id,
            name: "feat-x",
            branch: "feat-x",
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        mgr.insertOptimisticWorktree(optimistic)
        mgr.setOperationState(id: optimistic.id, state: .creating)

        let after = mgr.worktrees(projectId: project.id)
        #expect(after.count == 2)
        #expect(after.contains { $0.id == optimistic.id })
        #expect(mgr.operationState(for: optimistic.id) == .creating)

        mgr.insertOptimisticWorktree(optimistic)
        #expect(mgr.worktrees(projectId: project.id).filter { $0.id == optimistic.id }.count == 1)
    }

    @Test func refreshReconcilesCreatingWorktreeWithoutCompletingIt() async throws {
        let repo = try await makeRepo(name: "reconcile")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "reconcile", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)

        let svc = WorktreeService()
        let dest = repo.appendingPathComponent("wt-reconcile")
        _ = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "reconcile-b",
            destination: dest,
            projectId: project.id
        )
        let live = try #require(
            try await svc.list(repoPath: repo, projectId: project.id)
                .first { $0.id == Worktree.makeId(path: dest) }
        )

        let optimistic = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: project.id,
            name: "optimistic-name",
            branch: "reconcile-b",
            path: dest,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        mgr.insertOptimisticWorktree(optimistic)
        mgr.setOperationState(id: optimistic.id, state: .creating)

        try await mgr.refreshWorktrees(projectId: project.id)

        let trees = mgr.worktrees(projectId: project.id)
        let reconciled = try #require(trees.first { $0.id == optimistic.id })
        #expect(reconciled.name == live.name)
        #expect(reconciled.lastActivity == live.lastActivity)
        #expect(mgr.operationState(for: optimistic.id) == .creating)
    }

    @Test func refreshKeepsCreatingWorktreeUntilGitSeesIt() async throws {
        let repo = try await makeRepo(name: "creating-pending")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "creating-pending", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-pending")
        let optimistic = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: project.id,
            name: "pending-b",
            branch: "pending-b",
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        mgr.insertOptimisticWorktree(optimistic)
        mgr.setOperationState(id: optimistic.id, state: .creating)

        try await mgr.refreshWorktrees(projectId: project.id)

        #expect(mgr.worktrees(projectId: project.id).contains { $0.id == optimistic.id })
        #expect(mgr.operationState(for: optimistic.id) == .creating)
    }

    @Test func refreshPreservesFailedWorktree() async throws {
        let repo = try await makeRepo(name: "fail-preserve")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "fail-preserve", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-fail")
        let optimistic = Worktree(
            id: Worktree.makeId(path: dest),
            projectId: project.id,
            name: "fail-b",
            branch: "fail-b",
            path: dest,
            status: .clean,
            lastActivity: Date()
        )
        mgr.insertOptimisticWorktree(optimistic)
        mgr.setOperationState(
            id: optimistic.id,
            state: .createFailed(
                projectId: project.id,
                message: "disk full",
                base: "main",
                ggWorktreeMode: .inherit
            )
        )

        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.contains { $0.id == optimistic.id })
        #expect(mgr.operationState(for: optimistic.id) == .createFailed(
            projectId: project.id,
            message: "disk full",
            base: "main",
            ggWorktreeMode: .inherit
        ))
    }

    @Test(arguments: [GGWorktreeMode.on, .off, .inherit])
    func refreshPromotesCreateFailedGGModeWhenWorktreeAppears(mode: GGWorktreeMode) async throws {
        let repo = try await makeRepo(name: "create-failed-live-\(mode.rawValue)")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(
            path: repo,
            displayName: "create-failed-live-\(mode.rawValue)",
            color: "#5fb7c4"
        )
        try await mgr.refreshWorktrees(projectId: project.id)

        let svc = WorktreeService()
        let dest = repo.appendingPathComponent("wt-cf-live-\(mode.rawValue)")
        let worktree = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "cf-live-\(mode.rawValue)",
            destination: dest,
            projectId: project.id
        )
        try await mgr.refreshWorktrees(projectId: project.id)

        if mode == .inherit {
            mgr.setGGWorktreeMode(projectId: project.id, worktreeId: worktree.id, mode: .on)
        }

        mgr.setOperationState(
            id: worktree.id,
            state: .createFailed(
                projectId: project.id,
                message: "transient",
                base: "main",
                ggWorktreeMode: mode
            )
        )
        let changed = try await mgr.refreshWorktrees(projectId: project.id)

        #expect(changed)
        #expect(mgr.operationState(for: worktree.id) == nil)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.contains { $0.id == worktree.id })
        #expect(mgr.ggWorktreeMode(projectId: project.id, worktreeId: worktree.id) == mode)
        #expect(mgr.projects[0].ggWorktreeModes[worktree.id] == (mode == .inherit ? nil : mode))
    }

    @Test func refreshDoesNotConsumeCreateFailureFromAnotherProjectWithSameWorktreeId() async throws {
        let repo = try await makeRepo(name: "create-failed-project-scope")
        defer { try? FileManager.default.removeItem(at: repo) }
        let origin = ProjectConfig(
            id: "origin",
            name: "origin",
            path: repo.path,
            color: "#5fb7c4",
            addedAt: .now
        )
        let other = ProjectConfig(
            id: "other",
            name: "other",
            path: repo.path,
            color: "#c89d6f",
            addedAt: .now
        )
        let manager = ProjectsManager(persistedProjects: [origin, other])
        try await manager.refreshWorktrees(projectId: origin.id)
        try await manager.refreshWorktrees(projectId: other.id)
        let sharedId = try #require(manager.worktrees(projectId: origin.id).first?.id)
        #expect(manager.worktrees(projectId: other.id).first?.id == sharedId)

        manager.setOperationState(
            id: sharedId,
            state: .createFailed(
                projectId: origin.id,
                message: "transient",
                base: "main",
                ggWorktreeMode: .on
            )
        )

        let otherChanged = try await manager.refreshWorktrees(projectId: other.id)
        #expect(!otherChanged)
        #expect(manager.operationState(for: sharedId) != nil)
        #expect(manager.ggWorktreeMode(projectId: other.id, worktreeId: sharedId) == .inherit)

        let originChanged = try await manager.refreshWorktrees(projectId: origin.id)
        #expect(originChanged)
        #expect(manager.operationState(for: sharedId) == nil)
        #expect(manager.ggWorktreeMode(projectId: origin.id, worktreeId: sharedId) == .on)
    }

    @Test func refreshClearsDeletingStateWhenWorktreeDisappears() async throws {
        let repo = try await makeRepo(name: "delete-clear")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "delete-clear", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)

        let svc = WorktreeService()
        let dest = repo.appendingPathComponent("wt-delete")
        let worktree = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "delete-b",
            destination: dest,
            projectId: project.id
        )
        try await mgr.refreshWorktrees(projectId: project.id)
        mgr.setOperationState(id: worktree.id, state: .deleting)

        try await svc.remove(repoPath: repo, worktree: worktree, deleteBranchIfMerged: false, force: false)
        try await mgr.refreshWorktrees(projectId: project.id)

        #expect(!mgr.worktrees(projectId: project.id).contains { $0.id == worktree.id })
        #expect(mgr.operationState(for: worktree.id) == nil)
    }

    @Test func refreshPreservesDeleteFailedStateForLiveWorktree() async throws {
        let repo = try await makeRepo(name: "delete-failed")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "delete-failed", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)
        let worktree = try #require(mgr.worktrees(projectId: project.id).first)

        mgr.setOperationState(id: worktree.id, state: .deleteFailed(message: "permission denied"))
        try await mgr.refreshWorktrees(projectId: project.id)

        #expect(mgr.worktrees(projectId: project.id).contains { $0.id == worktree.id })
        #expect(mgr.operationState(for: worktree.id) == .deleteFailed(message: "permission denied"))
    }

    @Test func refreshClearsDeleteFailedWhenWorktreeDisappears() async throws {
        let repo = try await makeRepo(name: "delete-failed-gone")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "delete-failed-gone", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)

        let svc = WorktreeService()
        let dest = repo.appendingPathComponent("wt-delete-fail")
        let worktree = try await svc.add(
            repoPath: repo,
            base: "main",
            branch: "delete-fail-b",
            destination: dest,
            projectId: project.id
        )
        try await mgr.refreshWorktrees(projectId: project.id)
        mgr.setOperationState(id: worktree.id, state: .deleteFailed(message: "permission denied"))

        // Simulate external removal; refresh should drop the ghost row.
        try await svc.remove(repoPath: repo, worktree: worktree, deleteBranchIfMerged: false, force: false)
        try await mgr.refreshWorktrees(projectId: project.id)

        #expect(!mgr.worktrees(projectId: project.id).contains { $0.id == worktree.id })
        #expect(mgr.operationState(for: worktree.id) == nil)
    }

    @Test func isMainTrueForPrimaryCheckout() async throws {
        let repo = try await makeRepo(name: "ismain-true")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "ismain-true", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        #expect(mgr.isMain(trees[0], in: project))
    }

    @Test func isMainFalseForFeatureWorktree() async throws {
        let repo = try await makeRepo(name: "ismain-false")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "ismain-false", color: "#c89d6f")

        let svc = WorktreeService()
        let dest = repo.appendingPathComponent("wt-feature")
        _ = try await svc.add(repoPath: repo, base: "main", branch: "feature-b", destination: dest, projectId: project.id)

        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 2)

        let repoCanonical = repo.standardizedFileURL.path
        let mainWorktree = try #require(trees.first { $0.path.standardizedFileURL.path == repoCanonical })
        let featureWorktree = try #require(trees.first { $0.path.standardizedFileURL.path != repoCanonical })

        #expect(mgr.isMain(mainWorktree, in: project))
        #expect(!mgr.isMain(featureWorktree, in: project))
    }
}
