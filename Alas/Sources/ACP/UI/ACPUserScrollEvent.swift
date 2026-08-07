import AppKit

/// Maps an `NSEvent.EventType` to whether it represents a live user scroll
/// gesture, used by the transcript scroller to decide if an upward bounds
/// change is deliberate. Extracted as a pure function so the mapping is unit
/// testable without a running event loop.
///
/// The set is deliberately narrow. `NSApp.currentEvent` reports the most
/// recent app-wide event, not the cause of the bounds change, so any event
/// type that also occurs away from scrolling would misattribute layout reflow
/// during streaming and re-latch the false pause this guards against:
///   - `.keyDown`: the transcript `ScrollView` never holds key focus here (the
///     composer owns it), so keyboard paging can't scroll it; accepting it
///     would catch composer typing during streaming.
///   - `.leftMouseDown` / `.leftMouseUp`: a bare click can't be told apart from
///     clicking a transcript control (expanding a card, the copy button) by
///     type alone, so it would catch reflow that coincides with such a click.
/// The covered cases (trackpad and dragging the scroller knob) only fire while
/// actually scrolling, so they can't be confused with idle layout reflow.
enum ACPUserScrollEvent {
    /// `NSApp.currentEvent` lingers after the gesture ends; only treat it as
    /// the cause of a bounds change when it happened within this window.
    /// Trackpad momentum keeps emitting scrollWheel events, so live scrolling
    /// stays fresh.
    static let freshnessWindow: TimeInterval = 0.35

    /// `NSEvent.timestamp` is seconds since system startup, the same
    /// timebase as `ProcessInfo.processInfo.systemUptime` (per Apple's
    /// documentation for `NSEvent.timestamp`), so the two are directly
    /// comparable without conversion.
    static func isFresh(
        eventTimestamp: TimeInterval?,
        now: TimeInterval,
        window: TimeInterval = freshnessWindow
    ) -> Bool {
        guard let eventTimestamp else { return false }
        return now - eventTimestamp <= window
    }

    static func isUserDriven(_ type: NSEvent.EventType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .scrollWheel, .leftMouseDragged, .gesture, .magnify, .swipe:
            return true
        default:
            return false
        }
    }

    static func isHeadPaginationDriven(
        _ type: NSEvent.EventType?,
        previousMinY: CGFloat? = nil,
        newMinY: CGFloat? = nil,
        isScrollbarTrackHit: Bool = false
    ) -> Bool {
        guard let type else { return false }
        if isUserDriven(type) { return true }
        // Track-click paging arrives as a plain mouse-down. Keep that out of
        // tail-follow pause detection, and require both scrollbar provenance
        // and actual upward geometry movement so tab/content clicks cannot
        // reveal older rows during restore or layout.
        guard type == .leftMouseDown, isScrollbarTrackHit, let previousMinY, let newMinY else {
            return false
        }
        return newMinY < previousMinY - ACPScrollDirectionClassifier.upwardEpsilon
    }

    static func isScrollbarTrackMouseDown(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown, let contentView = event.window?.contentView else {
            return false
        }
        return isScrollbarView(contentView.hitTest(event.locationInWindow))
    }

    private static func isScrollbarView(_ view: NSView?) -> Bool {
        var current = view
        while let view = current {
            if view is NSScroller { return true }
            let className = NSStringFromClass(type(of: view)).lowercased()
            if className.contains("scroller") || className.contains("scrollbar") {
                return true
            }
            current = view.superview
        }
        return false
    }
}
