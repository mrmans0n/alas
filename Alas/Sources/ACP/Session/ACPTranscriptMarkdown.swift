import Foundation

/// Pure Markdown serialization of an ACP conversation. No UI, no I/O.
///
/// Conversation-only: renders `.user` and `.agent` messages and omits
/// every other kind (thought, tool call, file edit, plan, system notice).
/// This is the single source of truth for formatting so whole-session
/// export and per-message copy render identically.
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
            case .user(_, let text, _):
                sections.append("## You\n\n\(text)")
            case .agent(_, let buffer):
                sections.append("## \(agentHeading)\n\n\(buffer.value)")
            default:
                continue
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// One message's raw Markdown source, or nil for non-conversation kinds.
    @MainActor
    static func messageBody(_ message: ACPMessage) -> String? {
        switch message {
        case .user(_, let text, _): return text
        case .agent(_, let buffer): return buffer.value
        default: return nil
        }
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

    private static func headerTitle(_ title: String) -> String {
        trimmedNonEmpty(title).flatMap { $0 == "New session" ? nil : $0 } ?? "ACP session"
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
