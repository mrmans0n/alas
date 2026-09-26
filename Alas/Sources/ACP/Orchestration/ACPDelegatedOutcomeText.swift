import Foundation

/// Copy for the messages Alas injects into a parent session about one of its
/// delegated children. Conventions: identify the sender, state the fact, do
/// not ask for an acknowledgement.
enum ACPDelegatedOutcomeText {
    struct Context: Equatable, Sendable {
        let childSessionId: String
        let agentId: String
        let worktreeName: String?
    }

    static func unreported(_ context: Context, lastAgentText: String?) -> String {
        var lines = [
            "[alas system] Delegated session \(label(context)) finished its turn without sending a result."
        ]
        if let lastAgentText, !lastAgentText.isEmpty {
            lines.append("Last message from the child:")
            lines.append(lastAgentText)
        }
        lines.append("Use session_send to follow up with it, or session_list to inspect its state.")
        return lines.joined(separator: "\n")
    }

    static func failure(_ context: Context, message: String) -> String {
        "[alas system] Delegated session \(label(context)) failed: \(message)."
    }

    static func notice(_ context: Context) -> String {
        "Delegated session \(label(context)) finished its turn."
    }

    /// Trims whitespace and keeps at most `limit` characters from the end,
    /// prefixing an ellipsis when anything was dropped.
    static func tail(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…" + String(trimmed.suffix(limit))
    }

    private static func label(_ context: Context) -> String {
        if let worktreeName = context.worktreeName, !worktreeName.isEmpty {
            return "\(context.childSessionId) (\(context.agentId), worktree \(worktreeName))"
        }
        return "\(context.childSessionId) (\(context.agentId))"
    }
}
