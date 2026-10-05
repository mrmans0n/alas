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

    /// Inline context budget: the latest entries that fit, with the
    /// wrapper and labels counted against `contextMaxChars`.
    static let contextEntryLimit = 40
    static let contextMaxChars = 6_000
    /// Caps on the session's title, agent, and worktree names, so the
    /// wrapper always leaves room for entries.
    static let contextTitleLimit = 120
    static let contextNameLimit = 80

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

    /// Attachments of a user message chunk the agent sent, live or replayed.
    /// Alas never sends a session link on the wire (see
    /// `replacingReferences`), so one arriving from the agent is made up and
    /// must not be recorded: a recorded one grants `session_read`.
    static func agentSentAttachments(_ attachments: [ACPMessage.Attachment]) -> [ACPMessage.Attachment] {
        attachments.filter { sessionId(fromURI: $0.uri) == nil }
    }

    /// Sessions the user attached in `messages`. Delegated prompts are
    /// skipped: only the user can grant another session's transcript, and
    /// user chunks from the agent never carry a session link (see
    /// `agentSentAttachments`).
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
    /// A link to `selfSessionId`, the sending session (a chip pasted into
    /// its own composer), is dropped: it has nothing to add.
    static func replacingReferences(
        in blocks: [ACPContentBlock], contexts: [String: String], selfSessionId: String? = nil
    ) -> [ACPContentBlock] {
        blocks.compactMap { block in
            guard case .resourceLink(let uri, let name) = block, let id = sessionId(fromURI: uri) else {
                return block
            }
            if id == selfSessionId { return nil }
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
    /// `entries` may be only the latest part of the transcript, so the text
    /// never claims to show all of it.
    static func context(for target: Target, entries: [ACPSessionTranscriptReader.Entry]) -> String {
        func capped(_ value: String, _ limit: Int) -> String {
            value.count > limit ? value.prefix(limit) + "…" : value
        }
        let title = capped(target.title, contextTitleLimit)
        let agentName = capped(target.agentName, contextNameLimit)
        let worktreeName = capped(target.worktreeName, contextNameLimit)
        let header = [
            "<alas-session-reference session_id=\"\(target.sessionId)\">",
            "The user attached the Alas session \"\(title)\" (agent: \(agentName), "
                + "worktree: \(worktreeName)) as context. To read more of it, call the "
                + "session_read tool of the \"alas\" MCP server with session_id \"\(target.sessionId)\".",
        ]
        let footer = "</alas-session-reference>"
        func intro(_ count: Int) -> String { "Its latest \(count) entries (earlier ones may be omitted):" }
        func line(_ entry: ACPSessionTranscriptReader.Entry) -> String {
            "[\(entry.role)]\(entry.truncated == true ? " …" : "") \(entry.text)"
        }
        // Everything but the entries' text, at its longest: the text budget
        // is what remains of `contextMaxChars`.
        let wrapper = (header + [intro(contextEntryLimit), footer]).map(\.count).reduce(0, +) + 3
        let textBudget = max(1, contextMaxChars - wrapper)
        // Each entry adds a blank separator line and its label (with a
        // marker once cut). While those push the block over budget, page
        // again with the overrun taken off the text budget; every pass
        // shrinks it, so this settles in a few passes.
        func size(_ page: ACPSessionTranscriptReader.Page) -> Int {
            page.entries.map { line($0).count + 2 }.reduce(0, +)
        }
        var maxChars = textBudget
        var page = ACPSessionTranscriptReader.page(
            entries, offset: nil, limit: contextEntryLimit, maxChars: maxChars
        )
        while size(page) > textBudget, maxChars > 1 {
            maxChars = max(1, maxChars - (size(page) - textBudget))
            page = ACPSessionTranscriptReader.page(
                entries, offset: nil, limit: contextEntryLimit, maxChars: maxChars
            )
        }
        var lines = header
        if page.entries.isEmpty {
            lines.append("The session has no messages yet.")
        } else {
            lines.append(intro(page.entries.count))
            for entry in page.entries {
                lines.append("")
                lines.append(line(entry))
            }
        }
        lines.append(footer)
        return lines.joined(separator: "\n")
    }
}
