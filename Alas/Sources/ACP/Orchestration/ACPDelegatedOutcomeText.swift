import Foundation

/// Copy for the messages Alas injects into a parent session about one of its
/// delegated children. Conventions: identify the sender, state the fact, do
/// not ask for an acknowledgement.
enum ACPDelegatedOutcomeText {
    struct Context: Equatable, Sendable {
        let childSessionId: String
        let agentId: String
        let worktreeName: String?
        var blockerSummary: String? = nil
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

    /// Copy for a child blocked on a human decision. The strict boundary is
    /// in the words on purpose: a parent genuinely cannot answer a permission,
    /// question, or plan prompt — `flushQueueIfIdle` will not even dispatch a
    /// queued message while the child is blocked — so the text must not imply
    /// it can.
    static func blocker(
        _ context: Context,
        kindLabel: String,
        waitedSeconds: Int,
        escalated: Bool
    ) -> String {
        guard escalated else {
            return "Delegated session \(label(context)) is waiting for a human decision "
                + "(\(kindLabel)): \(context.blockerSummary ?? kindLabel)."
        }
        return [
            "[alas system] Delegated session \(label(context)) has been waiting \(waitedSeconds)s "
                + "for a human decision (\(kindLabel)): \(context.blockerSummary ?? kindLabel).",
            "You cannot approve this for the user — a permission, question, or plan prompt is "
                + "answered only in that session.",
            "Use notify to tell the user, session_send to give the child guidance it will act on "
                + "once unblocked, or continue with other work.",
        ].joined(separator: "\n")
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
