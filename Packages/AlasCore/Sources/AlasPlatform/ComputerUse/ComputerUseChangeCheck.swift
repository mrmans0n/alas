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
    /// `ComputerUseChangeCheck.elementsHash` of the element list; nil when the read failed or was
    /// cut short (limit, node budget, deadline), since elements past the cut may have changed.
    public var elementsHash: Int?
    /// The acted-on element's own state (value, selection, enabled, title); nil without one.
    public var targetHash: Int?
    /// `elementsHash` without which element has focus (`ComputerUseChangeCheck.elementsHash(_:focus:)`),
    /// nil when `elementsHash` is: tells a window whose focus or selection alone moved.
    public var contentHash: Int?

    public init(
        focus: Focus? = nil, windowTitle: String? = nil, elementsHash: Int? = nil, targetHash: Int? = nil,
        contentHash: Int? = nil
    ) {
        self.focus = focus
        self.windowTitle = windowTitle
        self.elementsHash = elementsHash
        self.targetHash = targetHash
        self.contentHash = contentHash
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
    /// cut-short read is how a drag that did nothing looked like one that worked. A drag that went
    /// as events and moved only focus and selection (the press selected the item it grabbed, and
    /// nothing was dropped) warns too. The retry hint is only for clicks, scrolls and drags that
    /// went as events: a key or typed text can legitimately change nothing a read shows, and an
    /// activation already was the direct way.
    public static func warning(
        before: ComputerUseWindowFingerprint?, after: ComputerUseWindowFingerprint?, kind: Kind, deliveredAsEvents: Bool
    ) -> String? {
        guard var before, var after else { return nil }
        if kind == .drag {
            if deliveredAsEvents, onlyFocusOrSelectionMoved(before, after) { return dragWarning + retryDirectHint }
            if before.elementsHash == nil || after.elementsHash == nil {
                before.elementsHash = nil
                after.elementsHash = nil
            }
            before.contentHash = nil
            after.contentHash = nil
            guard before == after else { return nil }
            return deliveredAsEvents ? dragWarning + retryDirectHint : dragWarning
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

    /// Whether the window's elements themselves changed: both reads complete and their elements
    /// differ. Focus and selection don't count: activating, raising and pressing the mouse move
    /// them before a drop shows.
    public static func elementsChanged(before: ComputerUseWindowFingerprint, after: ComputerUseWindowFingerprint?) -> Bool {
        guard let before = before.elementsHash, let after = after?.elementsHash else { return false }
        return before != after
    }

    /// Both reads complete, with the same elements but for which has focus, and the same title:
    /// what differs is the focused element, the selection or the acted-on element's state.
    private static func onlyFocusOrSelectionMoved(
        _ before: ComputerUseWindowFingerprint, _ after: ComputerUseWindowFingerprint
    ) -> Bool {
        guard let content = before.contentHash, content == after.contentHash else { return false }
        return before.windowTitle == after.windowTitle
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
