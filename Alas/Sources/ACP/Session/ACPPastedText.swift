import Foundation

/// Where one pasted-text badge sits in a recorded user message. Offsets are
/// UTF-16 units into the message `text`, so the renderer slices with
/// `NSString` ranges instead of walking a large paste by grapheme.
struct ACPPastedTextSpan: Codable, Hashable, Sendable {
    let ordinal: Int
    let utf16Offset: Int
    let utf16Length: Int

    var utf16Range: NSRange { NSRange(location: utf16Offset, length: utf16Length) }
}

/// When a paste collapses into a badge, and what the badge says.
enum ACPPastedTextPolicy {
    static let maxInlineLines = 20
    static let maxInlineUTF16Units = 2_000

    static func shouldCollapse(_ text: String) -> Bool {
        text.utf16.count > maxInlineUTF16Units || lineCount(text) > maxInlineLines
    }

    /// `\n`-separated lines, ignoring one trailing newline. `\r\n` holds a
    /// single `\n`, so CRLF text counts the same as LF text.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A { newlines += 1 }
        if text.utf8.last == 0x0A { newlines -= 1 }
        return newlines + 1
    }

    static func label(ordinal: Int, content: String) -> String {
        let lines = lineCount(content)
        let size = lines > 1
            ? "\(lines) lines"
            : ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
        return "Pasted text #\(ordinal) · \(size)"
    }
}

/// A recorded message's text plus its validated pasted spans, sorted by
/// offset. Two values built from the same message share `String` storage,
/// which `==` compares by identity first, so equality stays cheap for a
/// large paste.
struct ACPPastedTextContents: Equatable, Sendable {
    let text: String
    let spans: [ACPPastedTextSpan]

    /// Nil when `spans` is empty or invalid: empty, out of range,
    /// overlapping, or reusing an ordinal. A bad span set renders the full
    /// text rather than badging the wrong characters.
    init?(text: String, spans: [ACPPastedTextSpan]) {
        guard !spans.isEmpty else { return nil }
        let sorted = spans.sorted { $0.utf16Offset < $1.utf16Offset }
        let length = text.utf16.count
        var end = 0
        var ordinals = Set<Int>()
        for span in sorted {
            guard span.utf16Length > 0,
                  span.utf16Offset >= end,
                  span.utf16Offset + span.utf16Length <= length,
                  ordinals.insert(span.ordinal).inserted
            else { return nil }
            end = span.utf16Offset + span.utf16Length
        }
        self.text = text
        self.spans = sorted
    }

    func content(ordinal: Int) -> String? {
        guard let span = spans.first(where: { $0.ordinal == ordinal }) else { return nil }
        return (text as NSString).substring(with: span.utf16Range)
    }

    /// The message with every pasted span removed: what the user typed.
    var typedText: String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for span in spans {
            result += source.substring(with: NSRange(location: cursor, length: span.utf16Offset - cursor))
            cursor = span.utf16Offset + span.utf16Length
        }
        result += source.substring(from: cursor)
        return result
    }

    /// Whether every span starts at or after `utf16Offset`. A leading slash
    /// command is only a command when the user typed it, not when a paste
    /// begins with one.
    func spansStart(atOrAfter utf16Offset: Int) -> Bool {
        spans.allSatisfy { $0.utf16Offset >= utf16Offset }
    }
}
