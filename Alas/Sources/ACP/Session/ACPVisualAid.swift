import Foundation

/// An HTML visual an agent showed through the `visual_show` MCP tool, with an
/// optional single question the user answers from a native card.
struct ACPVisualAid: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let html: String
    let question: Question?
    var answer: Answer?
    let createdAt: Date

    struct Option: Codable, Equatable, Sendable {
        let id: String
        let label: String
    }

    struct Question: Codable, Equatable, Sendable {
        let prompt: String
        let options: [Option]
        let allowMultiple: Bool
    }

    enum Answer: Codable, Equatable, Sendable {
        case answered(selectedOptionIds: [String], note: String?, at: Date)
        case dismissed(at: Date)
    }

    /// The `visual_show` limits from `mcp.rs`. Counted in Unicode scalars so
    /// they agree with Rust's `chars().count()`.
    enum Limits {
        static let titleMaxCharacters = 120
        static let htmlMaxBytes = 512 * 1024
        static let promptMaxCharacters = 500
        static let optionCount = 2...8
        static let optionIdMaxCharacters = 64
        static let optionLabelMaxCharacters = 200
    }

    /// Why the arguments break the `visual_show` contract, or nil when they
    /// hold. The app re-checks because the socket also takes direct requests.
    static func validationFailure(title: String, html: String, question: Question?) -> String? {
        guard (1...Limits.titleMaxCharacters).contains(title.unicodeScalars.count) else {
            return "title must be 1 to \(Limits.titleMaxCharacters) characters"
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "html must be non-empty" }
        guard html.utf8.count <= Limits.htmlMaxBytes else { return "html must be at most \(Limits.htmlMaxBytes) bytes" }
        guard let question else { return nil }
        guard (1...Limits.promptMaxCharacters).contains(question.prompt.unicodeScalars.count) else {
            return "question.prompt must be 1 to \(Limits.promptMaxCharacters) characters"
        }
        guard Limits.optionCount.contains(question.options.count) else { return "question.options must have 2 to 8 items" }
        var seen = Set<String>()
        for option in question.options {
            let validID = (1...Limits.optionIdMaxCharacters).contains(option.id.unicodeScalars.count)
                && option.id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
            guard validID else { return "question option id '\(option.id)' is invalid" }
            guard seen.insert(option.id).inserted else { return "question option id '\(option.id)' is duplicated" }
            guard (1...Limits.optionLabelMaxCharacters).contains(option.label.unicodeScalars.count) else {
                return "question option '\(option.id)' label must be 1 to \(Limits.optionLabelMaxCharacters) characters"
            }
        }
        return nil
    }

    /// One line for `session_read`/`session_search`. Never includes the HTML.
    var transcriptSummary: String {
        var text = "visual aid: \(title)"
        switch answer {
        case .answered(let ids, let note, _):
            text += " (answered: \(ids.joined(separator: ", "))"
            if let note { text += "; note: \(note)" }
            text += ")"
        case .dismissed:
            text += " (dismissed)"
        case nil:
            break
        }
        return text
    }
}
