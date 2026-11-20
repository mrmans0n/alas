import Foundation

/// An `ACPPromptCard` as a peer reads it from `RemoteWireMessage.json`. The
/// Mac's card also opens reviews, which need the Mac's models, so only its
/// `.url` and `.reviewChanges` actions are read here; the parts below are the card's own types.
public struct RemotePromptCard: Decodable, Equatable, Sendable {
    public let origin: Origin
    public let title: String
    public let facts: [Fact]
    public let sections: [Section]
    /// The card's `.url` action; nil for any other action.
    public let actionURL: URL?
    /// Whether the card's action is `.reviewChanges`, which the phone runs by opening its Changes tab.
    public let opensChanges: Bool

    private enum CodingKeys: String, CodingKey {
        case origin, title, facts, sections, action
    }

    /// `ACPPromptCard.Action.url` as Swift encodes it: `{"url":{"_0":"…"}}`.
    private struct URLAction: Decodable {
        struct Payload: Decodable { let _0: URL }
        let url: Payload
    }

    /// `ACPPromptCard.Action.reviewChanges(worktreeID:)` as Swift encodes it; only its presence matters.
    private struct ChangesAction: Decodable {
        let reviewChanges: Empty
        struct Empty: Decodable {}
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(Origin.self, forKey: .origin)
        title = try c.decode(String.self, forKey: .title)
        facts = try c.decode([Fact].self, forKey: .facts)
        sections = try c.decode([Section].self, forKey: .sections)
        actionURL = (try? c.decodeIfPresent(URLAction.self, forKey: .action))?.url._0
        opensChanges = (try? c.decodeIfPresent(ChangesAction.self, forKey: .action)) != nil
    }

    /// String-backed so a value written by a newer build still decodes.
    public struct Origin: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let review = Origin(rawValue: "review")
        public static let ship = Origin(rawValue: "ship")
        public static let shepherd = Origin(rawValue: "shepherd")
        /// Outcome cards: what became of a shepherded request or stack.
        public static let merged = Origin(rawValue: "merged")
        public static let closed = Origin(rawValue: "closed")
        public static let queued = Origin(rawValue: "queued")
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
}
