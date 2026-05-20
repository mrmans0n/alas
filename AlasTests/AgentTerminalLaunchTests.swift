import Foundation
import Testing
@testable import Alas

@MainActor
struct AgentTerminalLaunchTests {
    private func agent(flag: String? = "--skip") -> AgentDefinition {
        AgentDefinition(
            id: "test-agent",
            displayName: "Test Agent",
            binary: "test-agent",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: flag,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }

    private func project(mode: ProjectStartupScriptMode, useBypass: Bool) -> ProjectConfig {
        var project = ProjectConfig(
            id: "project",
            name: "Project",
            path: "/tmp/project",
            color: "blue",
            addedAt: Date()
        )
        project.startupScripts.worktreeAgentMode = mode
        project.startupScripts.worktreeAgentUseBypassPermissions = useBypass
        return project
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func globalBypassAddsAgentFlag() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .useGlobal, useBypass: false)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func disabledProjectModeOmitsBypassFlag() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .disabled, useBypass: true)
        )
        #expect(command == "test-agent")
    }

    @Test func projectOverrideBypassWinsOverGlobal() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = false
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .overrideGlobal, useBypass: true)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func missingBypassFlagCannotBeAppended() {
        let state = AppState()
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(flag: nil),
            project: project(mode: .useGlobal, useBypass: true)
        )
        #expect(command == "test-agent")
    }

    @Test func binaryPathIsShellQuoted() {
        var custom = agent()
        custom.binaryOverride = "/Applications/Test Agent/bin/agent"
        let state = AppState()
        let command = state.agentStartupCommand(
            for: custom,
            project: project(mode: .disabled, useBypass: false)
        )
        #expect(command == "'/Applications/Test Agent/bin/agent'")
    }

    @Test func disabledAgentIdDoesNotLaunch() {
        let state = AppState()
        let worktree = Worktree(
            id: "wt",
            projectId: "project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/project"),
            status: .clean,
            lastActivity: Date()
        )

        #expect(throws: AppState.AgentTerminalLaunchError.self) {
            _ = try state.openAgentTerminalTab(for: worktree, agentId: "missing")
        }
    }

    @Test func missingProjectDoesNotLaunch() {
        let state = AppState()
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [agent()],
            installedIds: ["test-agent"]
        )
        let worktree = Worktree(
            id: "wt",
            projectId: "missing-project",
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/project"),
            status: .clean,
            lastActivity: Date()
        )

        #expect(throws: AppState.AgentTerminalLaunchError.self) {
            _ = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")
        }
    }

    @Test func manualLaunchAppendsTerminalTabWithStartupSuffix() throws {
        var capturedSuffix: String?
        let project = project(mode: .useGlobal, useBypass: false)
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/project"),
            status: .clean,
            lastActivity: Date()
        )
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, startupScriptSuffix in
                capturedSuffix = startupScriptSuffix
                return AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
            }
        )
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [agent()],
            installedIds: ["test-agent"]
        )

        let tab = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")

        #expect(capturedSuffix == "test-agent --skip")
        #expect(state.tabs.tabs(forWorktree: worktree.id) == [tab])
        if case .terminal(let terminal) = tab {
            #expect(terminal.root.firstLeaf().sessionId == "session-1")
        } else {
            Issue.record("Expected a terminal tab")
        }
    }
}
