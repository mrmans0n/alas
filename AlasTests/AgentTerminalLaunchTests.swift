import Foundation
import Testing
@testable import Alas

@MainActor
struct AgentTerminalLaunchTests {
    private func agent(flag: String? = "--skip", extraArgs: [String]? = nil) -> AgentDefinition {
        AgentDefinition(
            id: "test-agent",
            displayName: "Test Agent",
            binary: "test-agent",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: flag,
            extraTerminalArgs: extraArgs,
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

    private func tmpDir() -> (dir: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    private func copilotHookURL(in root: URL) -> URL {
        root
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("alas-notify.json", isDirectory: false)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func globalBypassAddsAgentFlag() {
        let state = AppState(store: MemoryStore())
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .useGlobal, useBypass: false)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func disabledProjectModeOmitsBypassFlag() {
        let state = AppState(store: MemoryStore())
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .disabled, useBypass: true)
        )
        #expect(command == "test-agent")
    }

    @Test func projectOverrideBypassWinsOverGlobal() {
        let state = AppState(store: MemoryStore())
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = false
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .overrideGlobal, useBypass: true)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func missingBypassFlagCannotBeAppended() {
        let state = AppState(store: MemoryStore())
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
        let state = AppState(store: MemoryStore())
        let command = state.agentStartupCommand(
            for: custom,
            project: project(mode: .disabled, useBypass: false)
        )
        #expect(command == "'/Applications/Test Agent/bin/agent'")
    }

    @Test func missingAgentIdDoesNotLaunch() {
        let state = AppState(store: MemoryStore())
        let project = project(mode: .useGlobal, useBypass: false)
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/project"),
            status: .clean,
            lastActivity: Date()
        )

        #expect(throws: AppState.AgentTerminalLaunchError.agentUnavailable) {
            _ = try state.openAgentTerminalTab(for: worktree, agentId: "missing")
        }
    }

    @Test func missingProjectDoesNotLaunch() {
        let state = AppState(store: MemoryStore())
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

        #expect(throws: AppState.AgentTerminalLaunchError.projectUnavailable) {
            _ = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")
        }
    }

    @Test func manualLaunchAppendsTerminalTabWithStartupSuffix() throws {
        var capturedSuffix: String?
        var capturedIncludeUserStartupScript: Bool?
        var capturedEnvironmentOverrides: [String: String]?
        var capturedEnvironmentRemovals: Set<String>?
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
            terminalSessionOpener: { _, _, _, _, _, startupScriptSuffix, includeUserStartupScript, environmentOverrides, environmentRemovals in
                capturedSuffix = startupScriptSuffix
                capturedIncludeUserStartupScript = includeUserStartupScript
                capturedEnvironmentOverrides = environmentOverrides
                capturedEnvironmentRemovals = environmentRemovals
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
        #expect(capturedIncludeUserStartupScript == true)
        #expect(capturedEnvironmentOverrides == [:])
        #expect(capturedEnvironmentRemovals == [])
        #expect(state.tabs.tabs(forWorktree: worktree.id) == [tab])
        if case .terminal(let terminal) = tab {
            #expect(terminal.root.firstLeaf().sessionId == "session-1")
        } else {
            Issue.record("Expected a terminal tab")
        }
    }

    @Test func acpAuthLaunchAppendsQuotedCommandAndEnvPrefix() throws {
        var capturedSuffix: String?
        var capturedIncludeUserStartupScript: Bool?
        var capturedEnvironmentOverrides: [String: String]?
        var capturedEnvironmentRemovals: Set<String>?
        var capturedInheritParentEnv: Bool?
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
            terminalSessionOpener: { _, _, terminalConfig, _, _, startupScriptSuffix, includeUserStartupScript, environmentOverrides, environmentRemovals in
                capturedSuffix = startupScriptSuffix
                capturedInheritParentEnv = terminalConfig.inheritParentEnv
                capturedIncludeUserStartupScript = includeUserStartupScript
                capturedEnvironmentOverrides = environmentOverrides
                capturedEnvironmentRemovals = environmentRemovals
                return AppState.OpenedTerminalSession(id: "auth-session", foregroundPid: { nil })
            }
        )
        state.config.terminal.inheritParentEnv = false
        state.projectsManager = ProjectsManager(persistedProjects: [project])

        _ = try state.openACPAuthTerminalTab(
            for: worktree,
            command: ACPAuthTerminalCommand(
                command: "/Applications/Auth CLI/bin/node",
                args: ["/opt/claude agent/acp", "--cli"],
                env: ["TOKEN": "abc'123", "A": "two words"]
            ),
            onExit: {}
        )

        #expect(capturedSuffix == [
            "A='two words' TOKEN='abc'\\''123' '/Applications/Auth CLI/bin/node' '/opt/claude agent/acp' --cli",
            "exit_code=$?",
            "exit \"$exit_code\"",
        ].joined(separator: "\n"))
        #expect(capturedIncludeUserStartupScript == false)
        #expect(capturedInheritParentEnv == true)
        #expect(capturedEnvironmentOverrides?["A"] == "two words")
        #expect(capturedEnvironmentOverrides?["TOKEN"] == "abc'123")
        #expect(capturedEnvironmentOverrides?["PATH"] != nil)
        #expect(capturedEnvironmentRemovals == ACPProcessEnvironment.agentSessionMarkerKeys)
    }

    @Test func acpAuthLaunchRejectsInvalidEnvKeyBeforeOpeningTerminal() {
        var openerCalled = false
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
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openerCalled = true
                return AppState.OpenedTerminalSession(id: "auth-session", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])

        #expect(throws: AppState.ACPAuthTerminalLaunchError.invalidEnvKey("BAD-NAME")) {
            _ = try state.openACPAuthTerminalTab(
                for: worktree,
                command: ACPAuthTerminalCommand(
                    command: "agent",
                    args: ["login"],
                    env: ["BAD-NAME": "x"]
                ),
                onExit: {}
            )
        }
        #expect(!openerCalled)
        #expect(state.tabs.tabs(forWorktree: worktree.id).isEmpty)
    }

    @Test func acpAuthLaunchRunsExitCallbackWhenTerminalExits() throws {
        var exitCount = 0
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
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                AppState.OpenedTerminalSession(id: "auth-session", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])

        _ = try state.openACPAuthTerminalTab(
            for: worktree,
            command: ACPAuthTerminalCommand(command: "agent", args: ["login"], env: [:])
        ) {
            exitCount += 1
        }

        state.handleTerminalProcessExited(worktreeId: worktree.id, leafId: "auth-session", processAlive: false)
        state.handleTerminalProcessExited(worktreeId: worktree.id, leafId: "auth-session", processAlive: false)

        #expect(exitCount == 1)
    }

    @Test func acpAuthManualTerminalCloseRemovesExitCallbackWithoutInvoking() throws {
        var exitCount = 0
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
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                AppState.OpenedTerminalSession(id: "auth-session", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])

        _ = try state.openACPAuthTerminalTab(
            for: worktree,
            command: ACPAuthTerminalCommand(command: "agent", args: ["login"], env: [:])
        ) {
            exitCount += 1
        }

        state.closeFocusedPane(worktreeId: worktree.id)
        state.handleTerminalProcessExited(worktreeId: worktree.id, leafId: "auth-session", processAlive: false)

        #expect(exitCount == 0)
    }

    @Test func launchingCopilotInstallsHookBeforeOpeningTerminal() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        var project = project(mode: .useGlobal, useBypass: false)
        project.path = dir.path
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: dir,
            status: .clean,
            lastActivity: Date()
        )
        let hookURL = copilotHookURL(in: dir)
        var hookExistedBeforeOpen = false
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                hookExistedBeforeOpen = FileManager.default.fileExists(atPath: hookURL.path)
                return AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [],
            installedIds: ["copilot"]
        )

        _ = try state.openAgentTerminalTab(for: worktree, agentId: "copilot")

        #expect(hookExistedBeforeOpen)
        #expect(FileManager.default.fileExists(atPath: hookURL.path))
    }

    @Test func launchingCopilotForRemoteWorktreeSkipsLocalHookInstall() throws {
        var project = project(mode: .useGlobal, useBypass: false)
        project.path = "/srv/project"
        project.host = "devbox"
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/srv/project"),
            status: .clean,
            lastActivity: Date()
        )
        var openerCalled = false
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openerCalled = true
                return AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [],
            installedIds: ["copilot"]
        )

        _ = try state.openAgentTerminalTab(for: worktree, agentId: "copilot")

        #expect(openerCalled)
    }

    @Test func launchingNonCopilotDoesNotCreateCopilotHook() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        var project = project(mode: .useGlobal, useBypass: false)
        project.path = dir.path
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: dir,
            status: .clean,
            lastActivity: Date()
        )
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [agent()],
            installedIds: ["test-agent"]
        )

        _ = try state.openAgentTerminalTab(for: worktree, agentId: "test-agent")

        #expect(!FileManager.default.fileExists(atPath: copilotHookURL(in: dir).path))
    }

    @Test func launchingCopilotWithUnmanagedHookDoesNotOpenTerminal() throws {
        let (dir, cleanup) = tmpDir()
        defer { cleanup() }
        var project = project(mode: .useGlobal, useBypass: false)
        project.path = dir.path
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: dir,
            status: .clean,
            lastActivity: Date()
        )
        let hookURL = copilotHookURL(in: dir)
        try FileManager.default.createDirectory(
            at: hookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"version":1,"hooks":{}}"#.write(to: hookURL, atomically: true, encoding: .utf8)
        var openerCalled = false
        var launchErrorTitle: String?
        let state = AppState(
            store: MemoryStore(),
            fileActionErrorHandler: { title, _ in
                launchErrorTitle = title
            },
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openerCalled = true
                return AppState.OpenedTerminalSession(id: "session-1", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.agentRegistry = AgentRegistry(
            builtinState: [:],
            customs: [],
            installedIds: ["copilot"]
        )

        #expect(throws: CopilotInstallerError.self) {
            _ = try state.openAgentTerminalTab(for: worktree, agentId: "copilot")
        }

        #expect(!openerCalled)
        #expect(launchErrorTitle == "Launch Agent Failed")
    }

    @Test func extraTerminalArgsInsertedBeforeBypassFlag() {
        let state = AppState(store: MemoryStore())
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(extraArgs: ["--model", "sonnet"]),
            project: project(mode: .useGlobal, useBypass: false)
        )
        #expect(command == "test-agent --model sonnet --skip")
    }

    @Test func extraTerminalArgsNilDoesNotChangeCommand() {
        let state = AppState(store: MemoryStore())
        state.config.agents.worktreeAutoLaunch.useBypassPermissions = true
        let command = state.agentStartupCommand(
            for: agent(),
            project: project(mode: .useGlobal, useBypass: false)
        )
        #expect(command == "test-agent --skip")
    }

    @Test func extraTerminalArgsAloneWithoutBypass() {
        let state = AppState(store: MemoryStore())
        let command = state.agentStartupCommand(
            for: agent(flag: nil, extraArgs: ["--verbose"]),
            project: project(mode: .disabled, useBypass: false)
        )
        #expect(command == "test-agent --verbose")
    }
}
