import Foundation

/// The agent-facing JSON shape of a review comment, as returned by the
/// `review_comments` CLI/MCP command. Snake_cased on the wire via
/// `jsonLine`'s key strategy.
public struct ReviewCommentWireDTO: Codable, Equatable {
    public struct Author: Codable, Equatable {
        public var kind: String
        public var name: String?

        public init(_ author: ReviewDraftCommentAuthor) {
            switch author {
            case .user:
                kind = "user"
                name = nil
            case .agent(let agentName):
                kind = "agent"
                name = agentName
            }
        }
    }

    public struct Reply: Codable, Equatable {
        public var id: String
        public var author: Author
        public var body: String
        public var createdAt: String
    }

    public var id: String
    public var sessionId: String
    public var path: String
    public var anchorKind: String
    public var startLine: Int?
    public var endLine: Int?
    public var side: String
    public var xPercent: Double?
    public var yPercent: Double?
    public var state: String
    public var author: Author
    public var body: String
    public var selectedText: String?
    public var replies: [Reply]

    public init(_ comment: ReviewDraftComment) {
        id = comment.id
        sessionId = comment.sessionID.rawValue
        path = comment.path
        switch comment.anchor {
        case .file:
            anchorKind = "file"
            startLine = nil
            xPercent = nil
            yPercent = nil
        case .line(_, let line, _, _):
            anchorKind = "line"
            startLine = line
            xPercent = nil
            yPercent = nil
        case .image(_, let x, let y):
            anchorKind = "image"
            startLine = nil
            xPercent = x * 100
            yPercent = y * 100
        }
        endLine = comment.endLine
        side = comment.side.rawValue
        state = comment.state.rawValue
        author = Author(comment.effectiveAuthor)
        body = comment.bodyMarkdown
        selectedText = comment.selectedText
        replies = comment.allReplies.map { reply in
            Reply(
                id: reply.id,
                author: Author(reply.author),
                body: reply.bodyMarkdown,
                createdAt: Self.iso8601.string(from: reply.createdAt)
            )
        }
    }

    /// `nonisolated(unsafe)` is sound: the formatter is never mutated after
    /// initialization (only `.string(from:)` is called, above), and Foundation
    /// documents `ISO8601DateFormatter` as thread-safe for formatting once its
    /// configuration is fixed.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    /// One deterministic (sorted-keys, snake_case) JSON line for CLI/MCP
    /// text output.
    public static func jsonLine<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
