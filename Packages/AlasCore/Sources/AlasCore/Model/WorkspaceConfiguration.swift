import Foundation

/// The explicit inheritance operation used by Workspace configuration. A
/// Workspace never reinterprets a frozen checkout snapshot from live settings.
public enum WorkspaceConfigurationMode: String, Codable, Equatable, Sendable {
    case inherit
    case append
    case override
    case disabled
}

public struct WorkspaceScriptConfiguration: Codable, Equatable, Sendable {
    public var mode: WorkspaceConfigurationMode
    public var script: String

    public static let inherit = Self(mode: .inherit, script: "")
    public static let disabled = Self(mode: .disabled, script: "")

    public static func append(_ script: String) -> Self { .init(mode: .append, script: script) }
    public static func override(_ script: String) -> Self { .init(mode: .override, script: script) }

    public init(mode: WorkspaceConfigurationMode, script: String) {
        self.mode = mode
        self.script = script
    }
}

public struct CreationLaunchPreference: Codable, Equatable, Sendable {
    public var openAfterCreate: Bool?
    public var launcherMode: AppConfig.LauncherMode?
    public var agentID: String?
    public var useBypassPermissions: Bool?

    public static let inherit = Self()

    public init(
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

    public func merging(_ override: CreationLaunchPreference) -> CreationLaunchPreference {
        .init(
            openAfterCreate: override.openAfterCreate ?? openAfterCreate,
            launcherMode: override.launcherMode ?? launcherMode,
            agentID: override.agentID ?? agentID,
            useBypassPermissions: override.useBypassPermissions ?? useBypassPermissions
        )
    }
}

public struct WorkspaceLaunchPreferenceConfiguration: Codable, Equatable, Sendable {
    public var mode: WorkspaceConfigurationMode
    public var preference: CreationLaunchPreference

    public static let inherit = Self(mode: .inherit, preference: .inherit)

    public static func override(_ preference: CreationLaunchPreference) -> Self {
        .init(mode: .override, preference: preference)
    }

    public init(mode: WorkspaceConfigurationMode, preference: CreationLaunchPreference) {
        self.mode = mode
        self.preference = preference
    }
}

public struct WorkspaceMCPServerConfiguration: Codable, Equatable, Sendable {
    public var mode: WorkspaceConfigurationMode
    public var servers: [ProjectMCPServer]

    public static let inherit = Self(mode: .inherit, servers: [])
    public static let disabled = Self(mode: .disabled, servers: [])

    public static func append(_ servers: [ProjectMCPServer]) -> Self { .init(mode: .append, servers: servers) }
    public static func override(_ servers: [ProjectMCPServer]) -> Self { .init(mode: .override, servers: servers) }

    public init(mode: WorkspaceConfigurationMode, servers: [ProjectMCPServer]) {
        self.mode = mode
        self.servers = servers
    }
}

public struct WorkspaceMemberConfiguration: Codable, Equatable, Sendable {
    public var setupScript: WorkspaceScriptConfiguration
    public var ggMode: WorkspaceConfigurationModeValue<GGProjectMode>
    public var mcpServers: WorkspaceMCPServerConfiguration

    public init(
        setupScript: WorkspaceScriptConfiguration = .inherit,
        ggMode: WorkspaceConfigurationModeValue<GGProjectMode> = .inherit,
        mcpServers: WorkspaceMCPServerConfiguration = .inherit
    ) {
        self.setupScript = setupScript
        self.ggMode = ggMode
        self.mcpServers = mcpServers
    }
}

public struct WorkspaceConfigurationModeValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var mode: WorkspaceConfigurationMode
    public var value: Value?

    public static var inherit: Self { .init(mode: .inherit, value: nil) }
    public static var disabled: Self { .init(mode: .disabled, value: nil) }
    public static func override(_ value: Value) -> Self { .init(mode: .override, value: value) }

    public init(mode: WorkspaceConfigurationMode, value: Value? = nil) {
        self.mode = mode
        self.value = value
    }
}

public struct WorkspaceConfiguration: Codable, Equatable, Sendable {
    public var sharedStartupScripts: ProjectStartupScripts?
    public var creationLaunchPreference: WorkspaceLaunchPreferenceConfiguration
    public var memberConfigurations: [UUID: WorkspaceMemberConfiguration]

    public init(
        sharedStartupScripts: ProjectStartupScripts? = nil,
        creationLaunchPreference: WorkspaceLaunchPreferenceConfiguration = .inherit,
        memberConfigurations: [UUID: WorkspaceMemberConfiguration] = [:]
    ) {
        self.sharedStartupScripts = sharedStartupScripts
        self.creationLaunchPreference = creationLaunchPreference
        self.memberConfigurations = memberConfigurations
    }
}

public struct WorkspaceMCPServerDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var server: ProjectMCPServer
    public var projectDirectory: String
    public var worktreeDirectory: String
    public var checkoutRoot: String

    public init(id: String, server: ProjectMCPServer, projectDirectory: String, worktreeDirectory: String, checkoutRoot: String? = nil) {
        self.id = id
        self.server = server
        self.projectDirectory = projectDirectory
        self.worktreeDirectory = worktreeDirectory
        self.checkoutRoot = checkoutRoot ?? projectDirectory
    }
}

public struct WorkspaceConfigurationWarning: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

public struct WorkspaceSharedConfigurationSnapshot: Codable, Equatable, Sendable {
    public var sessionOpenScript: String
    public var worktreeCreateScript: String
    public var creationLaunchPreference: CreationLaunchPreference
    public var globalWorktreeCreateScript: String

    public init(
        sessionOpenScript: String,
        worktreeCreateScript: String,
        creationLaunchPreference: CreationLaunchPreference,
        globalWorktreeCreateScript: String = ""
    ) {
        self.sessionOpenScript = sessionOpenScript
        self.worktreeCreateScript = worktreeCreateScript
        self.creationLaunchPreference = creationLaunchPreference
        self.globalWorktreeCreateScript = globalWorktreeCreateScript
    }

    private enum CodingKeys: String, CodingKey {
        case sessionOpenScript, worktreeCreateScript, creationLaunchPreference, globalWorktreeCreateScript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionOpenScript = try container.decodeIfPresent(String.self, forKey: .sessionOpenScript) ?? ""
        worktreeCreateScript = try container.decodeIfPresent(String.self, forKey: .worktreeCreateScript) ?? ""
        creationLaunchPreference = try container.decodeIfPresent(CreationLaunchPreference.self, forKey: .creationLaunchPreference) ?? .inherit
        globalWorktreeCreateScript = try container.decodeIfPresent(String.self, forKey: .globalWorktreeCreateScript) ?? ""
    }
}

public struct WorkspaceMemberConfigurationSnapshot: Codable, Equatable, Sendable {
    public var setupScript: String
    public var setupScriptIncludesInheritedGlobalPrefix: Bool
    public var ggMode: GGProjectMode
    public var mcpServers: [WorkspaceMCPServerDescriptor]
    /// Frozen project and member policies retain hook eligibility on resume.
    /// `nil` means a snapshot predates repository hooks and must use `setupScript`.
    public var projectWorktreeCreateMode: ProjectStartupScriptMode?
    public var projectWorktreeCreateScript: String?
    public var memberSetupScript: WorkspaceScriptConfiguration?

    public init(
        setupScript: String,
        setupScriptIncludesInheritedGlobalPrefix: Bool = false,
        ggMode: GGProjectMode,
        mcpServers: [WorkspaceMCPServerDescriptor],
        projectWorktreeCreateMode: ProjectStartupScriptMode? = nil,
        projectWorktreeCreateScript: String? = nil,
        memberSetupScript: WorkspaceScriptConfiguration? = nil
    ) {
        self.setupScript = setupScript
        self.setupScriptIncludesInheritedGlobalPrefix = setupScriptIncludesInheritedGlobalPrefix
        self.ggMode = ggMode
        self.mcpServers = mcpServers
        self.projectWorktreeCreateMode = projectWorktreeCreateMode
        self.projectWorktreeCreateScript = projectWorktreeCreateScript
        self.memberSetupScript = memberSetupScript
    }

    private enum CodingKeys: String, CodingKey {
        case setupScript, setupScriptIncludesInheritedGlobalPrefix, ggMode, mcpServers
        case projectWorktreeCreateMode, projectWorktreeCreateScript, memberSetupScript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript) ?? ""
        setupScriptIncludesInheritedGlobalPrefix = try container.decodeIfPresent(Bool.self, forKey: .setupScriptIncludesInheritedGlobalPrefix) ?? false
        ggMode = try container.decodeIfPresent(GGProjectMode.self, forKey: .ggMode) ?? .off
        mcpServers = try container.decodeIfPresent([WorkspaceMCPServerDescriptor].self, forKey: .mcpServers) ?? []
        projectWorktreeCreateMode = try container.decodeIfPresent(ProjectStartupScriptMode.self, forKey: .projectWorktreeCreateMode)
        projectWorktreeCreateScript = try container.decodeIfPresent(String.self, forKey: .projectWorktreeCreateScript)
        memberSetupScript = try container.decodeIfPresent(WorkspaceScriptConfiguration.self, forKey: .memberSetupScript)
    }
}

public enum WorkspaceConfigurationResolver: Sendable {
    public struct MemberInput: Sendable {
        public var id: UUID
        public var project: ProjectConfig
        public var checkoutRoot: String
        public var worktreePath: String

        public init(id: UUID, project: ProjectConfig, checkoutRoot: String, worktreePath: String) {
            self.id = id
            self.project = project
            self.checkoutRoot = checkoutRoot
            self.worktreePath = worktreePath
        }
    }

    public struct Input: Sendable {
        public var globalTerminal: AppConfig.Terminal
        public var globalLaunchPreference: CreationLaunchPreference
        public var workspaceConfiguration: WorkspaceConfiguration
        public var members: [MemberInput]
        public var availableLauncherModes: Set<AppConfig.LauncherMode>
        public var enabledAgentIDs: Set<String>

        public init(globalTerminal: AppConfig.Terminal, globalLaunchPreference: CreationLaunchPreference, workspaceConfiguration: WorkspaceConfiguration, members: [MemberInput], availableLauncherModes: Set<AppConfig.LauncherMode>, enabledAgentIDs: Set<String>) {
            self.globalTerminal = globalTerminal
            self.globalLaunchPreference = globalLaunchPreference
            self.workspaceConfiguration = workspaceConfiguration
            self.members = members
            self.availableLauncherModes = availableLauncherModes
            self.enabledAgentIDs = enabledAgentIDs
        }
    }

    public static func resolve(_ input: Input, capturedAt: Date = .now) -> WorkspaceCheckoutConfigurationSnapshot {
        let sharedScripts = input.workspaceConfiguration.sharedStartupScripts ?? .defaults
        let shared = WorkspaceSharedConfigurationSnapshot(
            sessionOpenScript: resolveScript(global: input.globalTerminal.startupScript, mode: sharedScripts.sessionOpenMode, local: sharedScripts.sessionOpenScript),
            worktreeCreateScript: resolveScript(global: input.globalTerminal.worktreeCreateScript, mode: sharedScripts.worktreeCreateMode, local: sharedScripts.worktreeCreateScript),
            creationLaunchPreference: resolveLaunchPreference(input),
            globalWorktreeCreateScript: input.globalTerminal.worktreeCreateScript.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var warnings: [WorkspaceConfigurationWarning] = []
        let normalizedLaunch = validatedLaunchPreference(shared.creationLaunchPreference, input: input, warnings: &warnings)
        var members: [UUID: WorkspaceMemberConfigurationSnapshot] = [:]
        for member in input.members {
            let configuration = input.workspaceConfiguration.memberConfigurations[member.id] ?? .init()
            let projectSetup = resolveScript(global: input.globalTerminal.worktreeCreateScript, mode: member.project.startupScripts.worktreeCreateMode, local: member.project.startupScripts.worktreeCreateScript)
            let setup = resolveScript(global: projectSetup, mode: configuration.setupScript.mode.asProjectMode, local: configuration.setupScript.script)
            let setupIncludesInheritedGlobalPrefix = projectSetup.inheritsGlobalSetupPrefix(input.globalTerminal.worktreeCreateScript)
                && (configuration.setupScript.mode == .inherit || configuration.setupScript.mode == .append)
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
                setupScriptIncludesInheritedGlobalPrefix: setupIncludesInheritedGlobalPrefix,
                ggMode: ggMode,
                mcpServers: servers.enumerated().map { index, server in
                    .init(id: "\(member.id.uuidString):\(index):\(server.id)", server: server, projectDirectory: member.checkoutRoot, worktreeDirectory: member.worktreePath, checkoutRoot: member.checkoutRoot)
                },
                projectWorktreeCreateMode: member.project.startupScripts.worktreeCreateMode,
                projectWorktreeCreateScript: member.project.startupScripts.worktreeCreateScript,
                memberSetupScript: configuration.setupScript
            )
        }
        return .init(
            capturedAt: capturedAt,
            shared: .init(
                sessionOpenScript: shared.sessionOpenScript,
                worktreeCreateScript: shared.worktreeCreateScript,
                creationLaunchPreference: normalizedLaunch,
                globalWorktreeCreateScript: shared.globalWorktreeCreateScript
            ),
            members: members,
            warnings: warnings
        )
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

    public static func memberSetupScript(
        sharedWorktreeCreateScript: String,
        globalWorktreeCreateScript: String,
        member: WorkspaceMemberConfigurationSnapshot,
        repoScript: String?
    ) -> String {
        guard let projectMode = member.projectWorktreeCreateMode,
              let projectScript = member.projectWorktreeCreateScript,
              let memberConfiguration = member.memberSetupScript
        else {
            let legacyMemberScript = member.setupScript
            let legacyMemberOnlyScript = sharedWorktreeCreateScript
                .inheritsGlobalSetupPrefix(globalWorktreeCreateScript)
                && member.setupScriptIncludesInheritedGlobalPrefix
                ? legacyMemberScript.removingInheritedGlobalSetupPrefix(globalWorktreeCreateScript)
                : legacyMemberScript.trimmingCharacters(in: .whitespacesAndNewlines)
            return [sharedWorktreeCreateScript, legacyMemberOnlyScript]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        let inheritedProjectScript = [globalWorktreeCreateScript, repoScript ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let projectSetup = resolveScript(
            global: inheritedProjectScript,
            mode: projectMode,
            local: projectScript
        )
        let memberSetup = resolveScript(
            global: projectSetup,
            mode: memberConfiguration.mode.asProjectMode,
            local: memberConfiguration.script
        )
        let memberOnlyScript = sharedWorktreeCreateScript
            .inheritsGlobalSetupPrefix(globalWorktreeCreateScript)
            ? memberSetup.removingInheritedGlobalSetupPrefix(globalWorktreeCreateScript)
            : memberSetup.trimmingCharacters(in: .whitespacesAndNewlines)
        return [sharedWorktreeCreateScript, memberOnlyScript]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
