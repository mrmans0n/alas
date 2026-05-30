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
    /// emits each mention as an inline `@displayName ` marker in the text
    /// AND a matching attachment, then `ACPSessionRunner.blocks` lays that
    /// out as a single `.text` block followed by one `.resourceLink` per
    /// attachment. A naive map that keeps the text marker *and* adds a chip
    /// would double every mention on resubmit, so the markers must be
    /// stripped — but only the ones `extract` actually produced.
    ///
    /// `insertMention` always *appends* the chip to the end of the
    /// composer, so `extract` emits the markers as a contiguous trailing
    /// run in attachment order: `…userText@a @b `. We therefore strip that
    /// exact trailing run positionally, never by first textual occurrence —
    /// the latter would mis-claim a literal `@name` the user typed earlier
    /// (e.g. "ping @here and @File.swift" with an attachment named here).
    /// Blocks that don't end in the canonical run (agent-sourced items,
    /// images, or hand-edited text) keep their text verbatim and append the
    /// links as chips so nothing is dropped.
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

    /// Reconstruct segments from the flat `(text, links)` pair, stripping
    /// the trailing `@name ` marker run that `extract` appends (see
    /// `init(blocks:)`) and emitting a chip per link. Falls back to
    /// text-then-chips when the canonical run isn't present so a literal
    /// `@name` earlier in the prose is never consumed.
    private static func rebuild(text: String, links: [(name: String, uri: String)]) -> [Segment] {
        guard !links.isEmpty else {
            return text.isEmpty ? [] : [.text(text)]
        }
        let chips = links.map { Segment.mention(displayName: $0.name, uri: $0.uri) }
        let markerRun = links.map { "@\($0.name) " }.joined()
        if text.hasSuffix(markerRun) {
            let prefix = String(text.dropLast(markerRun.count))
            return (prefix.isEmpty ? [] : [.text(prefix)]) + chips
        }
        return (text.isEmpty ? [] : [.text(text)]) + chips
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
