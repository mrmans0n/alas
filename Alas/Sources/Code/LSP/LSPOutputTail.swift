import Foundation

/// The last lines a language server wrote to stderr, kept so a crash can show
/// why it happened. Bounded by line count and total bytes; blank lines are
/// dropped and invalid UTF-8 is replaced rather than rejected.
///
/// Bytes are split on newlines before decoding, so a multibyte scalar that
/// straddles two chunks stays intact. The unterminated line in progress is
/// capped to its last `maxBytes` bytes as data arrives.
struct LSPOutputTail: Sendable {
    static let maxLines = 20
    static let maxBytes = 8192

    private(set) var lines: [String] = []
    private var partial: [UInt8] = []

    mutating func append(_ data: Data) {
        var rest = data[...]
        while let newline = rest.firstIndex(of: 0x0A) {
            extendPartial(with: rest[rest.startIndex ..< newline])
            flushPartial()
            rest = rest[(newline + 1)...]
        }
        extendPartial(with: rest)
    }

    /// Flushes an unterminated final line and returns the tail.
    mutating func finish() -> [String] {
        flushPartial()
        return lines
    }

    private mutating func extendPartial(with segment: Data) {
        let kept = segment.suffix(Self.maxBytes)
        partial.append(contentsOf: kept)
        let excess = partial.count - Self.maxBytes
        guard excess > 0 || kept.count < segment.count else { return }
        // Bytes were dropped from the front: skip the continuation bytes of a
        // scalar the cut landed in the middle of.
        var drop = max(excess, 0)
        while drop < partial.count, partial[drop] & 0xC0 == 0x80 { drop += 1 }
        partial.removeFirst(drop)
    }

    private mutating func flushPartial() {
        if partial.last == 0x0D { partial.removeLast() }
        guard !partial.isEmpty else { return }
        push(String(decoding: partial, as: UTF8.self))
        partial.removeAll(keepingCapacity: true)
    }

    private mutating func push(_ decoded: String) {
        var line = decoded
        // Invalid bytes decode to three-byte replacement characters, so the
        // decoded line can outgrow the raw cap.
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
