import Foundation

/// The last lines a language server wrote to stderr, kept so a crash can show
/// why it happened. Bounded by line count and total bytes; blank lines are
/// dropped and invalid UTF-8 is replaced rather than rejected.
struct LSPOutputTail: Sendable {
    static let maxLines = 20
    static let maxBytes = 8192

    private(set) var lines: [String] = []
    private var partial = ""

    mutating func append(_ data: Data) {
        var pieces = (partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        partial = pieces.removeLast()
        for piece in pieces { push(piece) }
    }

    /// Flushes an unterminated final line and returns the tail.
    mutating func finish() -> [String] {
        if !partial.isEmpty {
            push(partial)
            partial = ""
        }
        return lines
    }

    private mutating func push(_ raw: String) {
        var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard !line.isEmpty else { return }
        if line.utf8.count > Self.maxBytes {
            line = String(decoding: line.utf8.suffix(Self.maxBytes), as: UTF8.self)
        }
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        while lines.count > 1, lines.reduce(0, { $0 + $1.utf8.count }) > Self.maxBytes {
            lines.removeFirst()
        }
    }
}
