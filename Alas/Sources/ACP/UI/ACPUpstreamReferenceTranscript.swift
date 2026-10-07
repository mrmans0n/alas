import AppKit
import SwiftUI

/// Chip rendering switched on for one subtree. Only user messages set it,
/// so agent prose never gets chips.
struct ACPUpstreamReferenceChipping: Equatable, Sendable {
    let store: ACPUpstreamReferenceStore
    let host: CodeHostKind

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.host == rhs.host
    }
}

private struct ACPUpstreamReferenceStoreKey: EnvironmentKey {
    static let defaultValue: ACPUpstreamReferenceStore? = nil
}

private struct ACPUpstreamReferenceChippingKey: EnvironmentKey {
    static let defaultValue: ACPUpstreamReferenceChipping? = nil
}

extension EnvironmentValues {
    /// The worktree's reference store, re-injected into each hosted
    /// transcript row by `ACPTranscriptScroller.wrapRow`.
    var acpUpstreamReferenceStore: ACPUpstreamReferenceStore? {
        get { self[ACPUpstreamReferenceStoreKey.self] }
        set { self[ACPUpstreamReferenceStoreKey.self] = newValue }
    }

    var acpUpstreamReferenceChipping: ACPUpstreamReferenceChipping? {
        get { self[ACPUpstreamReferenceChippingKey.self] }
        set { self[ACPUpstreamReferenceChippingKey.self] = newValue }
    }
}

extension ACPUpstreamReferenceChip {
    /// References represented by badges in a submitted user message, in
    /// display order. Use the same block and inline renderers as the bubble
    /// so code and linked text do not create misleading summary rows.
    @MainActor
    static func summaryReferences(in text: String, host: CodeHostKind, theme: Theme) -> [CodeHostReference] {
        var seen: Set<CodeHostReference> = []
        var references: [CodeHostReference] = []

        for block in ACPMarkdownText.parse(text) {
            let fragments: [String] = switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): [text]
            case .taskList(let items): items.map(\.text)
            case .table(let header, let rows): header + rows.flatMap { $0 }
            case .code, .streamingCode, .mermaid, .image: []
            }
            for fragment in fragments {
                let rendered = ACPMarkdownInlineRenderer.makeAttributedString(
                    source: fragment, theme: theme, typography: .default, role: .body
                )
                for match in ACPUpstreamReferenceDetector.references(in: rendered.string, host: host)
                where isVisibleReference(in: rendered, range: match.range) && seen.insert(match.reference).inserted {
                    references.append(match.reference)
                }
            }
        }
        return references
    }

    @MainActor
    private static func isVisibleReference(in rendered: NSAttributedString, range: NSRange) -> Bool {
        let attributes = rendered.attributes(at: range.location, effectiveRange: nil)
        return attributes[.link] == nil && !ACPMarkdownInlineRenderer.isInlineCode(attributes)
    }

    /// Chips references in rendered inline markdown. Backticks are gone by
    /// now, so inline code is recognised via the `NSInlinePresentationIntent`
    /// code-span bit the renderer leaves on the attributed string — not by
    /// font, since a user's chat font can itself be monospaced. Linked text
    /// keeps its link.
    @MainActor
    @discardableResult
    static func chipifyRendered(_ rendered: NSMutableAttributedString, chipping: ACPUpstreamReferenceChipping) -> Int {
        chipify(rendered, host: chipping.host, store: chipping.store, excluding: { range in
            !isVisibleReference(in: rendered, range: range)
        })
    }
}
