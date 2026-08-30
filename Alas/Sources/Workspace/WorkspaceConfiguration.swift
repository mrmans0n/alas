import Foundation

/// The explicit inheritance operation used by Workspace configuration. A
/// Workspace never reinterprets a frozen checkout snapshot from live settings.
enum WorkspaceConfigurationMode: String, Codable, Equatable, Sendable {
    case inherit
    case append
    case override
    case disabled
}

struct WorkspaceScriptConfiguration: Codable, Equatable, Sendable {
    var mode: WorkspaceConfigurationMode
    var script: String

    static let inherit = Self(mode: .inherit, script: "")
    static let disabled = Self(mode: .disabled, script: "")

    static func append(_ script: String) -> Self { .init(mode: .append, script: script) }
    static func override(_ script: String) -> Self { .init(mode: .override, script: script) }
}

struct CreationLaunchPreference: Codable, Equatable, Sendable {
    var openAfterCreate: Bool?
    var launcherMode: AppConfig.LauncherMode?
    var agentID: String?
    var useBypassPermissions: Bool?

    static let inherit = Self()

    init(
        openAfterCreate: Bool? = nil,
        launcherMode: AppConfig.LauncherMode? = nil,
        agentID: String? = nil,
        useBypassPermissions: Bool? = nil
    ) {
        self.openAfterCreate = openAfterCreate
        self.launcherMode = launcherMode
        self.agentID = agentID
        self.useBypassPermissions = useBypassPermissions
    }

    func merging(_ override: CreationLaunchPreference) -> CreationLaunchPreference {
        .init(
            openAfterCreate: override.openAfterCreate ?? openAfterCreate,
            launcherMode: override.launcherMode ?? launcherMode,
            agentID: override.agentID ?? agentID,
            useBypassPermissions: override.useBypassPermissions ?? useBypassPermissions
        )
    }
}

struct WorkspaceLaunchPreferenceConfiguration: Codable, Equatable, Sendable {
    var mode: WorkspaceConfigurationMode
    var preference: CreationLaunchPreference

    static let inherit = Self(mode: .inherit, preference: .inherit)

    static func override(_ preference: CreationLaunchPreference) -> Self {
        .init(mode: .override, preference: preference)
    }
}

struct WorkspaceMCPServerConfiguration: Codable, Equatable, Sendable {
    var mode: WorkspaceConfigurationMode
    var servers: [ProjectMCPServer]

    static let inherit = Self(mode: .inherit, servers: [])
    static let disabled = Self(mode: .disabled, servers: [])

    static func append(_ servers: [ProjectMCPServer]) -> Self { .init(mode: .append, servers: servers) }
    static func override(_ servers: [ProjectMCPServer]) -> Self { .init(mode: .override, servers: servers) }
}

struct WorkspaceMemberConfiguration: Codable, Equatable, Sendable {
    var setupScript: WorkspaceScriptConfiguration
    var ggMode: WorkspaceConfigurationModeValue<GGProjectMode>
    var mcpServers: WorkspaceMCPServerConfiguration

    init(
        setupScript: WorkspaceScriptConfiguration = .inherit,
        ggMode: WorkspaceConfigurationModeValue<GGProjectMode> = .inherit,
        mcpServers: WorkspaceMCPServerConfiguration = .inherit
    ) {
        self.setupScript = setupScript
        self.ggMode = ggMode
        self.mcpServers = mcpServers
    }
}

struct WorkspaceConfigurationModeValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var mode: WorkspaceConfigurationMode
    var value: Value?

    static var inherit: Self { .init(mode: .inherit, value: nil) }
    static var disabled: Self { .init(mode: .disabled, value: nil) }
    static func override(_ value: Value) -> Self { .init(mode: .override, value: value) }
}

struct WorkspaceConfiguration: Codable, Equatable, Sendable {
    var sharedStartupScripts: ProjectStartupScripts?
    var creationLaunchPreference: WorkspaceLaunchPreferenceConfiguration
    var memberConfigurations: [UUID: WorkspaceMemberConfiguration]

    init(
        sharedStartupScripts: ProjectStartupScripts? = nil,
        creationLaunchPreference: WorkspaceLaunchPreferenceConfiguration = .inherit,
        memberConfigurations: [UUID: WorkspaceMemberConfiguration] = [:]
    ) {
        self.sharedStartupScripts = sharedStartupScripts
        self.creationLaunchPreference = creationLaunchPreference
        self.memberConfigurations = memberConfigurations
    }
}

struct WorkspaceMCPServerDescriptor: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var server: ProjectMCPServer
    var projectDirectory: String
    var worktreeDirectory: String
    var checkoutRoot: String

    init(id: String, server: ProjectMCPServer, projectDirectory: String, worktreeDirectory: String, checkoutRoot: String? = nil) {
        self.id = id
        self.server = server
        self.projectDirectory = projectDirectory
        self.worktreeDirectory = worktreeDirectory
        self.checkoutRoot = checkoutRoot ?? projectDirectory
    }
}

struct WorkspaceConfigurationWarning: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var message: String

    init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

struct WorkspaceSharedConfigurationSnapshot: Codable, Equatable, Sendable {
    var sessionOpenScript: String
    var worktreeCreateScript: String
    var creationLaunchPreference: CreationLaunchPreference
}

struct WorkspaceMemberConfigurationSnapshot: Codable, Equatable, Sendable {
    var setupScript: String
    var ggMode: GGProjectMode
    var mcpServers: [WorkspaceMCPServerDescriptor]
}

enum WorkspaceConfigurationResolver {
    struct MemberInput: Sendable {
        var id: UUID
        var project: ProjectConfig
        var checkoutRoot: String
        var worktreePath: String
    }

    struct Input: Sendable {
        var globalTerminal: AppConfig.Terminal
        var globalLaunchPreference: CreationLaunchPreference
        var workspaceConfiguration: WorkspaceConfiguration
        var members: [MemberInput]
        var availableLauncherModes: Set<AppConfig.LauncherMode>
        var enabledAgentIDs: Set<String>
    }

    static func resolve(_ input: Input, capturedAt: Date = .now) -> WorkspaceCheckoutConfigurationSnapshot {
        let sharedScripts = input.workspaceConfiguration.sharedStartupScripts ?? .defaults
        let shared = WorkspaceSharedConfigurationSnapshot(
            sessionOpenScript: resolveScript(global: input.globalTerminal.startupScript, mode: sharedScripts.sessionOpenMode, local: sharedScripts.sessionOpenScript),
            worktreeCreateScript: resolveScript(global: input.globalTerminal.worktreeCreateScript, mode: sharedScripts.worktreeCreateMode, local: sharedScripts.worktreeCreateScript),
            creationLaunchPreference: resolveLaunchPreference(input)
        )
        var warnings: [WorkspaceConfigurationWarning] = []
        let normalizedLaunch = validatedLaunchPreference(shared.creationLaunchPreference, input: input, warnings: &warnings)
        var members: [UUID: WorkspaceMemberConfigurationSnapshot] = [:]
        for member in input.members {
            let configuration = input.workspaceConfiguration.memberConfigurations[member.id] ?? .init()
            let projectSetup = resolveScript(global: input.globalTerminal.worktreeCreateScript, mode: member.project.startupScripts.worktreeCreateMode, local: member.project.startupScripts.worktreeCreateScript)
            let setup = resolveScript(global: projectSetup, mode: configuration.setupScript.mode.asProjectMode, local: configuration.setupScript.script)
            let ggMode: GGProjectMode = switch configuration.ggMode.mode {
            case .inherit, .append: member.project.ggMode
            case .override: configuration.ggMode.value ?? member.project.ggMode
            case .disabled: .off
            }
            let servers: [ProjectMCPServer] = switch configuration.mcpServers.mode {
            case .inherit: member.project.mcpServers
            case .append: member.project.mcpServers + configuration.mcpServers.servers
            case .override: configuration.mcpServers.servers
            case .disabled: []
            }
            members[member.id] = .init(
                setupScript: setup,
                ggMode: ggMode,
                mcpServers: servers.enumerated().map { index, server in
                    .init(id: "\(member.id.uuidString):\(index):\(server.id)", server: server, projectDirectory: member.checkoutRoot, worktreeDirectory: member.worktreePath, checkoutRoot: member.checkoutRoot)
                }
            )
        }
        return .init(capturedAt: capturedAt, shared: .init(sessionOpenScript: shared.sessionOpenScript, worktreeCreateScript: shared.worktreeCreateScript, creationLaunchPreference: normalizedLaunch), members: members, warnings: warnings)
    }

    private static func resolveLaunchPreference(_ input: Input) -> CreationLaunchPreference {
        switch input.workspaceConfiguration.creationLaunchPreference.mode {
        case .inherit, .append: input.globalLaunchPreference
        case .override: input.globalLaunchPreference.merging(input.workspaceConfiguration.creationLaunchPreference.preference)
        case .disabled: .init(openAfterCreate: false, launcherMode: .terminal)
        }
    }

    private static func validatedLaunchPreference(_ preference: CreationLaunchPreference, input: Input, warnings: inout [WorkspaceConfigurationWarning]) -> CreationLaunchPreference {
        var result = preference
        if let launcher = result.launcherMode, !input.availableLauncherModes.contains(launcher) {
            warnings.append(.init(message: "The \(launcher == .acp ? "ACP" : "terminal") launcher is unavailable; using Terminal."))
            result.launcherMode = .terminal
        }
        if let agentID = result.agentID, !input.enabledAgentIDs.contains(agentID) {
            warnings.append(.init(message: "The \(agentID) agent is unavailable; no agent will be launched."))
            result.agentID = nil
        }
        return result
    }

    private static func resolveScript(global: String, mode: ProjectStartupScriptMode, local: String) -> String {
        let global = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = local.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .useGlobal:
            return global
        case .appendToGlobal:
            return [global, local].filter { !$0.isEmpty }.joined(separator: "\n")
        case .overrideGlobal:
            return local
        case .disabled:
            return ""
        }
    }
}

private extension WorkspaceConfigurationMode {
    var asProjectMode: ProjectStartupScriptMode {
        switch self {
        case .inherit: .useGlobal
        case .append: .appendToGlobal
        case .override: .overrideGlobal
        case .disabled: .disabled
        }
    }
}
