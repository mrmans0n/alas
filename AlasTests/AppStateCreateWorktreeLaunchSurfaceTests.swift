import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCreateWorktreeLaunchSurfaceTests {
    private struct TerminalOpenFailure: LocalizedError {
        var errorDescription: String? { "Terminal failed to open" }
    }

    private struct FailingStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {
            throw NSError(
                domain: "AppStateCreateWorktreeLaunchSurfaceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "write rejected"]
            )
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-launchsurface-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    private func waitForOperationToClear(
        _ mgr: ProjectsManager,
        id: String,
        projectId: String,
        timeoutSeconds: Double = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if mgr.operationState(forWorktreeId: id, projectId: projectId) == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to clear for id \(id)")
    }

    @Test
    func terminalLaunchSurfaceRecordsLaunchFailureWhenTerminalOpenFails() async throws {
        let repo = try await makeRepo(name: "terminal-open-fails")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState(
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                throw TerminalOpenFailure()
            }
        )
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "terminal-open-fails",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        state.config.agents.builtinState["claude"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: nil,
            extraTerminalArgs: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: ["claude"]
        )

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-terminal-open-fails-\(UUID().uuidString)")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "terminal-open-fails",
            destination: dest,
            runStartup: false,
            launchSurface: .terminal(agentId: "claude")
        )
        #expect(!id.isEmpty)

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }

        guard case .launchFailed(_, let message, let launchSurface) =
            state.projectsManager.operationState(forWorktreeId: id, projectId: project.id)
        else {
            Issue.record("Expected launchFailed state")
            return
        }
        #expect(message == TerminalOpenFailure().localizedDescription)
        #expect(launchSurface == .terminal(agentId: "claude"))
        #expect(state.tabs.tabs(forWorktree: id).isEmpty)
    }

    @Test
    func createWorktreeCanFinishWithoutHookWhenApprovalSaveFails() async throws {
        let repo = try await makeRepo(name: "hook-save-failure")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState(
            store: FailingStore(),
            persistenceErrorHandler: { _, _ in }
        )
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "hook-save-failure",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        state.repoHookLoader = RepoHookLoader { _, _, _ in
            .data(Data("echo repository hook".utf8))
        }

        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "hook-save-failure",
            destination: repo.appendingPathComponent("wt-hook-save-failure"),
            runStartup: true,
            launchSurface: .none
        )

        for _ in 0..<80 {
            if state.repoHookApprovalQueue.activeRequest?.hook != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(state.repoHookApprovalQueue.activeRequest?.hook?.event == .worktreeCreate)
        guard state.repoHookApprovalQueue.activeRequest?.hook != nil else { return }
        state.repoHookApprovalQueue.decide(.approve)

        for _ in 0..<80 {
            if state.repoHookApprovalQueue.activeRequest?.failure != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(
            state.repoHookApprovalQueue.activeRequest?.failure?.message
                == "Alas couldn't save this repository hook approval. The hook was not run."
        )
        guard state.repoHookApprovalQueue.activeRequest?.failure != nil else { return }
        state.repoHookApprovalQueue.decide(.skip)

        try await waitForOperationToClear(state.projectsManager, id: id, projectId: project.id)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
        #expect(
            !state.projectsManager.isRepoHookApproved(
                projectId: project.id,
                hash: RepoHookTrust.hash(
                    event: .worktreeCreate,
                    bytes: Data("echo repository hook".utf8)
                )
            )
        )
    }

    @Test
    func missingWorkspaceProjectRequiresAnExplicitHookDecision() async throws {
        let state = AppState()
        let request = WorkspaceRepoHookRequest(
            projectID: "missing-\(UUID().uuidString)",
            worktreePath: "/tmp/missing-workspace-project",
            memberPolicy: WorkspaceMemberConfigurationSnapshot(
                setupScript: "",
                ggMode: .off,
                mcpServers: [],
                projectWorktreeCreateMode: .useGlobal,
                projectWorktreeCreateScript: ""
            )
        )
        let task = Task {
            try await state.preparedWorkspaceRepoHook(request)
        }

        for _ in 0..<80 {
            if state.repoHookApprovalQueue.activeRequest?.failure != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let failure = state.repoHookApprovalQueue.activeRequest?.failure
        #expect(failure?.event == .worktreeCreate)
        #expect(failure?.source == .local)
        #expect(failure?.message == "The Workspace member's project trust record is unavailable, so its repository hook approval cannot be checked.")
        #expect(state.repoHookApprovalQueue.activeRequest?.context == .workspaceMember)
        guard failure != nil else {
            task.cancel()
            return
        }

        state.repoHookApprovalQueue.decide(.skip)
        #expect(try await task.value == nil)
    }

    @Test
    func acpLaunchSurfaceOpensAcpSessionTab() async throws {
        let repo = try await makeRepo(name: "acp")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "acp-repo",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        // Enable the Claude built-in (ACP-capable) by force-installing it
        // in the registry. Mirrors the pattern in AgentTerminalLaunchTests.
        state.config.agents.builtinState["claude"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: nil,
            extraTerminalArgs: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: ["claude"]
        )

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-acp-\(UUID().uuidString)")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "acp-branch",
            destination: dest,
            runStartup: false,
            launchSurface: .acp(agentId: "claude")
        )
        #expect(!id.isEmpty)

        try await waitForOperationToClear(state.projectsManager, id: id, projectId: project.id)

        // Exactly one ACP session tab on the new worktree, no terminal tab.
        let tabs = state.tabs.tabs(forWorktree: id)
        let acpTabs = tabs.filter {
            if case .acpSession = $0 { return true }
            return false
        }
        let terminalTabs = tabs.filter {
            if case .terminal = $0 { return true }
            return false
        }
        #expect(acpTabs.count == 1)
        #expect(terminalTabs.isEmpty)
    }

    @Test
    func terminalLaunchSurfaceWithUnavailableAgentLeavesLaunchFailure() async throws {
        let repo = try await makeRepo(name: "terminal-unavailable-agent")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "terminal-unavailable-agent",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        state.config.agents.builtinState["claude"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: nil,
            extraTerminalArgs: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: []
        )

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-terminal-unavailable-\(UUID().uuidString)")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "terminal-unavailable",
            destination: dest,
            runStartup: false,
            launchSurface: .terminal(agentId: "claude")
        )
        #expect(!id.isEmpty)

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }

        guard case .launchFailed(_, let message, let launchSurface) =
            state.projectsManager.operationState(forWorktreeId: id, projectId: project.id)
        else {
            Issue.record("Expected launchFailed state")
            return
        }
        #expect(message == AppState.WorktreeAgentStartupError.agentUnavailable.localizedDescription)
        #expect(launchSurface == .terminal(agentId: "claude"))
        #expect(state.tabs.tabs(forWorktree: id).isEmpty)
    }

    @Test
    func acpLaunchSurfaceWithUnavailableAgentLeavesLaunchFailure() async throws {
        let repo = try await makeRepo(name: "acp-unavailable-agent")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "acp-unavailable-agent",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        state.config.agents.builtinState["claude"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: nil,
            extraTerminalArgs: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: []
        )

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-acp-unavailable-\(UUID().uuidString)")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "acp-unavailable",
            destination: dest,
            runStartup: false,
            launchSurface: .acp(agentId: "claude")
        )
        #expect(!id.isEmpty)

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }

        guard case .launchFailed(_, let message, let launchSurface) =
            state.projectsManager.operationState(forWorktreeId: id, projectId: project.id)
        else {
            Issue.record("Expected launchFailed state")
            return
        }
        #expect(message == AppState.WorktreeAgentStartupError.agentUnavailable.localizedDescription)
        #expect(launchSurface == .acp(agentId: "claude"))
        #expect(state.tabs.tabs(forWorktree: id).isEmpty)
    }

    @Test
    func retryingAcpLaunchRefreshesAvailabilityAndTargetsFailedWorktree() async throws {
        let repo = try await makeRepo(name: "acp-retry-target")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "acp-retry-target",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        guard let main = state.projectsManager.worktrees(projectId: project.id).first else {
            Issue.record("Expected main worktree")
            return
        }
        state.config.agents.builtinState["claude"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: nil,
            extraTerminalArgs: nil
        )
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: []
        )

        let dest = repo.deletingLastPathComponent()
            .appendingPathComponent("wt-acp-retry-target-\(UUID().uuidString)")
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "acp-retry-target",
            destination: dest,
            runStartup: false,
            launchSurface: .acp(agentId: "claude")
        )
        #expect(!id.isEmpty)

        try await waitForOperationStateMatching(state.projectsManager, id: id, projectId: project.id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }
        guard let failedWorktree = state.projectsManager.worktrees(projectId: project.id)
            .first(where: { $0.id == id })
        else {
            Issue.record("Expected failed worktree to remain in the project")
            return
        }

        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: ["claude"]
        )
        state.selectWorktree(id: main.id)

        await state.retryWorktreeLaunch(failedWorktree, project: project)

        #expect(state.projectsManager.operationState(forWorktreeId: id, projectId: project.id) == nil)
        let failedWorktreeTabs = state.tabs.tabs(forWorktree: id)
        let mainTabs = state.tabs.tabs(forWorktree: main.id)
        #expect(failedWorktreeTabs.contains {
            if case .acpSession = $0 { return true }
            return false
        })
        #expect(!mainTabs.contains {
            if case .acpSession = $0 { return true }
            return false
        })
    }

    private func waitForOperationStateMatching(
        _ mgr: ProjectsManager,
        id: String,
        projectId: String,
        matches: (WorktreeOperationState?) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if matches(mgr.operationState(forWorktreeId: id, projectId: projectId)) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to match for id \(id)")
    }
}
