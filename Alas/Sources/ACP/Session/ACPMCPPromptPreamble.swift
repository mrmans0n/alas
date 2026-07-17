import Foundation

/// How the preamble should describe Alas tool access for this agent.
///
/// Most adapters honor the ACP `session/new` `mcpServers` payload, so the
/// preamble describes the attached MCP tools (`.mcp`). Adapters that ignore
/// MCP config entirely (`ACPMCPInjectionSupport.external`) get the `alas`
/// CLI env injected into their process instead (see `AlasCLIEnvInjection`),
/// so the preamble must point the agent at CLI commands rather than tool
/// names.
enum ACPMCPPreambleMode: Equatable {
    case mcp
    case cli(serverAvailability: ACPMCPExternalStatus.AdapterServerAvailability)
}

/// Builds the one-time, wire-only context preamble injected into the first
/// prompt of a freshly created ACP session. Modern agent harnesses defer MCP
/// tools behind tool search, so the model never sees the attached tools
/// unless something in the prompt tells it they exist. See
/// docs/superpowers/specs/2026-07-17-mcp-discoverability-design.md.
enum ACPMCPPromptPreamble {
    /// Built-in server tool names, mirroring `tool_definitions` in
    /// AlasCLI/crates/alas/src/mcp.rs (its unit test asserts this order).
    /// Update both sides together.
    static let builtInToolNames: [String] = [
        "open", "notify",
        "session_list", "session_new", "session_send",
        "worktree_list", "worktree_switch", "worktree_new", "worktree_delete",
        "review", "review_comments", "review_reply", "review_resolve",
        "review_comment_add", "review_finish",
    ]

    /// The preamble text, or nil when no MCP server was attached.
    static func text(
        builtInInjected: Bool,
        isDelegated: Bool,
        userServerNames: [String],
        mode: ACPMCPPreambleMode = .mcp
    ) -> String? {
        guard builtInInjected || !userServerNames.isEmpty else { return nil }
        switch mode {
        case .mcp:
            return mcpText(
                builtInInjected: builtInInjected,
                isDelegated: isDelegated,
                userServerNames: userServerNames)
        case .cli(let serverAvailability):
            return cliText(
                builtInInjected: builtInInjected,
                isDelegated: isDelegated,
                userServerNames: userServerNames,
                serverAvailability: serverAvailability)
        }
    }

    private static func mcpText(
        builtInInjected: Bool,
        isDelegated: Bool,
        userServerNames: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("<alas-workspace-context>")
        lines.append(
            "This session runs inside Alas, the user's macOS workspace app. "
            + "MCP servers are attached to this session. Some agent harnesses "
            + "defer MCP tools behind tool search, so they may not appear in "
            + "your direct tool inventory — they ARE available; use your tool "
            + "discovery/search mechanism to load them.")
        if builtInInjected {
            let sessionTools = isDelegated
                ? "session_list/session_send"
                : "session_list/session_new/session_send (delegate direct child agent sessions)"
            var line = "The MCP server \"alas\" (built-in) drives the Alas UI: "
                + "open (reveal files to the user), notify (macOS notification), "
                + "worktree_list/worktree_switch/worktree_new/worktree_delete, "
                + "review, review_comments/review_reply/review_resolve/"
                + "review_comment_add/review_finish, \(sessionTools)."
            if isDelegated {
                line += " This session was delegated by a parent session: it "
                    + "cannot create descendants; return results or questions "
                    + "through session_send."
            }
            line += " Prefer these tools when the user asks to open/show files, "
                + "manage worktrees, run or respond to reviews, or be notified."
            lines.append(line)
        }
        if !userServerNames.isEmpty {
            lines.append("Additional MCP servers attached: "
                + userServerNames.joined(separator: ", ") + ".")
        }
        lines.append("</alas-workspace-context>")
        return lines.joined(separator: "\n")
    }

    private static func cliText(
        builtInInjected: Bool,
        isDelegated: Bool,
        userServerNames: [String],
        serverAvailability: ACPMCPExternalStatus.AdapterServerAvailability
    ) -> String {
        var lines: [String] = []
        lines.append("<alas-workspace-context>")
        var intro = "This session runs inside Alas, the user's macOS workspace app."
        if serverAvailability == .available, !userServerNames.isEmpty {
            intro += " MCP tools may be deferred behind tool search — they ARE "
                + "available; use your tool discovery/search mechanism to load them."
        }
        lines.append(intro)
        if builtInInjected {
            let sessionCLI = isDelegated
                ? "alas session send <session-id> <prompt>"
                : "alas session list | alas session new --prompt <text> | alas session send <session-id> <prompt>"
            var line = "Use the `alas` CLI via your shell tool to drive the Alas UI: "
                + "`alas open <path>` reveals a file to the user, "
                + "`alas notify <body>` posts a macOS notification, "
                + "`alas wt list|switch|new|delete` manages worktrees, "
                + "`alas review …` drives the review pane (comments/reply/resolve/finish), "
                + "and `\(sessionCLI)` manages delegated sessions."
            if isDelegated {
                line += " This session was delegated by a parent session: it cannot "
                    + "create descendants; return results or questions through "
                    + "`alas session send`."
            }
            line += " Prefer these commands when the user asks to open/show files, "
                + "manage worktrees, run or respond to reviews, or be notified."
            lines.append(line)
        }
        if !userServerNames.isEmpty {
            let names = userServerNames.joined(separator: ", ")
            switch serverAvailability {
            case .available:
                lines.append("Additional MCP servers are available through the "
                    + "`mcp()` tool (pi-mcp-adapter): \(names).")
            case .notInstalled:
                lines.append("This project configures MCP servers (\(names)) "
                    + "that cannot be reached until the pi-mcp-adapter extension "
                    + "is installed.")
            case .syncFailed:
                lines.append("This project configures MCP servers (\(names)), "
                    + "but Alas could not write .pi/mcp.json, so they may not "
                    + "be reachable.")
            case .userManaged:
                lines.append("This project configures MCP servers (\(names)), "
                    + "but an existing .pi/mcp.json governs pi's MCP config, so "
                    + "Alas did not add them — they may not be present.")
            case .noServers:
                break
            }
        }
        lines.append("</alas-workspace-context>")
        return lines.joined(separator: "\n")
    }
}
