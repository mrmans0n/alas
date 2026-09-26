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
    /// Chips references in rendered inline markdown. Backticks are gone by
    /// now, so inline code is recognised via the `NSInlinePresentationIntent`
    /// code-span bit the renderer leaves on the attributed string — not by
    /// font, since a user's chat font can itself be monospaced. Linked text
    /// keeps its link.
    @MainActor
    @discardableResult
    static func chipifyRendered(_ rendered: NSMutableAttributedString, chipping: ACPUpstreamReferenceChipping) -> Int {
        chipify(rendered, host: chipping.host, store: chipping.store, excluding: { range in
            let attributes = rendered.attributes(at: range.location, effectiveRange: nil)
            if attributes[.link] != nil { return true }
            return ACPMarkdownInlineRenderer.isInlineCode(attributes)
        })
    }
}
