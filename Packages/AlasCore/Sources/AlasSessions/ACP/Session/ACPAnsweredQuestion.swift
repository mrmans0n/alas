import Foundation
import AlasACP
import AlasRemoteKit

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
    }

    public struct Item: Codable, Equatable, Sendable {
        public let question: String
        public let description: String?
        public let answer: String?
        public let options: [Option]
    }

    public let id: UUID
    public let title: String?
    public let message: String
    public let outcome: Outcome
    public let items: [Item]

    public init(request: ACPUserInputRequest, action: ACPUserInputAction) {
        id = request.id
        title = request.title
        message = request.message
        let content: [String: ACPElicitationValue]
        switch action {
        case .submit(let values):
            content = values
            outcome = request.mode == .form ? .answered : .opened
        case .decline:
            content = [:]
            outcome = .skipped
        case .cancel:
            content = [:]
            outcome = .cancelled
        }
        items = request.fieldGroups.map { group in
            let field = group.field
            let selected: Set<String>
            switch content[field.key] {
            case .string(let value): selected = [value]
            case .strings(let values): selected = Set(values)
            default: selected = []
            }
            let options: [Option] = field.schema.isSecret ? [] : field.schema.options.map {
                Option(title: $0.title ?? $0.const, description: $0.description, selected: selected.contains($0.const))
            }
            var parts: [String] = []
            if let value = content[field.key] {
                if field.schema.isSecret {
                    parts.append("Hidden")
                } else {
                    let isOwnAnswer = field.schema.acceptsOwnAnswer
                        && value == .string(ACPUserInputRequest.ownAnswerOptionConst)
                    if !isOwnAnswer { parts.append(Self.display(value, options: field.schema.options)) }
                }
            }
            if let note = group.note, let value = content[note.key] {
                parts.append(note.schema.isSecret ? "Hidden" : Self.display(value, options: note.schema.options))
            }
            let answer = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return Item(
                question: field.label, description: field.schema.description,
                answer: answer.isEmpty ? nil : answer, options: options
            )
        }
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

    private static func display(_ value: ACPElicitationValue, options: [ACPElicitationOption]) -> String {
        func label(_ value: String) -> String {
            options.first { $0.const == value }?.title ?? value
        }
        switch value {
        case .string(let value): return label(value)
        case .strings(let values): return values.map(label).joined(separator: ", ")
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "Yes" : "No"
        }
    }
}
