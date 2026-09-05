import Foundation

/// What a keystroke should do about code fences. `.none` means the caller
/// falls through to `PairedDelimiterEditing`, whose one- and two-backtick
/// wrapping behaviour is unchanged by this feature.
enum FenceEditAction: Equatable {
    case openBlock
    case wrapSelection
    case none
}

/// A fenced code block found in markdown source.
///
/// `openFenceRange` and `closeFenceRange` are content ranges — they exclude the
/// line terminator. `bodyRange` spans everything between the two fence lines,
/// including each body line's own terminator. `outerRange` covers the block from
/// the first backtick of the opening fence to the last backtick of the closing
/// fence, or to end of text when the block is still unclosed.
///
/// `infoRange` is the opening fence line's info-string slot: everything from the
/// end of its backtick run to the end of the line, untrimmed. `infoString` is
/// the trimmed contents of exactly that range. An opener with no info string
/// still has an `infoRange` — an empty one parked where the tag would go.
struct FencedBlock: Equatable {
    var openFenceRange: NSRange
    var bodyRange: NSRange
    var closeFenceRange: NSRange?
    var infoString: String
    var infoRange: NSRange
    var outerRange: NSRange
}

enum MarkdownFenceEditing {
    /// CommonMark's minimum fence width.
    static let minimumFenceLength = 3
    /// CommonMark allows a fence to be indented by at most three spaces.
    private static let maximumFenceIndent = 3

    private static let space: unichar = 0x20
    private static let backtick: unichar = 0x60
    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D

    private struct FenceLine {
        var lineRange: NSRange      // includes the trailing terminator
        var contentRange: NSRange   // excludes the trailing terminator
        var backtickCount: Int
        var info: String
        var infoRange: NSRange      // the slot `info` was trimmed out of
    }

    static func blocks(in text: String) -> [FencedBlock] {
        let ns = text as NSString
        let fences = fenceLines(in: ns)
        var blocks: [FencedBlock] = []
        var index = 0

        while index < fences.count {
            let opener = fences[index]
            // Inside a block every line is content until a fence that is at
            // least as wide as the opener and carries no info string.
            var closerIndex: Int?
            var scan = index + 1
            while scan < fences.count {
                let candidate = fences[scan]
                if candidate.backtickCount >= opener.backtickCount, candidate.info.isEmpty {
                    closerIndex = scan
                    break
                }
                scan += 1
            }

            if let closerIndex {
                let closer = fences[closerIndex]
                let bodyStart = NSMaxRange(opener.lineRange)
                blocks.append(FencedBlock(
                    openFenceRange: opener.contentRange,
                    bodyRange: NSRange(
                        location: bodyStart,
                        length: max(0, closer.lineRange.location - bodyStart)
                    ),
                    closeFenceRange: closer.contentRange,
                    infoString: opener.info,
                    infoRange: opener.infoRange,
                    outerRange: NSRange(
                        location: opener.contentRange.location,
                        length: NSMaxRange(closer.contentRange) - opener.contentRange.location
                    )
                ))
                index = closerIndex + 1
            } else {
                let bodyStart = min(NSMaxRange(opener.lineRange), ns.length)
                blocks.append(FencedBlock(
                    openFenceRange: opener.contentRange,
                    bodyRange: NSRange(location: bodyStart, length: ns.length - bodyStart),
                    closeFenceRange: nil,
                    infoString: opener.info,
                    infoRange: opener.infoRange,
                    outerRange: NSRange(
                        location: opener.contentRange.location,
                        length: ns.length - opener.contentRange.location
                    )
                ))
                index = fences.count
            }
        }

        return blocks
    }

    private static func fenceLines(in ns: NSString) -> [FenceLine] {
        var lines: [FenceLine] = []
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break }
            let contentRange = trimmingLineTerminator(lineRange, in: ns)
            if let fence = parseFence(contentRange, in: ns) {
                lines.append(FenceLine(
                    lineRange: lineRange,
                    contentRange: contentRange,
                    backtickCount: fence.count,
                    info: fence.info,
                    infoRange: fence.infoRange
                ))
            }
            location = NSMaxRange(lineRange)
        }
        return lines
    }

    private static func parseFence(
        _ range: NSRange,
        in ns: NSString
    ) -> (count: Int, info: String, infoRange: NSRange)? {
        var index = range.location
        let end = NSMaxRange(range)

        var indent = 0
        while index < end, indent < maximumFenceIndent, ns.character(at: index) == space {
            index += 1
            indent += 1
        }

        var count = 0
        while index < end, ns.character(at: index) == backtick {
            index += 1
            count += 1
        }
        guard count >= minimumFenceLength else { return nil }

        // Everything past the backticks is the info-string slot, whether or
        // not anything has been typed into it yet.
        let infoRange = NSRange(location: index, length: end - index)
        let info = ns.substring(with: infoRange)
            .trimmingCharacters(in: .whitespaces)
        // A backtick-fence info string may not itself contain a backtick.
        guard !info.contains("`") else { return nil }
        return (count, info, infoRange)
    }

    private static func trimmingLineTerminator(_ range: NSRange, in ns: NSString) -> NSRange {
        var length = range.length
        if length > 0, ns.character(at: range.location + length - 1) == lineFeed {
            length -= 1
        }
        if length > 0, ns.character(at: range.location + length - 1) == carriageReturn {
            length -= 1
        }
        return NSRange(location: range.location, length: length)
    }

    /// What the keystroke `insertedText` at `selectedRange` should do about
    /// code fences.
    ///
    /// Both non-`.none` answers rewrite a span of the document into a whole
    /// new block, and the caller acts on them without a further structural
    /// check of its own — unlike `.none`, which routes through
    /// `PairedComposerTextControls`' simulate-and-compare guard. So this is
    /// where the invariant has to hold: neither answer is ever returned when
    /// the edit would land on an existing block. A caret is refused when it
    /// sits in a block's interior; a selection is refused when it overlaps any
    /// existing block's `outerRange` at all — reaching into one, running out of
    /// one, or swallowing one whole. `blocks(in:)` has no notion of nesting, so
    /// a block caught inside a new outer fence would have its own opener and
    /// closer re-paired against that fence rather than each other.
    static func resolve(
        insertedText: String,
        in text: String,
        selectedRange: NSRange
    ) -> FenceEditAction {
        guard insertedText == "`" else { return .none }
        let ns = text as NSString
        guard isValid(selectedRange, in: ns) else { return .none }
        // Exactly two backticks before the caret: keystroke one paired, two
        // stepped over, and this is the third.
        guard backtickRunLength(before: selectedRange.location, in: ns) == 2 else {
            return .none
        }
        guard block(containing: selectedRange.location, in: text) == nil else {
            return .none
        }

        if selectedRange.length == 0 {
            return .openBlock
        }
        // A caret can only ever be inside one block or outside them all, but a
        // selection is a span: it can start clear of every block and still run
        // into one, out of one, or straight over one. Wrapping any of those
        // hands the enclosed block's fence lines to the new outer fence, so
        // refuse on any overlap at all rather than only on where it starts.
        guard !blocks(in: text).contains(where: {
            NSIntersectionRange($0.outerRange, selectedRange).length > 0
        }) else {
            return .none
        }
        // Wrapping already ran twice, so the selection is flanked by exactly
        // two backticks on each side by the time the third keystroke lands.
        guard backtickRunLength(after: NSMaxRange(selectedRange), in: ns) == 2 else {
            return .none
        }
        return .wrapSelection
    }

    /// The block whose interior contains `location`, if any. The interior
    /// starts at the end of the opening fence's backticks — so the whole
    /// info-string slot counts as inside, including a caret parked part-way
    /// through a language tag the author is still typing — and ends at the
    /// start of the closing fence.
    static func block(containing location: Int, in text: String) -> FencedBlock? {
        blocks(in: text).first { block in
            let lower = block.infoRange.location
            let upper = block.closeFenceRange?.location ?? NSMaxRange(block.outerRange)
            return location >= lower && location <= upper
        }
    }

    /// How many auto-paired backticks sit immediately after `location`, capped
    /// at two.
    ///
    /// Whether a pending closer exists depends on what preceded the run.
    /// From an empty line the keystrokes go pair → step-over, leaving `` `` ``
    /// with nothing after the caret. After a word the first backtick resolves
    /// `.native` (the preceding character is identifier-like) and the second
    /// pairs, leaving a closer parked after the caret. Opening a block has to
    /// swallow that closer or it survives as a stray backtick below the box.
    static func trailingBacktickRun(at location: Int, in text: String) -> Int {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return 0 }
        return min(2, backtickRunLength(after: location, in: ns))
    }

    private static func backtickRunLength(before location: Int, in ns: NSString) -> Int {
        var cursor = location
        var count = 0
        while cursor > 0, cursor <= ns.length, ns.character(at: cursor - 1) == backtick {
            cursor -= 1
            count += 1
        }
        return count
    }

    private static func backtickRunLength(after location: Int, in ns: NSString) -> Int {
        var cursor = location
        var count = 0
        while cursor >= 0, cursor < ns.length, ns.character(at: cursor) == backtick {
            cursor += 1
            count += 1
        }
        return count
    }

    private static func isValid(_ range: NSRange, in ns: NSString) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= ns.length
            && range.length <= ns.length - range.location
    }
}
