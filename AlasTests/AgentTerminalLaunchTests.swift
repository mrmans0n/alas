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
}
