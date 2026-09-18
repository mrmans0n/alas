import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCreateWorktreeLaunchSurfaceTests {
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
        timeoutSeconds: Double = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if mgr.operationState(for: id) == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to clear for id \(id)")
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

        try await waitForOperationToClear(state.projectsManager, id: id)

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

        try await waitForOperationStateMatching(state.projectsManager, id: id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }

        guard case .launchFailed(_, let message, let launchSurface) =
            state.projectsManager.operationState(for: id)
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

        try await waitForOperationStateMatching(state.projectsManager, id: id) { operation in
            if case .launchFailed = operation { return true }
            return false
        }

        guard case .launchFailed(_, let message, let launchSurface) =
            state.projectsManager.operationState(for: id)
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

        try await waitForOperationStateMatching(state.projectsManager, id: id) { operation in
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

        #expect(state.projectsManager.operationState(for: id) == nil)
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
        matches: (WorktreeOperationState?) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if matches(mgr.operationState(for: id)) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to match for id \(id)")
    }
}
