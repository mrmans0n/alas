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
    func handleScrollWheelEvent(_ event: NSEvent, cursorInWindow: NSPoint) -> NSEvent? {
        let viewPoint = convert(cursorInWindow, from: nil)
        guard bounds.contains(viewPoint), let scroller = transcriptScroller else {
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
        scroller.markdownScrollRoutingState = routingState
        if shouldForward {
            for pendingEvent in routingState.consumePendingEvents() {
                scroller.scrollMarkdownWheel(with: pendingEvent)
            }
            scroller.scrollMarkdownWheel(with: event)
            return nil
        }
        // Undecided gesture start with buffered events: hold the tick the
        // same way markdown text views do, so neither axis sees jitter.
        if routingState.forwarding == nil, routingState.hasPendingEvents {
            return nil
        }
        // Vertical route not taken: leave the event to normal dispatch,
        // where SwiftUI's horizontal scroll view scrolls the block.
        return event
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

    /// Test-only exposure of `transcriptScroller`.
    var transcriptScrollerForTesting: ACPTranscriptScrollerView? {
        transcriptScroller
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Real input always arrives window-bound with the cursor
            // position already resolved into window coordinates.
            guard let window = self.window, event.window === window else { return event }
            return self.handleScrollWheelEvent(event, cursorInWindow: event.locationInWindow)
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
