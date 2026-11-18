import Foundation

/// Display-only history of a resolved input. Raw schemas, defaults, request
/// metadata and secret values never enter this snapshot.
public struct ACPAnsweredQuestion: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case answered, skipped, cancelled, opened
    }

    public struct Option: Codable, Equatable, Sendable {
        public let title: String
        public let description: String?
        public let selected: Bool

        public init(title: String, description: String?, selected: Bool) {
            self.title = title
            self.description = description
            self.selected = selected
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        public let question: String
        public let description: String?
        public let answer: String?
        public let options: [Option]

        public init(question: String, description: String?, answer: String?, options: [Option]) {
            self.question = question
            self.description = description
            self.answer = answer
            self.options = options
        }
    }

    public let id: UUID
    public let title: String?
    public let message: String
    public let outcome: Outcome
    public let items: [Item]

    public init(id: UUID, title: String?, message: String, outcome: Outcome, items: [Item]) {
        self.id = id
        self.title = title
        self.message = message
        self.outcome = outcome
        self.items = items
    }

    public var statusLabel: String {
        switch outcome {
        case .answered: "Answered"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        case .opened: "Opened in browser"
        }
    }

    public var displayText: String {
        ([message, statusLabel] + items.map {
            $0.question + ($0.answer.map { "\n\($0)" } ?? "")
        }).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
