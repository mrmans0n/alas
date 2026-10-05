import Foundation

/// The bounded `{title, body}` user message both issue helpers send to the
/// local model. Candidates go from most to least context, and the engine
/// picks the first that fits its token limit, so an oversized body degrades
/// to title-only.
enum IssueTicketInput {
    private static let bodyCharacterBudgets = [4_000, 1_000, 0]
    private static let titleCharacterLimit = 300

    static func messageCandidates(systemPrompt: String, title: String, body: String) -> [[LocalTextMessage]] {
        struct Ticket: Encodable {
            let title: String
            let body: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let boundedTitle = String(title.prefix(titleCharacterLimit))
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return bodyCharacterBudgets.map { budget in
            let ticket = Ticket(
                title: boundedTitle,
                body: budget == 0 || trimmedBody.isEmpty ? nil : String(trimmedBody.prefix(budget))
            )
            let data = (try? encoder.encode(ticket)) ?? Data()
            return [
                .init(role: .system, content: systemPrompt),
                .init(role: .user, content: String(decoding: data, as: UTF8.self)),
            ]
        }
    }
}
