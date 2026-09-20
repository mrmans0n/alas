import AppKit
import SwiftUI

/// Transparent AppKit backing for `ACPBlockWheelRouter` that routes
/// scroll-wheel events over the block between the block's own horizontal
/// scrolling and the enclosing transcript's vertical scrolling.
///
/// Why this exists: SwiftUI's internal scroll machinery (`HostingScrollView`
/// et al.) accepts phase-bearing trackpad gestures over the containers it
/// hosts — a `ScrollView(.horizontal)` inside the transcript therefore eats
/// vertical trackpad/momentum deltas (they never escape its gesture system
/// to the enclosing NSScrollView's responder chain), which froze transcript
/// scrolling whenever the pointer hovered a markdown table or code block.
/// SwiftUI does not surface raw scroll events to gesture modifiers, so — as
/// with `ScrollEventCapturingView` in the image-diff viewer — we drop down
/// to AppKit and watch the event stream before dispatch.
///
/// Routing mirrors `ACPMarkdownInlineNSTextView.scrollWheel`: the gesture is
/// classified with the shared per-transcript `ACPMarkdownScrollRoutingState`
/// so a gesture that starts over a block and continues over routed text
/// (or vice versa) keeps one consistent route through momentum. Vertical
/// gestures replay to the transcript scroller (`scrollMarkdownWheel`); the
/// phase-reset contract lives in the scroller's own `scrollWheel` override.
/// Horizontal gestures are left untouched for SwiftUI's horizontal scroll
/// view.
@MainActor
final class ACPBlockWheelRoutingView: NSView {
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    isolated deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    /// Hit-test transparent: the block's own SwiftUI content must keep
    /// receiving clicks, text selection, and hover; this view only watches
    /// the event stream.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Consumes events that belong to this block's vertical transcript
    /// routing; returns nil when the event was routed (monitor must stop
    /// dispatch), or the event itself when it should dispatch normally.
    /// `cursorInWindow` is the event's cursor position in window
    /// coordinates. Exposed for tests: synthetic events cannot carry a
    /// window-bound location through `NSApp.sendEvent` deterministically.
    func handleScrollWheelEvent(_ event: NSEvent, cursorInWindow: NSPoint, cursorTarget: NSView?) -> NSEvent? {
        guard isOwnBlock(cursorTarget: cursorTarget, cursorInWindow: cursorInWindow),
              let scroller = transcriptScroller
        else {
            return event
        }
        var routingState = scroller.markdownScrollRoutingState
        let shouldForward = routingState.shouldForward(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            pendingEvent: event
        )
        defer { routingState.completeCurrentEventRouting() }

        if shouldForward {
            let pendingEvents = routingState.consumePendingEvents()
            // The vertical route's first event carries `.began`; the
            // scroller's own `scrollWheel` reset rewrites the shared state
            // mid-delivery. Consume, forward, run the terminal reset, and
            // only then publish the finalized local state — otherwise the
            // premature write-back loses buffered events and later ticks
            // re-classify instead of staying latched to this gesture.
            scroller.scrollMarkdownWheel(with: event)
            for pendingEvent in pendingEvents {
                scroller.scrollMarkdownWheel(with: pendingEvent)
            }
            routingState.completeCurrentEventRouting()
            scroller.markdownScrollRoutingState = routingState
            return nil
        }
        // Undecided gesture start with buffered events: hold the tick the
        // same way markdown text views do, so neither axis sees jitter.
        if routingState.forwarding == nil, routingState.hasPendingEvents {
            scroller.markdownScrollRoutingState = routingState
            return nil
        }
        // Horizontal route selected after a buffered start: replay the
        // buffered beginning through the block's own scroll machinery, then
        // hand the current tick to normal dispatch — exactly once. (Over
        // block padding there is no markdown text view downstream to flush
        // buffered starts.) Ambiguous buffers carry no dominant-axis delta,
        // so replaying them cannot double-scroll.
        let pendingEvents = routingState.consumePendingEvents()
        routingState.completeCurrentEventRouting()
        scroller.markdownScrollRoutingState = routingState
        for pendingEvent in pendingEvents {
            dispatchBlockEvent(pendingEvent)
        }
        return event
    }

    /// Delivers an event through this block's own scroll machinery: the
    /// horizontal SwiftUI scroll view hosting the block's content when the
    /// cursor is over it, else normal responder-chain dispatch (which starts
    /// at the window's deepest hit-test view).
    private func dispatchBlockEvent(_ event: NSEvent) {
        if let innerScroll = innerScroll(containingWindowPoint: event.locationInWindow) {
            innerScroll.scrollWheel(with: event)
            return
        }
        superview?.scrollWheel(with: event)
    }

    /// Whether the cursor's window hit-test target belongs to this router's
    /// own block. Bounds alone cannot tell: the transcript is overlaid by
    /// the composer in a ZStack, so a block behind the composer must not
    /// route events the composer should receive. The anchor is the router's
    /// enclosing row hosting view: the router is a background sibling of the
    /// block content (never an ancestor of the hit target), but any hit
    /// target inside this row — and only those — reaches the same row
    /// hosting view through its responder chain. When the caller has no
    /// pre-computed target, the window hit-test resolves it.
    private func isOwnBlock(cursorTarget: NSView?, cursorInWindow: NSPoint) -> Bool {
        let viewPoint = convert(cursorInWindow, from: nil)
        guard bounds.contains(viewPoint) else { return false }
        guard let rowHostingView else { return false }
        let target = cursorTarget ?? window?.contentView?.hitTest(cursorInWindow)
        var responder: NSResponder? = target
        while let current = responder {
            if current === rowHostingView {
                return true
            }
            responder = current.nextResponder
        }
        return false
    }

    /// The block's own horizontal scroll view — the first NSScrollView above
    /// the deepest hit-test view that is not the transcript scroller — when
    /// the cursor actually lands inside this router's frame. The cursor can
    /// also sit inside this router but over content outside the scroll view
    /// (inter-row spacing in the hosting stack): those events go to normal
    /// dispatch.
    private func innerScroll(containingWindowPoint windowPoint: NSPoint) -> NSScrollView? {
        guard let window else { return nil }
        guard let hitView = window.contentView?.hitTest(windowPoint) else { return nil }
        var responder: NSResponder? = hitView
        while let current = responder {
            if let scrollView = current as? NSScrollView {
                return scrollView === transcriptScroller ? nil : scrollView
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// The transcript scroller above this block in the responder chain, or
    /// nil when the block renders outside a transcript (diff review panes,
    /// other markdown surfaces) — events then dispatch normally.
    private var transcriptScroller: ACPTranscriptScrollerView? {
        var responder: NSResponder? = superview
        while let current = responder {
            if let scroller = current as? ACPTranscriptScrollerView {
                return scroller
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// This router's enclosing row hosting view: the `NSHostingView` that
    /// mounts the transcript row's SwiftUI content. Ownership anchor for the
    /// occlusion check — the router is a background sibling of the block
    /// content, so a hit target inside this row reaches this hosting view
    /// through its responder chain, while a hit target in another surface
    /// (the composer overlay, another row) never does.
    private var rowHostingView: NSHostingView<AnyView>? {
        var responder: NSResponder? = superview
        while let current = responder {
            if let hostingView = current as? NSHostingView<AnyView> {
                return hostingView
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// Test-only exposure of `transcriptScroller`.
    var transcriptScrollerForTesting: ACPTranscriptScrollerView? {
        transcriptScroller
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Real input always arrives window-bound with the cursor
            // position already resolved into window coordinates. The window
            // hit-test resolves the deepest view under the cursor, which
            // owns the occlusion check (the composer overlays the
            // transcript, so a hit target outside this block must not
            // route).
            guard let window = self.window, event.window === window else { return event }
            return self.handleScrollWheelEvent(
                event,
                cursorInWindow: event.locationInWindow,
                cursorTarget: window.contentView?.hitTest(event.locationInWindow)
            )
        }
    }
}

/// SwiftUI bridge hosting `ACPBlockWheelRoutingView` as an invisible
/// background over a block that owns horizontal scrolling inside the
/// transcript (markdown tables, code blocks). The routing view resolves its
/// transcript scroller from the responder chain at event time; outside a
/// transcript it is inert.
struct ACPBlockWheelRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> ACPBlockWheelRoutingView {
        ACPBlockWheelRoutingView(frame: .zero)
    }

    func updateNSView(_ nsView: ACPBlockWheelRoutingView, context: Context) {}
}
