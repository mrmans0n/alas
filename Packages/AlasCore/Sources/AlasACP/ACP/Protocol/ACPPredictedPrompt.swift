import Foundation
import AlasModel

/// The client-neutral predicted follow-up prompt of our Claude and Codex
/// adapter forks. Alas declares `clientCapabilities._meta.promptSuggestions`,
/// and a `session/prompt` that wants its turn's prediction names an id in
/// `_meta.promptSuggestions.id`. The adapter answers once, after the turn, with
/// a `session_info_update` whose `_meta.promptSuggestions` carries
/// `suggestions: [{text}]` and that id; an empty list says the turn predicted
/// nothing. A turn can also end with no answer at all. The same key without an
/// id is the AIR form, or the adapter clearing what it sent before.
///
/// Not to be confused with `ACPSession.promptSuggestions`, the session's
/// commands and skills.
public enum ACPPredictedPrompt {
    /// `_meta.promptSuggestions` of a `session/prompt` request.
    public struct Request: Codable, Equatable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    /// The adapter's answer to a request.
    public struct Answer: Equatable, Sendable {
        public let id: String
        /// The first non-blank suggestion, trimmed; nil when it predicted none.
        public let text: String?

        public init(id: String, text: String?) {
            self.id = id
            self.text = text
        }
    }

    public static func newRequestID() -> String { UUID().uuidString }

    /// The answer `update` carries, or nil when it carries none: another kind
    /// of update, a clear, or the AIR form, which names no request.
    public static func answer(in update: ACPSessionUpdate) -> Answer? {
        guard case .sessionInfoUpdate(let info) = update,
              let metadata = info.metadata,
              let data = try? JSONEncoder().encode(metadata) else { return nil }
        struct Root: Decodable {
            struct Value: Decodable {
                struct Suggestion: Decodable {
                    let text: String?
                }
                let suggestions: [Suggestion]?
                let id: String?
            }
            let promptSuggestions: Value?
        }
        guard let value = (try? JSONDecoder().decode(Root.self, from: data))?.promptSuggestions,
              let id = value.id, !id.isEmpty, let suggestions = value.suggestions else { return nil }
        let text = suggestions.lazy
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return Answer(id: id, text: text)
    }
}
