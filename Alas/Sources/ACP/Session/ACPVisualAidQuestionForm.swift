import Foundation
import Observation

/// Maps a visual aid's question onto the native user-input form, and the
/// submitted form back onto an answer and the prompt the agent receives.
enum ACPVisualAidQuestionForm {
    static let choiceKey = "choice"
    static let noteKey = "note"
    static let noteMaxLength = 2000

    static func request(for visual: ACPVisualAid) -> ACPUserInputRequest? {
        guard let question = visual.question else { return nil }
        let choice = ACPUserInputField(key: choiceKey, required: true, schema: .init(
            type: question.allowMultiple ? "array" : "string",
            title: question.prompt, description: nil,
            minLength: nil, maxLength: nil, pattern: nil, format: nil, minimum: nil, maximum: nil,
            minItems: question.allowMultiple ? 1 : nil, maxItems: nil,
            options: question.options.map { ACPElicitationOption(const: $0.id, title: $0.label, description: nil) },
            defaultValue: nil, isSecret: false
        ))
        let note = ACPUserInputField(key: noteKey, required: false, schema: .init(
            type: "string", title: "Note", description: nil,
            minLength: nil, maxLength: noteMaxLength, pattern: nil, format: nil, minimum: nil, maximum: nil,
            minItems: nil, maxItems: nil, options: [], defaultValue: nil, isSecret: false
        ))
        return ACPUserInputRequest(
            id: visual.id, source: .visualAid(visual.id), title: visual.title,
            message: question.prompt, fields: [choice, note], mode: .form
        )
    }

    /// The choice field when `choice` is exactly one of the option ids.
    static func choiceField(for choice: String, in request: ACPUserInputRequest) -> ACPUserInputField? {
        guard let field = request.fields.first(where: { $0.key == choiceKey }),
              field.schema.options.contains(where: { $0.const == choice })
        else { return nil }
        return field
    }

    static func answer(
        from content: [String: ACPElicitationValue],
        question: ACPVisualAid.Question,
        at date: Date
    ) -> ACPVisualAid.Answer? {
        let picked: Set<String>
        switch content[choiceKey] {
        case .string(let id): picked = [id]
        case .strings(let ids): picked = Set(ids)
        default: return nil
        }
        let ordered = question.options.map(\.id).filter(picked.contains)
        guard !ordered.isEmpty else { return nil }
        var note: String?
        if case .string(let text) = content[noteKey] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            note = trimmed.isEmpty ? nil : trimmed
        }
        return .answered(selectedOptionIds: ordered, note: note, at: date)
    }

    /// The user prompt an answer sends; nil for a dismissal, which sends nothing.
    static func answerPrompt(for visual: ACPVisualAid, answer: ACPVisualAid.Answer) -> String? {
        guard case .answered(let ids, let note, _) = answer else { return nil }
        let labels = Dictionary(uniqueKeysWithValues: (visual.question?.options ?? []).map { ($0.id, $0.label) })
        var lines = [
            "[Visual aid: \(visual.title)] \(visual.question?.prompt ?? "")",
            "Selected: " + ids.map { "\($0) (\(labels[$0] ?? $0))" }.joined(separator: ", "),
        ]
        if let note, !note.isEmpty { lines.append("Note: \(note)") }
        return lines.joined(separator: "\n")
    }
}

/// Delivery state of one visual aid's answer, kept on the session so a card
/// remounted after leaving the mount band still shows a failed send.
@MainActor
@Observable
final class ACPVisualAidSendStatus {
    static let failureMessage = "Couldn't send your answer. Try again."

    var error: String?
}
