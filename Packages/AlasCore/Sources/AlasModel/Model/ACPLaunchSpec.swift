import Foundation

/// How an adapter receives MCP servers. Most honor the `mcpServers`
/// payload in ACP `session/new`; `.external` adapters ignore it and need
/// agent-side setup (config files, plugins) instead.
public enum ACPMCPInjectionSupport: Equatable, Sendable {
    case sessionNew
    case external(hint: String)
}

public struct ACPLaunchSpec: Equatable, Sendable {
    public let agentID: String
    public let command: String
    public let arguments: [String]
    public let extraEnv: [String: String]
    public let setupCheck: ACPSetupCheck
    public let supportsModelSelection: Bool
    public let supportsModeSelection: Bool
    public let mcpInjection: ACPMCPInjectionSupport
    public let remoteNodeBinDirectory: String?

    public init(
        agentID: String,
        command: String,
        arguments: [String],
        extraEnv: [String: String],
        setupCheck: ACPSetupCheck,
        supportsModelSelection: Bool,
        supportsModeSelection: Bool,
        mcpInjection: ACPMCPInjectionSupport = .sessionNew,
        remoteNodeBinDirectory: String? = nil
    ) {
        self.agentID = agentID
        self.command = command
        self.arguments = arguments
        self.extraEnv = extraEnv
        self.setupCheck = setupCheck
        self.supportsModelSelection = supportsModelSelection
        self.supportsModeSelection = supportsModeSelection
        self.mcpInjection = mcpInjection
        self.remoteNodeBinDirectory = remoteNodeBinDirectory
    }

    /// The npm package that installs/updates this adapter, when the setup
    /// check exposes one. Binary-only adapters (gemini, opencode,
    /// cursor-agent, copilot) return nil — Alas does not own their install.
    public var npmPackageName: String? {
        switch setupCheck {
        case .binaryOnPath: return nil
        case .npxPackage(let name): return name
        case .binaryOnPathOrNpmPackage(_, let npmPackage): return npmPackage
        }
    }

    /// A copy of this spec with `command` replaced and all other fields
    /// unchanged. Used to launch a resolved absolute path through the
    /// launcher's existing absolute-path branch.
    public func overridingCommand(
        _ command: String,
        remoteNodeBinDirectory: String? = nil
    ) -> ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: agentID,
            command: command,
            arguments: arguments,
            extraEnv: extraEnv,
            setupCheck: setupCheck,
            supportsModelSelection: supportsModelSelection,
            supportsModeSelection: supportsModeSelection,
            mcpInjection: mcpInjection,
            remoteNodeBinDirectory: remoteNodeBinDirectory)
    }

    /// A copy of this spec whose setup check verifies the same executable that
    /// launch will run. Used for explicit user overrides; catalog defaults keep
    /// their adapter-specific setup rules.
    public func overridingCommandAndSetupCheck(_ command: String) -> ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: agentID,
            command: command,
            arguments: arguments,
            extraEnv: extraEnv,
            setupCheck: .binaryOnPath(name: command),
            supportsModelSelection: supportsModelSelection,
            supportsModeSelection: supportsModeSelection,
            mcpInjection: mcpInjection,
            remoteNodeBinDirectory: nil)
    }

    /// A copy of this spec with `env` overlaid onto `extraEnv` (new keys win).
    public func mergingExtraEnv(_ env: [String: String]) -> ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: agentID, command: command, arguments: arguments,
            extraEnv: extraEnv.merging(env) { _, new in new },
            setupCheck: setupCheck,
            supportsModelSelection: supportsModelSelection,
            supportsModeSelection: supportsModeSelection,
            mcpInjection: mcpInjection,
            remoteNodeBinDirectory: remoteNodeBinDirectory)
    }

    /// A copy of this spec with launch arguments added after the
    /// adapter-specific argument tail (`omp acp --config …`).
    public func appendingArguments(_ arguments: [String]) -> ACPLaunchSpec {
        replacingArguments(self.arguments + arguments)
    }

    /// A copy of this spec with launch arguments inserted before the
    /// adapter-specific argument tail. Used for frozen Workspace launch
    /// preferences that must affect adapter process startup.
    public func prependingArguments(_ arguments: [String]) -> ACPLaunchSpec {
        replacingArguments(arguments + self.arguments)
    }

    public func replacingArguments(_ arguments: [String]) -> ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: agentID, command: command, arguments: arguments,
            extraEnv: extraEnv,
            setupCheck: setupCheck,
            supportsModelSelection: supportsModelSelection,
            supportsModeSelection: supportsModeSelection,
            mcpInjection: mcpInjection,
            remoteNodeBinDirectory: remoteNodeBinDirectory)
    }
}
