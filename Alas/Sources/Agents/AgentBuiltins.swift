/// Hard-coded catalog of agents Alas ships knowledge for. The order here is
/// the order they appear in the Agents pane. The fields live in code (not
/// persistence) so app updates can fix CLI flag changes for every user
/// without a config migration.
enum AgentBuiltins {
    static let catalog: [AgentDefinition] = [
        // Verified against `claude --help` v2.1.133 (2026-05-16). -p is the
        // documented non-interactive prompt flag; --dangerously-skip-permissions
        // is the documented "skip all permission prompts" flag.
        AgentDefinition(
            id: "claude",
            displayName: "Claude Code",
            binary: "claude",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: "--dangerously-skip-permissions",
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-claude"
        ),
        // Verified against `codex --help` and `codex exec --help` v0.130.0
        // (2026-05-16). The `exec` subcommand is the non-interactive entry
        // point; --dangerously-bypass-approvals-and-sandbox disables all
        // sandboxing and approval prompts. (The previously-assumed
        // `--full-auto` flag does not exist.)
        AgentDefinition(
            id: "codex",
            displayName: "Codex",
            binary: "codex",
            binaryOverride: nil,
            promptModeArgs: ["exec"],
            bypassPermissionsFlag: "--dangerously-bypass-approvals-and-sandbox",
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-codex"
        ),
        // Verified against cursor.com/docs/cli (2026-05-16). The installed
        // binary is `cursor-agent`. -p / --print enables headless mode;
        // --force auto-approves file changes without confirmation.
        AgentDefinition(
            id: "cursor-agent",
            displayName: "Cursor CLI",
            binary: "cursor-agent",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: "--force",
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-cursor"
        ),
        // Verified against `pi --help` v0.74.0 (2026-05-16). -p is the
        // non-interactive prompt flag. No bypass-permissions equivalent
        // exists in this CLI.
        AgentDefinition(
            id: "pi",
            displayName: "Pi",
            binary: "pi",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: nil,
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-pi"
        ),
        // Verified against `opencode run --help` v1.15.1 (2026-05-16). The
        // `run` subcommand is the non-interactive entry point;
        // --dangerously-skip-permissions auto-approves permissions.
        AgentDefinition(
            id: "opencode",
            displayName: "opencode",
            binary: "opencode",
            binaryOverride: nil,
            promptModeArgs: ["run"],
            bypassPermissionsFlag: "--dangerously-skip-permissions",
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-opencode"
        ),
        // Verified against google-gemini/gemini-cli source
        // (packages/cli/src/config/config.ts, main branch, 2026-05-16).
        // -p / --prompt is the non-interactive flag; --yolo auto-approves
        // all tool calls.
        AgentDefinition(
            id: "gemini",
            displayName: "Gemini CLI",
            binary: "gemini",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: "--yolo",
            isBuiltin: true,
            isEnabled: true,
            builtinLogoAssetName: "agent-gemini"
        ),
    ]

    /// Look up a catalog entry by id; nil for unknown ids.
    static func entry(id: String) -> AgentDefinition? {
        catalog.first(where: { $0.id == id })
    }
}
