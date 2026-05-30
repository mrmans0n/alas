import Foundation

struct ACPComposerDraft: Codable, Equatable {
    var segments: [Segment]

    static let empty = ACPComposerDraft(segments: [])

    var isEmpty: Bool {
        segments.allSatisfy { segment in
            switch segment {
            case .text(let value):
                value.isEmpty
            case .mention:
                false
            }
        }
    }

    /// True when the draft has any non-whitespace text or any mention.
    /// Distinct from `isEmpty` (which is strictly structural) — use this
    /// when deciding whether the user has typed something meaningful.
    var hasContent: Bool {
        segments.contains { segment in
            switch segment {
            case .text(let value):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .mention:
                return true
            }
        }
    }

    enum Segment: Codable, Equatable {
        case text(String)
        case mention(displayName: String, uri: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case displayName
            case uri
        }

        private enum SegmentType: String, Codable {
            case text
            case mention
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
            }
        }
    }
}

extension ACPComposerDraft {
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
        var text = ""
        var links: [(name: String, uri: String)] = []
        for block in blocks {
            switch block {
            case .text(let value):
                text += value
            case .resourceLink(let uri, let name):
                links.append((name ?? Self.displayName(forURI: uri), uri))
            case .image(let uri, _):
                links.append((Self.displayName(forURI: uri), uri))
            }
        }
        self.segments = Self.rebuild(text: text, links: links)
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
    /// draft just returns the non-empty side unchanged.
    func appending(_ other: ACPComposerDraft) -> ACPComposerDraft {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return ACPComposerDraft(segments: segments + [.text("\n")] + other.segments)
    }
}
