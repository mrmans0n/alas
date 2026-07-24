import Foundation

/// Pure Markdown serialization of an ACP conversation. No UI, no I/O.
///
/// Conversation-only: renders `.user` and `.agent` messages and omits
/// every other kind (thought, tool call, file edit, plan, system notice).
/// This is the single source of truth for formatting so whole-session
/// export/context and per-message copy render identically. Bare prose
/// web URLs are serialized as Markdown autolinks.
///
/// Reading an agent message's text touches `StreamingText.value`, which is
/// `@MainActor`-isolated, so the rendering entry points are `@MainActor`.
enum ACPTranscriptMarkdown {
    /// Whole conversation → Markdown document.
    /// - Parameters:
    ///   - title: session title; empty or "New session" falls back to "ACP session".
    ///   - agentName: display name for the agent heading; nil/blank falls back to "Agent".
    ///   - messages: full transcript in order. Non-conversation kinds are filtered out.
    @MainActor
    static func document(title: String, agentName: String?, messages: [ACPMessage]) -> String {
        let agentHeading = trimmedNonEmpty(agentName) ?? "Agent"
        var sections: [String] = ["# \(headerTitle(title))"]
        for message in messages {
            switch message {
            case .user(_, _, let text, _, _):
                sections.append("## You\n\n\(serializedBody(text))")
            case .agent(_, _, let buffer):
                sections.append("## \(agentHeading)\n\n\(serializedBody(buffer.value))")
            default:
                continue
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// One message's serialized Markdown source, or nil for non-conversation kinds.
    @MainActor
    static func messageBody(_ message: ACPMessage) -> String? {
        switch message {
        case .user(_, _, let text, _, _): return serializedBody(text)
        case .agent(_, _, let buffer): return serializedBody(buffer.value)
        default: return nil
        }
    }

    @MainActor
    static func forkContext(sourceAgentID: String, messages: [ACPMessage]) -> String? {
        let markdown = document(
            title: "Imported conversation",
            agentName: sourceAgentID,
            messages: messages
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        return """
        The conversation below was imported from \(sourceAgentID). Use it as background context for this branch. Provider-specific tool state, hidden context, and attachments were not transferred. Do not summarize or repeat the imported conversation unless I ask.

        \(markdown)
        """
    }

    /// Session title → filesystem-safe `.md` filename.
    static func sanitizedFilename(title: String) -> String {
        let base = trimmedNonEmpty(title).flatMap { $0 == "New session" ? nil : $0 } ?? "acp-session"
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = base.components(separatedBy: illegal).joined(separator: "-")
        let collapsed = cleaned.replacingOccurrences(of: " ", with: "-")
        let safe = collapsed.isEmpty ? "acp-session" : collapsed
        return "\(safe).md"
    }

    // MARK: - Helpers

    private static func serializedBody(_ text: String) -> String {
        ACPBareURLLinkifier.markdownAutolinkingBareURLs(
            text,
            preserveFencedCodeBlocks: true
        )
    }

    private static func headerTitle(_ title: String) -> String {
        trimmedNonEmpty(title).flatMap { $0 == "New session" ? nil : $0 } ?? "ACP session"
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
