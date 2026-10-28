import Foundation
import CoreGraphics

/// What an action could have changed in the target window, read right before and after it.
public struct ComputerUseWindowFingerprint: Equatable, Sendable {
    /// The app's focused element, as far as it could be read.
    public struct Focus: Equatable, Sendable {
        public var role: String
        public var title: String?
        public var valueHash: Int?
        /// Location and length of the selected text, when the element has one.
        public var selectedRange: [Int]?

        public init(role: String, title: String? = nil, valueHash: Int? = nil, selectedRange: [Int]? = nil) {
            self.role = role
            self.title = title
            self.valueHash = valueHash
            self.selectedRange = selectedRange
        }
    }

    /// Nil when nothing has focus or the focus couldn't be read.
    public var focus: Focus?
    public var windowTitle: String?
    /// `ComputerUseChangeCheck.elementsHash` of the element list (up to the change check's own
    /// budget, not the call's listing limit); nil when the read failed, was cut short (node
    /// budget, deadline), left elements out for depth, or listed more elements than that budget,
    /// since elements past the cut may have changed.
    public var elementsHash: Int?
    /// The acted-on element's own state (value, selection, enabled, title); nil without one.
    public var targetHash: Int?
    /// `elementsHash` without which element has focus (`ComputerUseChangeCheck.elementsHash(_:focus:)`),
    /// nil when `elementsHash` is: tells a window whose focus or selection alone moved.
    public var contentHash: Int?
    /// `ComputerUseChangeCheck.prefixHashes` of the read, complete or not: how a drag in a window
    /// too large for `elementsHash` can still show it changed something. Nil when the read can't
    /// be compared that way.
    public var prefixHashes: [Int]?

    public init(
        focus: Focus? = nil, windowTitle: String? = nil, elementsHash: Int? = nil, targetHash: Int? = nil,
        contentHash: Int? = nil, prefixHashes: [Int]? = nil
    ) {
        self.focus = focus
        self.windowTitle = windowTitle
        self.elementsHash = elementsHash
        self.targetHash = targetHash
        self.contentHash = contentHash
        self.prefixHashes = prefixHashes
    }

    /// The fingerprint as the complete-read comparisons see it.
    var withoutPrefix: Self {
        var copy = self
        copy.prefixHashes = nil
        return copy
    }
}

/// Apps may accept an input and ignore it; an action that changed nothing says so.
public enum ComputerUseChangeCheck {
    /// The input the check ran for.
    public enum Kind: Sendable { case click, type, key, scroll, drag }

    public static let noChangeWarning =
        "No change was observed in the window after this action; the app may have ignored it."
    public static let retryDirectHint = #" Retry with delivery: "direct"."#
    public static let dragWarning = "Couldn't confirm the drag had an effect; inspect to verify."

    /// The warning for an action whose window looks the same after it, else nil. Without both
    /// complete element lists the check can't tell, so it doesn't warn, except after a drag: a
    /// cut-short read is how a drag that did nothing looked like one that worked, unless the
    /// reads' first elements (`prefixChanged`) show it changed something. A drag that
    /// moved only focus and selection (the activation or the press selected the item it grabbed,
    /// and nothing was dropped) warns too, however it went. The retry hint is only for clicks,
    /// scrolls and drags that went as events: a key or typed text can legitimately change nothing
    /// a read shows, and an activation already was the direct way. A drag gets it only over two
    /// complete reads: a cut-short read can't tell a drag that did nothing from one that worked,
    /// and repeating one that worked does it twice.
    public static func warning(
        before: ComputerUseWindowFingerprint?, after: ComputerUseWindowFingerprint?, kind: Kind, deliveredAsEvents: Bool
    ) -> String? {
        guard let fullBefore = before, let fullAfter = after else { return nil }
        var before = fullBefore.withoutPrefix
        var after = fullAfter.withoutPrefix
        if kind == .drag {
            let complete = before.elementsHash != nil && after.elementsHash != nil
            let warning = deliveredAsEvents && complete ? dragWarning + retryDirectHint : dragWarning
            if onlyFocusOrSelectionMoved(before, after) { return warning }
            if !complete {
                // Reads cut short only ever show a change: equal first elements say nothing of the rest.
                if prefixChanged(fullBefore.prefixHashes, fullAfter.prefixHashes) { return nil }
                before.elementsHash = nil
                after.elementsHash = nil
            }
            before.contentHash = nil
            after.contentHash = nil
            return before == after ? warning : nil
        }
        guard before.elementsHash != nil, after.elementsHash != nil, before == after else { return nil }
        let hint = deliveredAsEvents && (kind == .click || kind == .scroll)
        return hint ? noChangeWarning + retryDirectHint : noChangeWarning
    }

    /// Whether a pointer retry visibly changed the window: a complete read whose elements, title or
    /// clicked element differ from before the first press. Focus alone doesn't count, since a
    /// press that only focused is what the retry is for; a read that can't tell doesn't either.
    public static func retryChanged(before: ComputerUseWindowFingerprint, after: ComputerUseWindowFingerprint?) -> Bool {
        guard let after, before.elementsHash != nil, after.elementsHash != nil else { return false }
        return before.elementsHash != after.elementsHash || before.windowTitle != after.windowTitle
            || before.targetHash != after.targetHash
    }

    /// Both reads complete, with the same elements but for which has focus, and the same title:
    /// what differs is the focused element, the selection or the acted-on element's state.
    private static func onlyFocusOrSelectionMoved(
        _ before: ComputerUseWindowFingerprint, _ after: ComputerUseWindowFingerprint
    ) -> Bool {
        guard let content = before.contentHash, content == after.contentHash else { return false }
        return before.windowTitle == after.windowTitle
    }

    /// Per-node hashes over the first `limit` nodes of a read, in `flatten`'s pre-order and depth
    /// limit, whatever the query: what each shows but focus, and how many children it listed,
    /// which a container whose children the read cut off still tells. Nil for a read that can't
    /// be compared with another (`cut`): one with unanswered or unreadable elements in place of
    /// others shifts the order, and a web window read without its web content lacks what the app
    /// tears down after input. The node a time limit stopped the read at may be partly read, so
    /// a read cut by one leaves it out; so does any node whose attributes weren't read, and all after it.
    public static func prefixHashes(
        _ root: ComputerUseAXNode, cut: ComputerUseReadCut?, maxDepth: Int, limit: Int
    ) -> [Int]? {
        switch cut {
        case nil, .nodeBudget, .timeLimit: break
        case .appNotResponding, .elementsUnreadable, .webContentMissing: return nil
        }
        var hashes: [Int] = []
        var stopped = false
        func visit(_ node: ComputerUseAXNode, depth: Int) {
            guard !stopped, depth <= maxDepth, hashes.count < limit else { return }
            guard let childCount = node.childCount else {
                stopped = true
                return
            }
            var hasher = Hasher()
            hasher.combine(depth)
            hasher.combine(node.role)
            hasher.combine(node.subrole)
            hasher.combine(node.title)
            hasher.combine(node.value)
            hasher.combine(node.description)
            hasher.combine(node.frame.origin.x)
            hasher.combine(node.frame.origin.y)
            hasher.combine(node.frame.width)
            hasher.combine(node.frame.height)
            hasher.combine(node.isEnabled)
            hasher.combine(childCount)
            hashes.append(hasher.finalize())
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        if cut == .timeLimit, !stopped { hashes = hashes.dropLast() }
        return hashes
    }

    /// Whether two reads' `prefixHashes` differ over the nodes both read. Not knowing either, or
    /// having none in common, isn't a change.
    public static func prefixChanged(_ before: [Int]?, _ after: [Int]?) -> Bool {
        guard let before, let after else { return false }
        let common = min(before.count, after.count)
        return common > 0 && before.prefix(common) != after.prefix(common)
    }

    /// A hash of everything an element list shows; equal lists hash equal within a process.
    /// `focus: false` leaves out which element has focus.
    public static func elementsHash(_ elements: [ComputerUseInspectElement], focus: Bool = true) -> Int {
        var hasher = Hasher()
        for element in elements {
            hasher.combine(element.ref)
            hasher.combine(element.depth)
            hasher.combine(element.role)
            hasher.combine(element.subrole)
            hasher.combine(element.title)
            hasher.combine(element.value)
            hasher.combine(element.valueLength)
            hasher.combine(element.description)
            hasher.combine(element.frame.origin.x)
            hasher.combine(element.frame.origin.y)
            hasher.combine(element.frame.width)
            hasher.combine(element.frame.height)
            hasher.combine(element.isEnabled)
            if focus { hasher.combine(element.isFocused) }
        }
        return hasher.finalize()
    }
}
