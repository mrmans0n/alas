import Foundation
import Testing
@testable import Alas

@Suite("Workspace configuration resolution")
struct WorkspaceConfigurationResolverTests {
    @Test("workspace shared settings override global settings and member settings append project setup")
    func resolvesSharedAndMemberSettings() {
        let memberID = UUID()
        let project = project(
            startupScripts: .init(
                sessionOpenMode: .useGlobal,
                sessionOpenScript: "",
                worktreeCreateMode: .appendToGlobal,
                worktreeCreateScript: "project setup"
            ),
            ggMode: .auto,
            mcpServers: [.stdio(name: "project", command: "project-mcp")]
        )
        let workspace = WorkspaceConfiguration(
            sharedStartupScripts: .init(
                sessionOpenMode: .overrideGlobal,
                sessionOpenScript: "workspace open",
                worktreeCreateMode: .useGlobal,
                worktreeCreateScript: ""
            ),
            creationLaunchPreference: .override(.init(openAfterCreate: false, launcherMode: .terminal)),
            memberConfigurations: [memberID: .init(
                setupScript: .append("member setup"),
                ggMode: .override(.on),
                mcpServers: .append([.stdio(name: "member", command: "member-mcp")])
            )]
        )

        let snapshot = WorkspaceConfigurationResolver.resolve(.init(
            globalTerminal: terminal(startup: "global open", create: "global setup"),
            globalLaunchPreference: .init(openAfterCreate: true, launcherMode: .acp),
            workspaceConfiguration: workspace,
            members: [.init(id: memberID, project: project, checkoutRoot: "/checkout", worktreePath: "/checkout/repo")],
            availableLauncherModes: [.terminal, .acp],
            enabledAgentIDs: []
        ))

        #expect(snapshot.shared.sessionOpenScript == "workspace open")
        #expect(snapshot.shared.worktreeCreateScript == "global setup")
        #expect(snapshot.shared.globalWorktreeCreateScript == "global setup")
        #expect(snapshot.shared.creationLaunchPreference == .init(openAfterCreate: false, launcherMode: .terminal))
        #expect(snapshot.members[memberID]?.setupScript == "global setup\nproject setup\nmember setup")
        #expect(snapshot.members[memberID]?.ggMode == .on)
        #expect(snapshot.members[memberID]?.mcpServers.map(\.server.name) == ["project", "member"])
        #expect(snapshot.members[memberID]?.mcpServers.allSatisfy { $0.checkoutRoot == "/checkout" } == true)
        #expect(snapshot.members[memberID]?.mcpServers.allSatisfy { $0.projectDirectory == "/checkout" } == true)
    }

    @Test("disabled member settings suppress inherited settings and unavailable optional choices warn")
    func disablesAndWarns() {
        let memberID = UUID()
        let snapshot = WorkspaceConfigurationResolver.resolve(.init(
            globalTerminal: terminal(startup: "global", create: "setup"),
            globalLaunchPreference: .init(openAfterCreate: true, launcherMode: .acp, agentID: "missing"),
            workspaceConfiguration: .init(
                creationLaunchPreference: .override(.init(openAfterCreate: true, launcherMode: .acp, agentID: "also-missing")),
                memberConfigurations: [memberID: .init(setupScript: .disabled, ggMode: .disabled, mcpServers: .disabled)]
            ),
            members: [.init(id: memberID, project: project(), checkoutRoot: "/checkout", worktreePath: "/checkout/repo")],
            availableLauncherModes: [.terminal],
            enabledAgentIDs: []
        ))

        #expect(snapshot.members[memberID]?.setupScript == "")
        #expect(snapshot.members[memberID]?.ggMode == .off)
        #expect(snapshot.members[memberID]?.mcpServers.isEmpty == true)
        #expect(snapshot.shared.creationLaunchPreference.launcherMode == .terminal)
        #expect(snapshot.warnings.contains(where: { $0.message.contains("ACP launcher") }))
        #expect(snapshot.warnings.contains(where: { $0.message.contains("also-missing") }))
    }

    @Test("snapshot stays unchanged after live project and workspace configuration change")
    func freezesResolvedValues() {
        let memberID = UUID()
        var project = project(mcpServers: [.stdio(name: "before", command: "before")])
        var workspace = WorkspaceConfiguration(memberConfigurations: [memberID: .init(mcpServers: .inherit)])
        let input = WorkspaceConfigurationResolver.Input(
            globalTerminal: terminal(startup: "", create: ""),
            globalLaunchPreference: .inherit,
            workspaceConfiguration: workspace,
            members: [.init(id: memberID, project: project, checkoutRoot: "/checkout", worktreePath: "/checkout/repo")],
            availableLauncherModes: [.terminal, .acp],
            enabledAgentIDs: []
        )
        let snapshot = WorkspaceConfigurationResolver.resolve(input)
        project.mcpServers = [.stdio(name: "after", command: "after")]
        workspace.memberConfigurations[memberID] = .init(mcpServers: .disabled)

        #expect(snapshot.members[memberID]?.mcpServers.map(\.server.name) == ["before"])
    }

    private func project(
        startupScripts: ProjectStartupScripts = .defaults,
        ggMode: GGProjectMode = .auto,
        mcpServers: [ProjectMCPServer] = []
    ) -> ProjectConfig {
        .init(id: UUID().uuidString, name: "Repo", path: "/repo", color: "blue", addedAt: .now, startupScripts: startupScripts, mcpServers: mcpServers, ggMode: ggMode)
    }

    private func terminal(startup: String, create: String) -> AppConfig.Terminal {
        .init(shell: "/bin/zsh", workingDirectory: "worktreeRoot", startupScript: startup, worktreeCreateScript: create, inheritParentEnv: true, fontFamily: "Menlo", fontSize: 12, cursorStyle: "block", cursorBlink: false, scrollbackLines: 1_000, bell: "off", syncTabTitleWithTerminalTitle: false)
    }
}
