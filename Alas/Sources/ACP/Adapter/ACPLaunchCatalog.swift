import Foundation

enum ACPLaunchCatalog {
    static let specs: [ACPLaunchSpec] = [
        // Claude Code via the ACP adapter. The package was renamed from
        // `@zed-industries/claude-code-acp` (stale, pins claude-agent-sdk
        // 0.2.44 — only knows up to opus-4-6 / sonnet-4-5) to
        // `@agentclientprotocol/claude-agent-acp` (active, ships newer
        // claude-agent-sdk and so advertises opus-4-7 / sonnet-4-6 /
        // haiku-4-6). The binary on PATH is `claude-agent-acp`.
        ACPLaunchSpec(
            agentID: ACPManagedAdapterDescriptor.claude.agentID,
            command: ACPManagedAdapterDescriptor.claude.binaryName,
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPathOrNpmPackage(
                binary: ACPManagedAdapterDescriptor.claude.binaryName,
                npmPackage: ACPManagedAdapterDescriptor.claude.packageName),
            supportsModelSelection: true,
            supportsModeSelection: true),

        ACPLaunchSpec(
            agentID: "gemini",
            command: "gemini",
            arguments: ["--experimental-acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "gemini"),
            supportsModelSelection: true,
            supportsModeSelection: false),

        ACPLaunchSpec(
            agentID: "opencode",
            command: "opencode",
            // The exact subcommand name may differ — implementation step
            // verifies against `opencode --help` before merging.
            arguments: ["acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "opencode"),
            supportsModelSelection: true,
            supportsModeSelection: true),

        // Cursor CLI ships `agent` binary (typically at ~/.local/bin/agent).
        // `agent acp` starts the ACP JSON-RPC 2.0 server over stdio.
        // Supports 3 modes (agent, plan, ask) and model selection.
        // Auth via `agent login` or cursor_login ACP auth method.
        ACPLaunchSpec(
            agentID: "cursor-agent",
            command: "agent",
            arguments: ["acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "agent"),
            supportsModelSelection: true,
            supportsModeSelection: true),

        // Codex CLI (OpenAI) has no native ACP support; an adapter bridges
        // Codex to ACP over stdio. The package moved orgs — same story as
        // claude above: `@zed-industries/codex-acp` is stale and does NOT
        // emit `usage_update`, while `@agentclientprotocol/codex-acp` (active)
        // does, so the context-window indicator only lights up on the latter.
        // The binary on PATH is still `codex-acp` in both packages — which is
        // exactly why the setup check is `.npxPackage` (gate on the specific
        // global package) rather than `.binaryOnPathOrNpmPackage`: a
        // binary-on-PATH check would pass on a stale `@zed-industries/codex-acp`
        // install and skip the migration, leaving `usage_update` unavailable.
        // (The claude rename above didn't need this — its binary name changed.)
        // Requires OPENAI_API_KEY or CODEX_API_KEY in the environment.
        ACPLaunchSpec(
            agentID: ACPManagedAdapterDescriptor.codex.agentID,
            command: ACPManagedAdapterDescriptor.codex.binaryName,
            arguments: [],
            extraEnv: [:],
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.codex.packageName),
            supportsModelSelection: false,
            supportsModeSelection: false),

        // GitHub Copilot CLI. Native ACP support (public preview Jan 2026).
        // `copilot --acp` starts the ACP server over stdio (default).
        // Also supports TCP via `--port N`.
        // Auth via `copilot auth login`.
        ACPLaunchSpec(
            agentID: "copilot",
            command: "copilot",
            arguments: ["--acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "copilot"),
            supportsModelSelection: true,
            supportsModeSelection: true),

        // Pi coding agent. The `pi-acp` npm package bridges Pi's RPC mode
        // to ACP over stdio. Internally spawns `pi --mode rpc`.
        // First-time auth via `pi-acp --terminal-login`.
        ACPLaunchSpec(
            agentID: ACPManagedAdapterDescriptor.pi.agentID,
            command: ACPManagedAdapterDescriptor.pi.binaryName,
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPathOrNpmPackage(
                binary: ACPManagedAdapterDescriptor.pi.binaryName,
                npmPackage: ACPManagedAdapterDescriptor.pi.packageName),
            supportsModelSelection: false,
            supportsModeSelection: false,
            mcpInjection: .external(hint: "Pi ignores ACP MCP config. Alas tools work via the alas CLI; other MCP servers need the pi-mcp-adapter extension.")),
    ]

    static func spec(for agentID: String) -> ACPLaunchSpec? {
        specs.first { $0.agentID == agentID }
    }
}
