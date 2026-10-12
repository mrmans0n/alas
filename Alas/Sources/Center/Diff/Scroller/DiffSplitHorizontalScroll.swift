import AppKit

/// Per-side horizontal scroll state for a CoreText split row. Each side
/// scrolls on its own, as the two `NSScrollView` panes do today.
struct DiffSplitHorizontalScroll: Equatable {
    var oldOffset: CGFloat = 0
    var newOffset: CGFloat = 0
    /// Widest line plus text insets, per side.
    var oldContentWidth: CGFloat = 0
    var newContentWidth: CGFloat = 0
    /// Visible code width per side: the pane width minus the gutter.
    var oldViewportWidth: CGFloat = 0
    var newViewportWidth: CGFloat = 0

    func maxOffset(_ side: DiffSplitCoreTextRowView.Side) -> CGFloat {
        switch side {
        case .old: max(0, oldContentWidth - oldViewportWidth)
        case .new: max(0, newContentWidth - newViewportWidth)
        }
    }

    func offset(_ side: DiffSplitCoreTextRowView.Side) -> CGFloat {
        side == .old ? oldOffset : newOffset
    }

    /// Moves `side` by `delta` points; positive reveals content to the right.
    /// Returns whether the offset changed.
    mutating func scroll(_ side: DiffSplitCoreTextRowView.Side, byPoints delta: CGFloat) -> Bool {
        let current = offset(side)
        let next = min(max(0, current + delta), maxOffset(side))
        guard next != current else { return false }
        if side == .old { oldOffset = next } else { newOffset = next }
        return true
    }

    /// Sets `side` to `fraction` of its scrollable range, as a scroller drag does.
    mutating func scroll(_ side: DiffSplitCoreTextRowView.Side, toFraction fraction: CGFloat) -> Bool {
        scroll(side, byPoints: min(max(0, fraction), 1) * maxOffset(side) - offset(side))
    }

    mutating func setViewportWidths(old: CGFloat, new: CGFloat) {
        oldViewportWidth = max(0, old)
        newViewportWidth = max(0, new)
        oldOffset = min(oldOffset, maxOffset(.old))
        newOffset = min(newOffset, maxOffset(.new))
    }

    mutating func resetToLeading() {
        oldOffset = 0
        newOffset = 0
    }

    /// Converts a wheel event's horizontal delta to points. Mouse wheels
    /// report lines, trackpads report points.
    static func pointDelta(scrollingDeltaX: CGFloat, isPrecise: Bool, lineHeight: CGFloat) -> CGFloat {
        isPrecise ? scrollingDeltaX : scrollingDeltaX * lineHeight
    }
}

/// Which axis a trackpad gesture scrolls a CoreText row, decided when the
/// gesture begins and kept through its momentum, as `NSScrollView` locks it.
/// Mouse wheels have no phases and are decided per event.
struct DiffSplitScrollGesture: Equatable {
    private var claimsHorizontal: Bool?

    /// Whether the row should consume this event. `canScroll` is whether the
    /// side under the pointer has anything to scroll sideways.
    mutating func claims(
        phase: NSEvent.Phase, momentumPhase: NSEvent.Phase,
        deltaX: CGFloat, deltaY: CGFloat, canScroll: Bool
    ) -> Bool {
        let decide = { canScroll && deltaX != 0 && abs(deltaX) >= abs(deltaY) }
        if phase.isEmpty, momentumPhase.isEmpty { return decide() }
        if phase.contains(.began) || claimsHorizontal == nil {
            claimsHorizontal = decide()
        }
        return claimsHorizontal ?? false
    }
}
