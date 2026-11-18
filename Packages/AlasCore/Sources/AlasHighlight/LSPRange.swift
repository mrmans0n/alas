import Foundation

public struct LSPPosition: Codable, Hashable, Sendable {
    public let line: Int          // 0-based
    public let character: Int     // UTF-16 code units, 0-based per spec

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Hashable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public var json: [String: Any] {
        [
            "start": ["line": start.line, "character": start.character],
            "end": ["line": end.line, "character": end.character]
        ]
    }

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}
