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

    /// String-backed so a value written by a newer build still decodes.
    public struct Origin: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let review = Origin(rawValue: "review")
        public static let ship = Origin(rawValue: "ship")
        public static let shepherd = Origin(rawValue: "shepherd")
    }

    public struct Fact: Codable, Equatable, Sendable {
        /// String-backed so a value written by a newer build still decodes.
        public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let repository = Kind(rawValue: "repository")
            public static let revision = Kind(rawValue: "revision")
            public static let branch = Kind(rawValue: "branch")
            public static let provider = Kind(rawValue: "provider")
            public static let other = Kind(rawValue: "other")
        }

        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var title: String?
        public var items: [Item]

        public init(title: String?, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    public struct Item: Codable, Equatable, Sendable {
        /// String-backed so a value written by a newer build still decodes.
        public struct Status: RawRepresentable, Codable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }
            public static let failed = Status(rawValue: "failed")
            public static let cancelled = Status(rawValue: "cancelled")
            public static let conflict = Status(rawValue: "conflict")
        }

        public var location: Location?
        public var author: String?
        public var bodyMarkdown: String?
        public var excerpt: Excerpt?
        public var url: URL?
        public var status: Status?
        /// The local review draft comment this item shows, for live status.
        public var reviewCommentID: String?

        public init(
            location: Location? = nil,
            author: String? = nil,
            bodyMarkdown: String? = nil,
            excerpt: Excerpt? = nil,
            url: URL? = nil,
            status: Status? = nil,
            reviewCommentID: String? = nil
        ) {
            self.location = location
            self.author = author
            self.bodyMarkdown = bodyMarkdown
            self.excerpt = excerpt
            self.url = url
            self.status = status
            self.reviewCommentID = reviewCommentID
        }
    }

    public struct Location: Codable, Equatable, Sendable {
        public var path: String
        public var startLine: Int?
        public var endLine: Int?
        /// "old" or "new"; nil when the side is unknown or irrelevant.
        public var side: String?

        public init(path: String, startLine: Int? = nil, endLine: Int? = nil, side: String? = nil) {
            self.path = path
            self.startLine = startLine
            self.endLine = endLine
            self.side = side
        }
    }

    public struct Excerpt: Codable, Equatable, Sendable {
        public enum Style: String, Codable, Sendable { case code, log }

        public var text: String
        public var style: Style
        public var language: String?

        public init(text: String, style: Style, language: String? = nil) {
            self.text = text
            self.style = style
            self.language = language
        }
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
