import Foundation
import AlasModel

/// A card Alas adds to a transcript when something it tracks for the session
/// finishes, such as the PR the session shipped being merged. Not a turn: the
/// agent never sees it. `text` is what readers without the card show, and is
/// stored as the row's notice text so an older build shows it as a notice.
public struct ACPOutcomeCard: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let card: ACPPromptCard
    public let text: String

    public init(id: UUID = UUID(), card: ACPPromptCard, text: String) {
        self.id = id
        self.card = card
        self.text = text
    }
}
