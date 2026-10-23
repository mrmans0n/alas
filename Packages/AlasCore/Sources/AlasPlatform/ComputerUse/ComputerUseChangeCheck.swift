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

    public init(focus: Focus? = nil, windowTitle: String? = nil, elementsHash: Int? = nil, targetHash: Int? = nil) {
        self.focus = focus
        self.windowTitle = windowTitle
        self.elementsHash = elementsHash
        self.targetHash = targetHash
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
    public static let dragRetryHint = #" Retry with delivery: "direct" to drag with the app in front."#

    /// The warning for an action whose window looks the same after it, else nil. Without both
    /// complete element lists the check can't tell, so it doesn't warn, except after a drag: a
    /// cut-short read is how a drag that did nothing looked like one that worked. The retry hint
    /// is only for clicks, scrolls and drags that went as events: a key or typed text can
    /// legitimately change nothing a read shows, and an activation already was the direct way.
    public static func warning(
        before: ComputerUseWindowFingerprint?, after: ComputerUseWindowFingerprint?, kind: Kind, deliveredAsEvents: Bool
    ) -> String? {
        guard var before, var after else { return nil }
        if kind == .drag {
            if before.elementsHash == nil || after.elementsHash == nil {
                before.elementsHash = nil
                after.elementsHash = nil
            }
            guard before == after else { return nil }
            return deliveredAsEvents ? dragWarning + dragRetryHint : dragWarning
        }
        guard before.elementsHash != nil, after.elementsHash != nil, before == after else { return nil }
        let hint = deliveredAsEvents && (kind == .click || kind == .scroll)
        return hint ? noChangeWarning + retryDirectHint : noChangeWarning
    }

    /// A hash of everything an element list shows; equal lists hash equal within a process.
    public static func elementsHash(_ elements: [ComputerUseInspectElement]) -> Int {
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
            hasher.combine(element.isFocused)
        }
        return hasher.finalize()
    }
}
