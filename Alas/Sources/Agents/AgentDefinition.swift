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
    var isBuiltin: Bool
    var isEnabled: Bool
    var builtinLogoAssetName: String?

    /// The binary to invoke. Prefers a non-blank override; otherwise the
    /// catalog/custom `binary` (looked up via PATH at run time).
    /// Tildes are expanded so that `~/bin/foo` works when the value is
    /// passed to `/usr/bin/env` or shell-quoted into a command line —
    /// neither of those does its own tilde expansion the way an
    /// interactive shell does.
    var resolvedBinary: String {
        let raw: String
        if let trimmed = binaryOverride?.trimmingCharacters(in: .whitespaces),
           !trimmed.isEmpty {
            raw = trimmed
        } else {
            raw = binary
        }
        return (raw as NSString).expandingTildeInPath
    }
}
