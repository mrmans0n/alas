import Foundation
import Synchronization

enum ACPLaunchCatalog {
    /// Curated launch specs shipped with Alas.
    static let builtinSpecs: [ACPLaunchSpec] = [
        // Claude Code via Alas's maintained ACP adapter package. Require the
        // package itself so a PATH binary from a legacy install cannot skip
        // migration; the binary on PATH is `claude-agent-acp`.
        ACPLaunchSpec(
            agentID: ACPManagedAdapterDescriptor.claude.agentID,
            command: ACPManagedAdapterDescriptor.claude.binaryName,
            arguments: [],
            extraEnv: [:],
            setupCheck: .npxPackage(name: ACPManagedAdapterDescriptor.claude.packageName),
            supportsModelSelection: true,
            supportsModeSelection: true),

        ACPLaunchSpec(
            agentID: "gemini",
            command: "gemini",
            arguments: ["--acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "gemini"),
            supportsModelSelection: true,
            supportsModeSelection: false),

        // Antigravity has no ACP mode in `agy` itself; Google ships a separate
        // `agy_acp_server` binary (ACP registry id `antigravity-acp`, archive
        // from dl.google.com). The macOS archive ships it as
        // `agy_acp_server.par`; launch that name so an unrenamed install on
        // PATH works.
        ACPLaunchSpec(
            agentID: "antigravity",
            command: "agy_acp_server.par",
            arguments: [],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "agy_acp_server.par"),
            supportsModelSelection: true,
            supportsModeSelection: true),

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
        // Codex to ACP over stdio. Require Alas's maintained package because
        // legacy packages expose the same `codex-acp` binary.
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
        // Auth via `copilot login`.
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

        // OMP ships a native ACP server.
        ACPLaunchSpec(
            agentID: "omp",
            command: "omp",
            arguments: ["acp"],
            extraEnv: [:],
            setupCheck: .binaryOnPath(name: "omp"),
            supportsModelSelection: true,
            supportsModeSelection: true),
    ]

    /// Launch specs of agents installed from the ACP registry. Process-wide
    /// because every ACP surface consults the catalog statically; `AppState`
    /// republishes it whenever `config.agents.registry` may have changed.
    private static let registrySpecs = Mutex<[ACPLaunchSpec]>([])

    /// Every launchable ACP agent: the curated built-ins, then registry installs.
    static var specs: [ACPLaunchSpec] {
        builtinSpecs + registrySpecs.withLock { $0 }
    }

    static func spec(for agentID: String) -> ACPLaunchSpec? {
        if let builtin = builtinSpecs.first(where: { $0.agentID == agentID }) { return builtin }
        return registrySpecs.withLock { specs in specs.first { $0.agentID == agentID } }
    }

    static func publishRegistryAgents(_ agents: [ACPRegistryInstalledAgent]) {
        let specs = agents.map(\.launchSpec)
        registrySpecs.withLock { $0 = specs }
    }
}
