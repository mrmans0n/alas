import Foundation

/// One chip in a remote viewer's composer: what it shows, and what it sends
/// in its place.
public enum RemoteDraftChip: Equatable, Hashable, Sendable {
    /// A known slash command, `/` included.
    case command(String)
    case mention(RemoteMention)
    case reference(CodeHostReference)
    /// A collapsed paste; `ordinal` is the `#N` its label shows.
    case pasted(ordinal: Int, text: String)

    /// The text the chip sends in its place.
    public var spelling: String {
        switch self {
        case .command(let name): name
        case .mention(let mention): "@" + mention.name
        case .reference(let reference): reference.spelling
        case .pasted(_, let text): text
        }
    }
}

public enum RemoteDraftSegment: Equatable, Sendable {
    case text(String)
    case chip(RemoteDraftChip)
}

/// What a remote viewer is composing: text runs and chips, in order. What
/// `sendPrompt` sends is computed from it, so a mention goes out exactly
/// while its chip is in the draft.
public struct RemoteComposerDraft: Equatable, Sendable {
    public var segments: [RemoteDraftSegment]

    public init(segments: [RemoteDraftSegment] = []) {
        self.segments = segments
    }

    /// The prompt text: each chip spelled out. A mention directly followed
    /// by more than whitespace gets a separating space, as on the Mac.
    public var text: String { serialized.text }

    /// Where each collapsed paste sits in `text`, in UTF-16 units.
    public var pastedSpans: [ACPPastedTextSpan] { serialized.spans }

    /// The mentions to send, in order, each once.
    public var mentions: [RemoteMention] {
        var seen = Set<RemoteMention>()
        return segments.compactMap { segment in
            guard case .chip(.mention(let mention)) = segment, seen.insert(mention).inserted else { return nil }
            return mention
        }
    }

    /// Non-whitespace text, or a chip that sends something.
    public var hasContent: Bool {
        segments.contains { segment in
            switch segment {
            case .text(let value), .chip(.pasted(_, let value)):
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .chip:
                true
            }
        }
    }

    public var isEmpty: Bool {
        segments.allSatisfy { if case .text(let value) = $0 { value.isEmpty } else { false } }
    }

    /// The `#N` of every pasted chip, so a new paste takes the next number.
    public var pastedOrdinals: Set<Int> {
        Set(segments.compactMap { if case .chip(.pasted(let ordinal, _)) = $0 { ordinal } else { nil } })
    }

    /// `other` after this draft, on a new line when both have content: how a
    /// refused prompt comes back ahead of what was typed since.
    public func appending(_ other: RemoteComposerDraft) -> RemoteComposerDraft {
        guard !isEmpty else { return other }
        guard !other.isEmpty else { return self }
        return RemoteComposerDraft(segments: segments + [.text("\n")] + other.segments).merged
    }

    /// Adjacent text runs joined and empty ones dropped.
    public var merged: RemoteComposerDraft {
        var result: [RemoteDraftSegment] = []
        for segment in segments {
            if case .text(let value) = segment {
                guard !value.isEmpty else { continue }
                if case .text(let previous)? = result.last {
                    result[result.count - 1] = .text(previous + value)
                    continue
                }
            }
            result.append(segment)
        }
        return RemoteComposerDraft(segments: result)
    }

    /// The text an editor shows: each chip as one attachment character
    /// (U+FFFC). Editor offsets, carets and the `/` and `@` token rules work
    /// in these units.
    public var displayText: String {
        segments.map { if case .text(let value) = $0 { value } else { Self.attachmentCharacter } }.joined()
    }

    public static let attachmentCharacter = "\u{FFFC}"

    /// This draft with `range` of `displayText` replaced by `replacement`.
    /// A range that ends inside a text run splits it; chips are whole.
    public func replacing(_ range: NSRange, with replacement: [RemoteDraftSegment]) -> RemoteComposerDraft {
        let (before, rest) = split(at: range.location)
        let (_, after) = RemoteComposerDraft(segments: rest).split(at: range.length)
        return RemoteComposerDraft(segments: before + replacement + after).merged
    }

    /// `range` of `displayText` as the text it sends, for the clipboard.
    public func spelled(_ range: NSRange) -> String {
        let (_, rest) = split(at: range.location)
        return RemoteComposerDraft(segments: RemoteComposerDraft(segments: rest).split(at: range.length).0).text
    }

    /// The segments before and from `offset` of `displayText`.
    private func split(at offset: Int) -> ([RemoteDraftSegment], [RemoteDraftSegment]) {
        var before: [RemoteDraftSegment] = []
        var remaining = offset
        for (index, segment) in segments.enumerated() {
            guard remaining > 0 else { return (before, Array(segments[index...])) }
            switch segment {
            case .text(let value):
                let length = value.utf16.count
                if remaining >= length {
                    before.append(segment)
                    remaining -= length
                } else {
                    let string = value as NSString
                    before.append(.text(string.substring(to: remaining)))
                    return (before, [.text(string.substring(from: remaining))] + segments[(index + 1)...])
                }
            case .chip:
                before.append(segment)
                remaining -= 1
            }
        }
        return (before, [])
    }

    private var serialized: (text: String, spans: [ACPPastedTextSpan]) {
        var text = ""
        var length = 0
        var spans: [ACPPastedTextSpan] = []
        for (index, segment) in segments.enumerated() {
            let piece: String
            switch segment {
            case .text(let value):
                piece = value
            case .chip(.pasted(let ordinal, let content)):
                spans.append(ACPPastedTextSpan(ordinal: ordinal, utf16Offset: length, utf16Length: content.utf16.count))
                piece = content
            case .chip(.mention(let mention)):
                piece = "@" + mention.name + (startsWithWhitespace(after: index) ? "" : " ")
            case .chip(let chip):
                piece = chip.spelling
            }
            text += piece
            length += piece.utf16.count
        }
        return (text, spans)
    }

    private func startsWithWhitespace(after index: Int) -> Bool {
        guard index + 1 < segments.count else { return true }
        switch segments[index + 1] {
        case .text(let value), .chip(.pasted(_, let value)): return value.first?.isWhitespace ?? true
        case .chip: return false
        }
    }

    /// A draft rebuilt from plain text, as a refused or edited prompt comes
    /// back: known commands and references on completed tokens become chips.
    /// A token ending at `caret` stays text, since the user may still be
    /// typing it; a nil `caret` means the text is final.
    public static func restoring(
        _ text: String, commands: [String], codeHost: CodeHostKind?, caret: Int?
    ) -> RemoteComposerDraft {
        let commandTargets = SlashCommandText.chipTargets(in: caret == nil ? text + " " : text, commands: commands)
            .map { (range: $0.range, chip: RemoteDraftChip.command($0.command)) }
        let referenceTargets = codeHost.map { host in
            UpstreamReferenceText.chippableMatches(
                in: text, host: host, caret: caret.map { NSRange(location: $0, length: 0) }
            ).map { (range: $0.range, chip: RemoteDraftChip.reference($0.reference)) }
        } ?? []
        return RemoteComposerDraft(segments: slice(text, at: commandTargets + referenceTargets))
    }

    /// The segments a paste of `pasted` at `range` of `current` becomes: one
    /// pasted chip when it is long, otherwise its text with known commands,
    /// references and same-repository PR/MR/issue URLs as chips. The text
    /// around `range` decides whether the paste's edges are token boundaries.
    public static func pasteSegments(
        _ pasted: String, replacing range: NSRange, in current: String,
        commands: [String], codeHost: RemoteCodeHost?, nextOrdinal: Int
    ) -> [RemoteDraftSegment] {
        if ACPPastedTextPolicy.shouldCollapse(pasted) {
            return [.chip(.pasted(ordinal: nextOrdinal, text: pasted))]
        }
        let string = current as NSString
        let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : nil
        let after: unichar? = NSMaxRange(range) < string.length ? string.character(at: NSMaxRange(range)) : nil
        var targets = SlashCommandText.chipTargets(inFragment: pasted, replacing: range, in: current, commands: commands)
            .map { (range: $0.range, chip: RemoteDraftChip.command($0.command)) }
        if let codeHost, !isInCode(range.location, in: string) {
            // The two characters before the paste are scanned with it, so a URL
            // pasted as a link target (after `](`) stays a URL.
            let contextStart = max(0, range.location - 2)
            let context = string.substring(with: NSRange(location: contextStart, length: range.location - contextStart))
            let contextLength = (context as NSString).length
            let urls = UpstreamReferenceText.urlReferences(
                in: context + pasted, repository: codeHost,
                precededBy: contextStart > 0 ? string.character(at: contextStart - 1) : nil, followedBy: after
            ).compactMap { match in
                match.range.location < contextLength ? nil : UpstreamReferenceText.Match(
                    range: NSRange(location: match.range.location - contextLength, length: match.range.length),
                    reference: match.reference)
            }
            let tokens = UpstreamReferenceText.references(in: pasted, host: codeHost.kind, precededBy: before, followedBy: after)
            targets += (urls + tokens).map { (range: $0.range, chip: RemoteDraftChip.reference($0.reference)) }
        }
        return slice(pasted, at: targets)
    }

    /// Whether a paste at `location` lands in code: an inline span still open
    /// there, as the Mac's paste checks, or a fenced block.
    private static func isInCode(_ location: Int, in string: NSString) -> Bool {
        let prefix = string.substring(to: location) as NSString
        // A run left open through the caret shows up only in the scan that extends it.
        if UpstreamReferenceText.codeRanges(in: prefix, unclosedRunsExtendToEnd: true).count
            > UpstreamReferenceText.codeRanges(in: prefix, unclosedRunsExtendToEnd: false).count { return true }
        return MarkdownFenceEditing.blocks(in: string as String).contains {
            location > $0.outerRange.location && location < NSMaxRange($0.outerRange)
        }
    }

    /// `text` cut into text runs and chips at `targets`, which may overlap:
    /// the earlier, then longer, wins.
    private static func slice(_ text: String, at targets: [(range: NSRange, chip: RemoteDraftChip)]) -> [RemoteDraftSegment] {
        let source = text as NSString
        var segments: [RemoteDraftSegment] = []
        var cursor = 0
        let ordered = targets.sorted {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
        for target in ordered where target.range.location >= cursor {
            if target.range.location > cursor {
                segments.append(.text(source.substring(with: NSRange(location: cursor, length: target.range.location - cursor))))
            }
            segments.append(.chip(target.chip))
            cursor = NSMaxRange(target.range)
        }
        if cursor < source.length { segments.append(.text(source.substring(from: cursor))) }
        return segments
    }
}
