import Foundation
import AlasACP
import AlasRemoteKit

/// Builds the snapshot from the request it resolves.
extension ACPAnsweredQuestion {
    public init(request: ACPUserInputRequest, action: ACPUserInputAction) {
        let content: [String: ACPElicitationValue]
        let outcome: Outcome
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
        let items: [Item] = request.fieldGroups.map { group in
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
        self.init(id: request.id, title: request.title, message: request.message, outcome: outcome, items: items)
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
