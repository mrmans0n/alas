import Foundation
import AlasFoundation

/// One CLI coding agent Alas knows about. Built-ins are seeded from
/// `AgentBuiltins.catalog`; customs are user-defined entries persisted in
/// `AppConfig.agents.custom`.
///
/// The fields under "static knowledge" (binary, promptModeArgs,
/// bypassPermissionsFlag) come from the catalog for built-ins and are not
/// re-persisted; only per-built-in state (isEnabled, binaryOverride) lives
/// on disk. Custom agents persist the whole record.
public struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var binary: String
    public var binaryOverride: String?
    public var promptModeArgs: [String]
    public var bypassPermissionsFlag: String?
    public var extraTerminalArgs: [String]?
    public var isBuiltin: Bool
    public var isEnabled: Bool
    public var builtinLogoAssetName: String?
    /// Set for agents installed from the ACP registry. Those are ACP-only:
    /// their command is a stdio ACP server, not an interactive CLI.
    public var acpRegistryID: String?

    /// Whether the agent can run in a terminal tab or in prompt mode.
    public var supportsTerminal: Bool { acpRegistryID == nil }

    /// Registry binary and npm installs live under this Mac's Application
    /// Support, so they cannot launch on an SSH host. A bare registry command
    /// (`uvx`) still resolves on the remote PATH.
    public var canRunOnRemoteHost: Bool { acpRegistryID == nil || !binary.contains("/") }

    /// The binary configured by the user. Prefers a non-blank override;
    /// otherwise returns the catalog/custom `binary` unchanged.
    public var configuredBinary: String {
        if let value = binaryOverride?.trimmingCharacters(in: .whitespaces),
           !value.isEmpty {
            return value
        }
        return binary
    }

    /// The local binary to invoke. Tildes are expanded so that `~/bin/foo` works when the value is
    /// passed to `/usr/bin/env` or shell-quoted into a command line —
    /// neither of those does its own tilde expansion the way an
    /// interactive shell does.
    public var resolvedBinary: String {
        (configuredBinary as NSString).expandingTildeInPath
    }

    public init(id: String, displayName: String, binary: String, binaryOverride: String? = nil, promptModeArgs: [String], bypassPermissionsFlag: String? = nil, extraTerminalArgs: [String]? = nil, isBuiltin: Bool, isEnabled: Bool, builtinLogoAssetName: String? = nil, acpRegistryID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.binaryOverride = binaryOverride
        self.promptModeArgs = promptModeArgs
        self.bypassPermissionsFlag = bypassPermissionsFlag
        self.extraTerminalArgs = extraTerminalArgs
        self.isBuiltin = isBuiltin
        self.isEnabled = isEnabled
        self.builtinLogoAssetName = builtinLogoAssetName
        self.acpRegistryID = acpRegistryID
    }
}
