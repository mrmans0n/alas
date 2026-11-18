import Foundation
import AlasFoundation

/// How Alas shows a turn it injected (review feedback, Ship, PR shepherd):
/// a structured card in place of the instruction text. Presentation only;
/// the agent receives the text, and queue behavior stays on
/// `ACPDelegatedPromptSource`'s other fields.
public struct ACPPromptCard: Codable, Equatable, Sendable {
    public var origin: Origin
    public var title: String
    public var facts: [Fact]
    public var sections: [Section]
    public var action: Action?

    public init(origin: Origin, title: String, facts: [Fact] = [], sections: [Section] = [], action: Action? = nil) {
        self.origin = origin
        self.title = title
        self.facts = facts
        self.sections = sections
        self.action = action
    }

    // The parts a peer can show live in AlasRemoteKit, which the phone links.
    public typealias Origin = RemotePromptCard.Origin
    public typealias Fact = RemotePromptCard.Fact
    public typealias Section = RemotePromptCard.Section
    public typealias Item = RemotePromptCard.Item
    public typealias Location = RemotePromptCard.Location
    public typealias Excerpt = RemotePromptCard.Excerpt

    /// `remote` with its `.url` action, the only one a peer reads.
    public init(_ remote: RemotePromptCard) {
        self.init(origin: remote.origin, title: remote.title, facts: remote.facts, sections: remote.sections,
                  action: remote.actionURL.map(Action.url))
    }

    public enum Action: Codable, Equatable, Sendable {
        case url(URL)
        case reviewSession(ReviewSessionTarget)
        case reviewChanges(worktreeID: String)
    }

    /// The card a transcript row shows for `source`: its own card, else a
    /// header-only card for an app action saved before cards existed.
    public static func resolved(for source: ACPDelegatedPromptSource?) -> ACPPromptCard? {
        guard let source else { return nil }
        if let card = source.card { return card }
        return source.appAction.map(legacy(appAction:))
    }

    public static func legacy(appAction: ACPDelegatedPromptSource.AppAction) -> ACPPromptCard {
        ACPPromptCard(origin: Origin(rawValue: appAction.source.lowercased()), title: appAction.title)
    }
}
