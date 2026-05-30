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
    /// the composer. Resource links (and images) become mention chips so
    /// nothing is silently dropped on restore; a link without a name falls
    /// back to its uri's last path component, then the raw uri.
    ///
    /// Declared in an extension so the compiler keeps synthesizing the
    /// memberwise `init(segments:)` that the rest of the codebase relies on.
    init(blocks: [ACPContentBlock]) {
        self.segments = blocks.map { block in
            switch block {
            case .text(let value):
                return .text(value)
            case .resourceLink(let uri, let name):
                return .mention(displayName: name ?? Self.displayName(forURI: uri), uri: uri)
            case .image(let uri, _):
                return .mention(displayName: Self.displayName(forURI: uri), uri: uri)
            }
        }
    }

    private static func displayName(forURI uri: String) -> String {
        let last = URL(string: uri)?.lastPathComponent
        return (last?.isEmpty == false ? last : nil) ?? uri
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
