import Foundation

/// One CLI coding agent Alas knows about. Built-ins are seeded from
/// `AgentBuiltins.catalog`; customs are user-defined entries persisted in
/// `AppConfig.agents.custom`.
///
/// The fields under "static knowledge" (binary, promptModeArgs,
/// bypassPermissionsFlag) come from the catalog for built-ins and are not
/// re-persisted; only per-built-in state (isEnabled, binaryOverride) lives
/// on disk. Custom agents persist the whole record.
struct AgentDefinition: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var binary: String
    var binaryOverride: String?
    var promptModeArgs: [String]
    var bypassPermissionsFlag: String?
    var extraTerminalArgs: [String]?
    var isBuiltin: Bool
    var isEnabled: Bool
    var builtinLogoAssetName: String?

    /// The binary configured by the user. Prefers a non-blank override;
    /// otherwise returns the catalog/custom `binary` unchanged.
    var configuredBinary: String {
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
    var resolvedBinary: String {
        (configuredBinary as NSString).expandingTildeInPath
    }
}
