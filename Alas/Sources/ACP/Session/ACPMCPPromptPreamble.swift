import Foundation

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
        userServerNames: [String]
    ) -> String? {
        guard builtInInjected || !userServerNames.isEmpty else { return nil }
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
}
