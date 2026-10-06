import Foundation

/// A registry agent the user installed, persisted in `AppConfig.agents.registry`.
/// Registry agents are ACP-only: they join the launch catalog under
/// `"registry-<registryID>"` and never appear on terminal surfaces, because
/// their command is an ACP stdio server rather than an interactive CLI.
struct ACPRegistryInstalledAgent: Codable, Equatable, Identifiable, Sendable {
    static let agentIDPrefix = "registry-"

    let registryID: String
    var displayName: String
    var version: String
    /// Absolute executable for binary/npm installs; `uvx` for uv packages.
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var isEnabled: Bool

    /// The Alas agent id. Prefixed so registry ids never collide with
    /// built-in ids (`gemini`, `opencode`, …).
    var id: String { Self.agentIDPrefix + registryID }

    var agentDefinition: AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: displayName,
            binary: command,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: isEnabled,
            builtinLogoAssetName: nil,
            acpRegistryID: registryID
        )
    }

    var launchSpec: ACPLaunchSpec {
        ACPLaunchSpec(
            agentID: id,
            command: command,
            arguments: arguments,
            extraEnv: environment,
            setupCheck: .binaryOnPath(name: command),
            supportsModelSelection: true,
            supportsModeSelection: true
        )
    }
}

extension AppConfig.Agents {
    /// Every non-built-in agent: user-defined customs, then installed
    /// registry agents. This is what the configured catalog appends after
    /// the built-ins.
    var userAgents: [AgentDefinition] {
        custom + registry.map(\.agentDefinition)
    }
}
