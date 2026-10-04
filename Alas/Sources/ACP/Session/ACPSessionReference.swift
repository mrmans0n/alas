import Foundation

/// Another session the user attached to a prompt, by `@`-mentioning it or
/// dragging it from the sidebar into the composer.
///
/// It rides the composer's mention pipeline as an `alas-session://<id>`
/// resource link, so chips, drafts, the queue, and the recorded user message
/// all treat it like a file mention. Just before sending, the link is
/// replaced on the wire with a text block: the session's id, for
/// `session_read`, and a budgeted tail of its transcript, for agents
/// without the Alas MCP server. The recorded user message keeps the link,
/// and it is what lets the agent `session_read` that session afterwards.
enum ACPSessionReference {
    static let scheme = "alas-session"

    /// Inline transcript budget: the latest entries that fit.
    static let contextEntryLimit = 40
    static let contextMaxChars = 6_000

    struct Target: Equatable, Sendable {
        let sessionId: String
        let title: String
        let agentName: String
        let worktreeName: String
    }

    static func uri(sessionId: String) -> String {
        "\(scheme)://\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sessionId)"
    }

    static func sessionId(fromURI uri: String) -> String? {
        let prefix = "\(scheme)://"
        guard uri.hasPrefix(prefix) else { return nil }
        let encoded = uri.dropFirst(prefix.count)
        guard let id = String(encoded).removingPercentEncoding, !id.isEmpty else { return nil }
        return id
    }

    /// Sessions the user attached in `messages`. Delegated prompts are
    /// skipped: only the user can grant another session's transcript.
    @MainActor
    static func attachedSessionIds(in messages: [ACPMessage]) -> Set<String> {
        var ids = Set<String>()
        for message in messages {
            guard case .user(_, _, _, let attachments, let delegatedSource) = message,
                  delegatedSource == nil else { continue }
            for attachment in attachments {
                if let id = sessionId(fromURI: attachment.uri) { ids.insert(id) }
            }
        }
        return ids
    }

    /// Ids of the sessions referenced by `blocks`, in order, without repeats.
    static func sessionIds(in blocks: [ACPContentBlock]) -> [String] {
        var ids: [String] = []
        for block in blocks {
            guard case .resourceLink(let uri, _) = block, let id = sessionId(fromURI: uri),
                  !ids.contains(id) else { continue }
            ids.append(id)
        }
        return ids
    }

    /// `blocks` with each session link replaced by its context from
    /// `contexts`, or by a short note naming the session when it could not
    /// be resolved. Agents never see the `alas-session` scheme: some treat
    /// every resource link as a path to read.
    static func replacingReferences(in blocks: [ACPContentBlock], contexts: [String: String]) -> [ACPContentBlock] {
        blocks.map { block in
            guard case .resourceLink(let uri, let name) = block, let id = sessionId(fromURI: uri) else {
                return block
            }
            if let context = contexts[id] { return .text(context) }
            let title = name.map { " \"\($0)\"" } ?? ""
            return .text("""
            <alas-session-reference session_id="\(id)">
            The user attached the Alas session\(title) as context, but its transcript is not available.
            </alas-session-reference>
            """)
        }
    }

    /// The text block sent in place of a session link: who the session is,
    /// how to read it in full, and its latest entries within the budget.
    static func context(for target: Target, entries: [ACPSessionTranscriptReader.Entry]) -> String {
        let page = ACPSessionTranscriptReader.page(
            entries, offset: nil, limit: contextEntryLimit, maxChars: contextMaxChars
        )
        var lines = [
            "<alas-session-reference session_id=\"\(target.sessionId)\">",
            "The user attached the Alas session \"\(target.title)\" (agent: \(target.agentName), "
                + "worktree: \(target.worktreeName)) as context. To read more of it, call the "
                + "session_read tool of the \"alas\" MCP server with session_id \"\(target.sessionId)\".",
        ]
        if page.entries.isEmpty {
            lines.append("The session has no messages yet.")
        } else {
            lines.append(page.start > 0
                ? "Its latest \(page.entries.count) of \(page.total) entries (earlier ones omitted):"
                : "Its transcript:")
            for entry in page.entries {
                lines.append("")
                lines.append("[\(entry.role)]\(entry.truncated == true ? " …" : "") \(entry.text)")
            }
        }
        lines.append("</alas-session-reference>")
        return lines.joined(separator: "\n")
    }
}
