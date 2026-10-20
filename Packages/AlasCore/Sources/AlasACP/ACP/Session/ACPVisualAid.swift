import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// An HTML visual an agent showed through the `visual_show` MCP tool, with an
/// optional single question the user answers from a native card.
public struct ACPVisualAid: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let html: String
    public let question: Question?
    public let presentation: Presentation
    public var answer: Answer?
    public let createdAt: Date

    /// How the visual is shown in the transcript: borderless inline content, or
    /// a bordered card. A visual with a question is always a card.
    public enum Presentation: String, Codable, Sendable {
        case embedded
        case card
    }

    public struct Option: Codable, Equatable, Sendable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        public let prompt: String
        public let options: [Option]
        public let allowMultiple: Bool

        public init(prompt: String, options: [Option], allowMultiple: Bool) {
            self.prompt = prompt
            self.options = options
            self.allowMultiple = allowMultiple
        }
    }

    public enum Answer: Codable, Equatable, Sendable {
        case answered(selectedOptionIds: [String], note: String?, at: Date)
        case dismissed(at: Date)
    }

    /// The `visual_show` limits from `mcp.rs`. Counted in Unicode scalars so
    /// they agree with Rust's `chars().count()`.
    public enum Limits: Sendable {
        public static let titleMaxCharacters = 120
        public static let htmlMaxBytes = 512 * 1024
        public static let promptMaxCharacters = 500
        public static let optionCount = 2...8
        public static let optionIdMaxCharacters = 64
        public static let optionLabelMaxCharacters = 200
    }

    /// Why the arguments break the `visual_show` contract, or nil when they
    /// hold. The app re-checks because the socket also takes direct requests.
    public static func validationFailure(title: String, html: String, question: Question?) -> String? {
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
    public var transcriptSummary: String {
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

    /// A question needs the card's controls, so it forces `.card`; otherwise
    /// the request wins and defaults to `.embedded`.
    public static func resolvePresentation(requested: Presentation?, hasQuestion: Bool) -> Presentation {
        hasQuestion ? .card : (requested ?? .embedded)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, html, question, presentation, answer, createdAt
    }

    /// Visuals stored before `presentation` existed read back as cards.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        html = try c.decode(String.self, forKey: .html)
        question = try c.decodeIfPresent(Question.self, forKey: .question)
        presentation = try c.decodeIfPresent(Presentation.self, forKey: .presentation) ?? .card
        answer = try c.decodeIfPresent(Answer.self, forKey: .answer)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public init(
        id: UUID, title: String, html: String, question: Question?,
        presentation: Presentation = .card, answer: Answer? = nil, createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.html = html
        self.question = question
        self.presentation = presentation
        self.answer = answer
        self.createdAt = createdAt
    }
}
