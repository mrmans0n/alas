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

    /// Agent-authored text (a tool title, an elicitation message, a plan
    /// name) reaching a parent's prompt verbatim is a hazard this function
    /// closes: collapse embedded newlines so a multi-line summary can't
    /// visually inject extra lines into a message whose whole point is a
    /// safety boundary, and cap the length the same way Phase 1 caps a
    /// child's full agent text (`ACPTurnCompletion.lastAgentTextLimit`,
    /// used via `ACPSessionRunner.swift`'s `emitTurnCompleted`) — just at a
    /// one-line-summary-appropriate size instead of a whole message's.
    private static func sanitizedBlockerSummary(_ summary: String?, fallback: String) -> String {
        guard let summary else { return fallback }
        let collapsed = summary.replacingOccurrences(of: "\n", with: " ")
        let capped = tail(collapsed, limit: 200)
        return capped.isEmpty ? fallback : capped
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
                + "(\(kindLabel)): \(sanitizedBlockerSummary(context.blockerSummary, fallback: kindLabel))."
        }
        return [
            "[alas system] Delegated session \(label(context)) has been waiting \(waitedSeconds)s "
                + "for a human decision (\(kindLabel)): \(sanitizedBlockerSummary(context.blockerSummary, fallback: kindLabel)).",
            "You cannot approve this for the user — a permission, question, or plan prompt is "
                + "answered only in that session.",
            "Use notify to tell the user, session_send to give the child guidance it will act on "
                + "once unblocked, or continue with other work.",
        ].joined(separator: "\n")
    }

    /// A child's `session_send` to its parent: one header line naming the
    /// sender, then the child's text unchanged. Without it the parent sees
    /// the report as if the user had typed it.
    static func childReport(_ context: Context, message: String) -> String {
        "[alas system] Report from delegated session \(label(context)) via session_send:\n\(message)"
    }

    static func notice(_ context: Context) -> String {
        "Delegated session \(label(context)) finished its turn."
    }

    /// A child turn the user cancelled. A notice only: the human intervened,
    /// so it never wakes the parent.
    static func cancelled(_ context: Context) -> String {
        "Delegated session \(label(context)) had its turn cancelled by the user."
    }

    static func limited(_ context: Context) -> String {
        "Delegated session \(label(context)) stopped at a provider usage limit. Alas resumes it when the limit resets."
    }

    /// The kinds of prompt Alas itself sends a parent about one of its
    /// children, as opposed to a report the child sent. Raw values are
    /// persisted with the transcript row.
    enum NoticeKind: String, CaseIterable, Sendable {
        case needsDecision = "needs_decision"
        case noResult = "no_result"
        case failed
    }

    /// Recognizes a delivered prompt as one of Alas's own notices about a
    /// child, from its first line. That line is always Alas's: a child's
    /// `session_send` to its parent is wrapped in `childReport` at enqueue,
    /// so a report's body can never be mistaken for a notice. Matching the
    /// text, not the inbox id, also classifies rows an older build queued.
    static func noticeKind(ofDelivered prompt: String) -> NoticeKind? {
        let firstLine = prompt.prefix { $0 != "\n" }
        guard firstLine.hasPrefix(systemPrefix + "Delegated session ") else { return nil }
        // The verb follows the session label, and agent text (a failure
        // message, a blocker summary) only follows the verb, so the earliest
        // match is the real one.
        let verbs: [(String, NoticeKind)] = [
            (") finished its turn without sending a result.", .noResult),
            (") has been waiting ", .needsDecision),
            (") failed: ", .failed),
        ]
        return verbs
            .compactMap { verb, kind in firstLine.range(of: verb).map { ($0.lowerBound, kind) } }
            .min { $0.0 < $1.0 }?
            .1
    }

    private static let systemPrefix = "[alas system] "

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
