import Foundation

/// The agent-facing JSON shape of a review comment, as returned by the
/// `review_comments` CLI/MCP command. Snake_cased on the wire via
/// `jsonLine`'s key strategy.
struct ReviewCommentWireDTO: Codable, Equatable {
    struct Author: Codable, Equatable {
        var kind: String
        var name: String?

        init(_ author: ReviewDraftCommentAuthor) {
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

    struct Reply: Codable, Equatable {
        var id: String
        var author: Author
        var body: String
        var createdAt: String
    }

    var id: String
    var sessionId: String
    var path: String
    var anchorKind: String
    var startLine: Int?
    var endLine: Int?
    var side: String
    var xPercent: Double?
    var yPercent: Double?
    var state: String
    var author: Author
    var body: String
    var selectedText: String?
    var replies: [Reply]

    init(_ comment: ReviewDraftComment) {
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

    private static let iso8601 = ISO8601DateFormatter()

    /// One deterministic (sorted-keys, snake_case) JSON line for CLI/MCP
    /// text output.
    static func jsonLine<T: Encodable>(_ value: T) -> String {
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
