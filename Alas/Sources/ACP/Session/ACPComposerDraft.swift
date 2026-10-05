import Foundation

struct ACPComposerDraft: Codable, Equatable, Sendable {
    var segments: [Segment]

    static let empty = ACPComposerDraft(segments: [])

    var isEmpty: Bool {
        segments.allSatisfy { segment in
            switch segment {
            case .text(let value):
                value.isEmpty
            case .mention, .image, .upstreamReference, .pastedText:
                false
            }
        }
    }

    /// True when the draft has non-whitespace text or pasted text, or any
    /// other chip. Distinct from `isEmpty` (which is strictly structural) —
    /// use this when deciding whether the user has typed something
    /// meaningful. A whitespace-only paste is not content: submit trims it
    /// away and would silently refuse.
    var hasContent: Bool {
        segments.contains { segment in
            switch segment {
            case .text(let value), .pastedText(_, let value):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .mention, .image, .upstreamReference:
                return true
            }
        }
    }

    /// Human-readable text for the clipboard: mention and upstream
    /// reference chips spell out their text, command chips already use
    /// `/command`, and images drop out instead of leaking U+FFFC.
    /// A mention may abut following text in restored drafts, so insert a
    /// separating space rather than concatenate `@File.swiftright here`.
    var plainText: String {
        var result = ""
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let value):
                result += value
            case .upstreamReference(let reference):
                result += reference.spelling
            case .pastedText(_, let content):
                result += content
            case .mention(let displayName, _):
                result += "@" + displayName
                if !nextSegmentStartsWithWhitespace(after: index) {
                    result += " "
                }
            case .image:
                break
            }
        }
        return result
    }

    /// Whether the segment right after `index` opens with whitespace (or
    /// there's nothing after it, needing no separator). An `.image` segment
    /// contributes no text of its own, so it defers to whatever comes after
    /// it in turn.
    private func nextSegmentStartsWithWhitespace(after index: Int) -> Bool {
        var next = index + 1
        while next < segments.count {
            switch segments[next] {
            case .text(let value):
                return value.first?.isWhitespace ?? false
            case .pastedText(_, let content):
                return content.first?.isWhitespace ?? false
            case .mention, .upstreamReference:
                return false
            case .image:
                next += 1
            }
        }
        return true
    }

    /// Character offset, into the flattened message text, of each `.image`
    /// segment in order. `.text` and `.pastedText` contribute their literal
    /// characters, `.mention` contributes `"@displayName "`,
    /// `.upstreamReference` contributes its spelling, and `.image`
    /// contributes nothing. Used to attach `textOffset` to each recorded
    /// image attachment so the transcript marks its position. Returns early
    /// without images, so a large paste is never walked by grapheme for
    /// nothing.
    func imageTextOffsets() -> [Int] {
        guard segments.contains(where: { if case .image = $0 { true } else { false } }) else { return [] }
        var offset = 0
        var offsets: [Int] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                offset += value.count
            case .mention(let displayName, _):
                offset += ("@" + displayName + " ").count
            case .upstreamReference(let reference):
                offset += reference.spelling.count
            case .pastedText(_, let content):
                offset += content.count
            case .image:
                offsets.append(offset)
            }
        }
        return offsets
    }

    /// UTF-16 span of each `.pastedText` segment inside `text`, the message
    /// text `ACPInputField.Coordinator.extract` produced from this draft.
    /// Each segment advances the offset by what `extract` writes for it.
    /// Returns `[]` unless every span's slice of `text` equals its segment's
    /// content, so a send path that changed the text records no badges
    /// instead of wrong ones.
    func pastedTextSpans(matching text: String) -> [ACPPastedTextSpan] {
        var offset = 0
        var spans: [ACPPastedTextSpan] = []
        var contents: [String] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                offset += value.utf16.count
            case .mention(let displayName, _):
                offset += ("@" + displayName + " ").utf16.count
            case .upstreamReference(let reference):
                offset += reference.spelling.utf16.count
            case .image:
                break
            case .pastedText(let ordinal, let content):
                let length = content.utf16.count
                spans.append(ACPPastedTextSpan(ordinal: ordinal, utf16Offset: offset, utf16Length: length))
                contents.append(content)
                offset += length
            }
        }
        guard !spans.isEmpty else { return [] }
        let source = text as NSString
        for (span, content) in zip(spans, contents) {
            guard NSMaxRange(span.utf16Range) <= source.length,
                  source.compare(content, options: .literal, range: span.utf16Range) == .orderedSame
            else { return [] }
        }
        return spans
    }

    /// This draft with every `.pastedText` ordinal found in `taken` moved to
    /// a fresh number above all ordinals in use, so a pasted copy never
    /// shows the same "#N" as a badge already in the composer.
    func renumberingPastedText(avoiding taken: Set<Int>) -> ACPComposerDraft {
        let own = segments.compactMap { segment -> Int? in
            if case .pastedText(let ordinal, _) = segment { return ordinal }
            return nil
        }
        guard own.contains(where: taken.contains) else { return self }
        var next = (taken.union(own).max() ?? 0) + 1
        var used = taken
        return ACPComposerDraft(segments: segments.map { segment in
            guard case .pastedText(let ordinal, let content) = segment else { return segment }
            if used.insert(ordinal).inserted { return segment }
            defer { next += 1 }
            return .pastedText(ordinal: next, content: content)
        })
    }

    enum Segment: Codable, Equatable, Sendable {
        case text(String)
        case mention(displayName: String, uri: String)
        case image(uri: String, mimeType: String)
        /// A reference already represented by a composer chip. Plain
        /// references remain `.text` so restoration can retain the caret guard.
        case upstreamReference(CodeHostReference)
        /// A paste collapsed into a badge. `content` is sent verbatim in
        /// place of the chip; `ordinal` is the "#N" the badge shows.
        case pastedText(ordinal: Int, content: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case displayName
            case uri
            case mimeType
            case spelling
            case ordinal
        }

        private enum SegmentType: String, Codable, Sendable {
            case text
            case mention
            case image
            case upstreamReference
            case pastedText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(SegmentType.self, forKey: .type)
            switch type {
            case .text:
                self = .text(try container.decode(String.self, forKey: .text))
            case .mention:
                self = .mention(
                    displayName: try container.decode(String.self, forKey: .displayName),
                    uri: try container.decode(String.self, forKey: .uri)
                )
            case .image:
                self = .image(
                    uri: try container.decode(String.self, forKey: .uri),
                    mimeType: try container.decode(String.self, forKey: .mimeType))
            case .upstreamReference:
                let spelling = try container.decode(String.self, forKey: .spelling)
                guard let reference = CodeHostReference(spelling: spelling) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .spelling,
                        in: container,
                        debugDescription: "Invalid upstream reference spelling."
                    )
                }
                self = .upstreamReference(reference)
            case .pastedText:
                self = .pastedText(
                    ordinal: try container.decode(Int.self, forKey: .ordinal),
                    content: try container.decode(String.self, forKey: .text))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let value):
                try container.encode(SegmentType.text, forKey: .type)
                try container.encode(value, forKey: .text)
            case .mention(let displayName, let uri):
                try container.encode(SegmentType.mention, forKey: .type)
                try container.encode(displayName, forKey: .displayName)
                try container.encode(uri, forKey: .uri)
            case .image(let uri, let mimeType):
                try container.encode(SegmentType.image, forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(mimeType, forKey: .mimeType)
            case .upstreamReference(let reference):
                try container.encode(SegmentType.upstreamReference, forKey: .type)
                try container.encode(reference.spelling, forKey: .spelling)
            case .pastedText(let ordinal, let content):
                try container.encode(SegmentType.pastedText, forKey: .type)
                try container.encode(ordinal, forKey: .ordinal)
                try container.encode(content, forKey: .text)
            }
        }
    }
}

extension ACPComposerDraft {
    func matchesPersistedUserPrompt(text: String, attachments: [ACPMessage.Attachment]) -> Bool {
        normalizedPromptBlocks == Self.contentBlocks(
            text: text,
            attachments: attachments.filter { !$0.isCheckpointReference }
        )
    }

    func matchesRecordedQueuedPrompt(in queue: [QueuedPrompt]) -> Bool {
        queue.contains { item in
            item.transcriptRecorded && self == item.restorableDraft
        }
    }

    private var normalizedPromptBlocks: [ACPContentBlock] {
        var text = ""
        var attachments: [ACPMessage.Attachment] = []
        for segment in segments {
            switch segment {
            case .text(let value):
                text += value
            case .upstreamReference(let reference):
                text += reference.spelling
            case .pastedText(_, let content):
                text += content
            case .mention(let displayName, let uri):
                text += "@\(displayName) "
                attachments.append(.init(uri: uri, name: displayName))
            case .image(let uri, let mimeType):
                attachments.append(.init(
                    uri: uri,
                    name: Self.displayName(forURI: uri),
                    mimeType: mimeType))
            }
        }
        return Self.contentBlocks(text: text, attachments: attachments)
    }

    func matchesSubmittedRecoveryPrompt(
        seq: Int64,
        text: String,
        attachments: [ACPMessage.Attachment],
        queue: [QueuedPrompt],
        submittedAfterSeq: Int64?
    ) -> Bool {
        seq > (submittedAfterSeq ?? -1)
            && !matchesRecordedQueuedPrompt(in: queue)
            && matchesPersistedUserPrompt(text: text, attachments: attachments)
    }

    // Keep this isolation-free for hydration, which runs off the main actor.
    // It mirrors ACPSessionRunner.blocks without pulling the runner into the
    // persistence path.
    private static func contentBlocks(
        text: String,
        attachments: [ACPMessage.Attachment]
    ) -> [ACPContentBlock] {
        var blocks: [ACPContentBlock] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [.text(text)]
        for attachment in attachments {
            if let mimeType = attachment.mimeType, mimeType.hasPrefix("image/") {
                blocks.append(.image(data: nil, uri: attachment.uri, mimeType: mimeType))
            } else {
                blocks.append(.resourceLink(uri: attachment.uri, name: attachment.name))
            }
        }
        return blocks
    }

    /// Rebuild an editable draft from a queued prompt's content blocks —
    /// the inverse of the submit path's draft→blocks serialization. Used
    /// when the user clicks "edit" on a queued item to pull it back into
    /// the composer.
    ///
    /// The submit path is asymmetric: `ACPInputField.Coordinator.extract`
    /// emits each mention as an inline `@displayName ` marker AT THE CHIP'S
    /// POSITION in the text AND a matching attachment, then
    /// `ACPSessionRunner.blocks` lays that out as a single `.text` block
    /// followed by one `.resourceLink` per attachment. A mention can sit
    /// anywhere — `insertMention` drops the chip in, then the user keeps
    /// typing — so the inverse must restore each chip IN PLACE, not just at
    /// the tail. We walk the links in `extract`'s order and replace each
    /// one's `@name ` marker, scanning forward from the previous match.
    ///
    /// This is a heuristic inverse of a LOSSY serialization: once a chip
    /// becomes `@name ` text it is indistinguishable from a literal `@name`
    /// the user typed. If the user both typed a literal `@File.swift` and
    /// attached File.swift, the forward scan may claim the literal first —
    /// a rare edge that still yields a valid chip with the correct uri, and
    /// the lesser evil versus duplicating/mispositioning every ordinary
    /// mid-text mention (the common case). Links whose marker can't be
    /// found are appended as chips so nothing is dropped.
    ///
    /// Declared in an extension so the compiler keeps synthesizing the
    /// memberwise `init(segments:)` that the rest of the codebase relies on.
    init(blocks: [ACPContentBlock]) {
        var segments: [Segment] = []
        var text = ""
        var links: [(name: String, uri: String)] = []
        for block in blocks {
            switch block {
            case .text(let value):
                text += value
            case .resourceLink(let uri, let name):
                links.append((name ?? Self.displayName(forURI: uri), uri))
            case .resource(let uri, _, _):
                links.append((Self.displayName(forURI: uri), uri))
            case .image(_, let uri, let mimeType):
                if let uri {
                    segments.append(contentsOf: Self.rebuild(text: text, links: links))
                    text = ""
                    links = []
                    segments.append(.image(uri: uri, mimeType: mimeType ?? "image/png"))
                }
            }
        }
        segments.append(contentsOf: Self.rebuild(text: text, links: links))
        self.segments = segments
    }

    private static func displayName(forURI uri: String) -> String {
        let last = URL(string: uri)?.lastPathComponent
        return (last?.isEmpty == false ? last : nil) ?? uri
    }

    /// Reconstruct segments from the flat `(text, links)` pair by replacing
    /// each link's `@name ` marker (in `extract`'s attachment order,
    /// scanning forward) with its mention chip, preserving inline
    /// positions. See `init(blocks:)` for the lossy-serialization caveat.
    private static func rebuild(text: String, links: [(name: String, uri: String)]) -> [Segment] {
        guard !links.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }
        var segments: [Segment] = []
        var remaining = Substring(text)
        var unmatched: [(name: String, uri: String)] = []
        for link in links {
            if let range = remaining.range(of: "@\(link.name) ") {
                let before = remaining[remaining.startIndex..<range.lowerBound]
                if !before.isEmpty { segments.append(.text(String(before))) }
                segments.append(.mention(displayName: link.name, uri: link.uri))
                remaining = remaining[range.upperBound...]
            } else {
                unmatched.append(link)
            }
        }
        if !remaining.isEmpty { segments.append(.text(String(remaining))) }
        for link in unmatched {
            segments.append(.mention(displayName: link.name, uri: link.uri))
        }
        return segments
    }

    /// Concatenate `other` onto this draft, separated by a newline when
    /// both sides carry content, so restoring a queued item never clobbers
    /// text the user has already typed. Appending onto (or of) an empty
    /// draft just returns the non-empty side unchanged. Pasted-text badges
    /// in `other` that reuse a number already in this draft are renumbered,
    /// so the result never shows two "#1" badges or repeats a span ordinal.
    func appending(_ other: ACPComposerDraft) -> ACPComposerDraft {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let taken = Set(segments.compactMap { segment -> Int? in
            if case .pastedText(let ordinal, _) = segment { return ordinal }
            return nil
        })
        return ACPComposerDraft(
            segments: segments + [.text("\n")] + other.renumberingPastedText(avoiding: taken).segments
        )
    }
}
