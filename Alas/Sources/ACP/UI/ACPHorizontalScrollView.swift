import AppKit
import SwiftUI

/// Horizontal-only scrolling for wide markdown content (tables).
///
/// AppKit-backed instead of `ScrollView(.horizontal)`: SwiftUI's scroll view
/// swallows phase-bearing trackpad gestures over its content, which froze the
/// transcript whenever the pointer hovered a wide table. This view keeps only
/// horizontal-dominant wheel events and passes the rest up the responder chain,
/// so the transcript scroller needs no `scrollWheel` override of its own and
/// keeps AppKit responsive scrolling.
struct ACPHorizontalScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> ACPHorizontalNSScrollView {
        let scrollView = ACPHorizontalNSScrollView()
        scrollView.setContent(hostedContent(context))
        return scrollView
    }

    func updateNSView(_ scrollView: ACPHorizontalNSScrollView, context: Context) {
        scrollView.setContent(hostedContent(context))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: ACPHorizontalNSScrollView, context: Context
    ) -> CGSize? {
        let fitting = nsView.contentFittingSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    /// A nested `NSHostingView` does not inherit the SwiftUI environment, so
    /// carry it over explicitly (theme, color scheme, chipping flags, ...).
    private func hostedContent(_ context: Context) -> AnyView {
        AnyView(
            content
                .environment(\.self, context.environment)
                // The document can be wider than the viewport; keep narrow content leading-aligned.
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}

/// Document view that reports SwiftUI-driven size changes (for example an image
/// loading inside a cell) so the owning scroll view can re-measure itself.
@MainActor
private final class ACPHorizontalHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }
}

/// Routing owner of one phased wheel gesture over the table.
private enum GestureOwner {
    case undecided, table, transcript
}

/// The AppKit side of `ACPHorizontalScrollView`.
@MainActor
final class ACPHorizontalNSScrollView: NSScrollView {
    private let hostingView = ACPHorizontalHostingView(rootView: AnyView(EmptyView()))
    private var lastFittingSize: CGSize = .zero
    private var isRefreshingFittingSize = false

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        // No scroller: a legacy-style bar would take space inside a frame sized
        // to the content height and clip the last row. Trackpads still scroll.
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
        documentView = hostingView
        hostingView.onIntrinsicSizeInvalidated = { [weak self] in
            self?.hostingContentSizeChanged()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var contentFittingSize: CGSize { lastFittingSize }

    func setContent(_ view: AnyView) {
        hostingView.rootView = view
        refreshFittingSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lastFittingSize.height)
    }

    override func layout() {
        super.layout()
        sizeDocumentToContent()
    }

    private var gestureOwner = GestureOwner.undecided
    /// Whether this view saw the current gesture's `.began`/`.mayBegin`. A
    /// gesture that started elsewhere (over prose) and slid under the table
    /// belongs to the transcript for its whole life.
    private var sawGestureStart = false
    /// Zero-delta phased events held while the owner is undecided.
    private var pendingEvents: [NSEvent] = []
    private static let pendingEventLimit = 8

    /// Keeps horizontal gestures and passes the rest up the responder chain to
    /// the transcript, which scrolls it with AppKit responsive scrolling.
    /// A phased gesture is decided by its first non-zero delta and owned by the
    /// table or the transcript through momentum, so no phase event is split
    /// between them. Phaseless (mouse wheel) events route per event.
    override func scrollWheel(with event: NSEvent) {
        let isPhased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard isPhased else {
            if Self.isHorizontalDominant(deltaX: dx, deltaY: dy) {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
            return
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            gestureOwner = .undecided
            sawGestureStart = true
            // `.began` legitimately follows its own `.mayBegin`; anything else
            // buffered belongs to an abandoned gesture.
            let continuesMayBegin = event.phase.contains(.began)
                && pendingEvents.last?.phase.contains(.mayBegin) == true
            if !continuesMayBegin { pendingEvents.removeAll() }
        }

        if gestureOwner == .undecided, !sawGestureStart {
            // Mid-gesture arrival: the transcript received the start, so it
            // owns this event and everything after it, whatever its delta.
            gestureOwner = .transcript
        }

        if gestureOwner == .undecided {
            if dx != 0 || dy != 0, !event.phase.isEmpty {
                gestureOwner = Self.isHorizontalDominant(deltaX: dx, deltaY: dy) ? .table : .transcript
                deliver(pendingEvents)
                pendingEvents.removeAll()
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled)
                || !event.momentumPhase.isEmpty
            {
                // The gesture finished without ever moving: hand the whole
                // sequence to the transcript so its begin/end stay paired.
                let flushed = pendingEvents + [event]
                pendingEvents.removeAll()
                sawGestureStart = false
                for pending in flushed { nextResponder?.scrollWheel(with: pending) }
                resetOwnerIfGestureOver(event)
                return
            } else {
                // Zero-delta start of a phased gesture: its owner is not known
                // yet, so hold it back instead of splitting the sequence.
                pendingEvents.append(event)
                if pendingEvents.count > Self.pendingEventLimit { pendingEvents.removeFirst() }
                return
            }
        }

        deliver([event])
        resetOwnerIfGestureOver(event)
    }

    private func deliver(_ events: [NSEvent]) {
        for event in events {
            if gestureOwner == .table {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }
    }

    private func resetOwnerIfGestureOver(_ event: NSEvent) {
        if event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
        {
            gestureOwner = .undecided
            sawGestureStart = false
        }
    }

    static func isHorizontalDominant(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaX) > abs(deltaY)
    }

    private func hostingContentSizeChanged() {
        refreshFittingSize()
    }

    /// Re-measures the hosted content and invalidates this view only when the
    /// fitting size actually changed, which also stops invalidation loops.
    private func refreshFittingSize() {
        guard !isRefreshingFittingSize else { return }
        isRefreshingFittingSize = true
        defer { isRefreshingFittingSize = false }
        let fitting = hostingView.fittingSize
        sizeDocument(to: fitting)
        guard fitting != lastFittingSize else { return }
        lastFittingSize = fitting
        invalidateIntrinsicContentSize()
    }

    private func sizeDocumentToContent() {
        refreshFittingSize()
    }

    private func sizeDocument(to fitting: CGSize) {
        let size = NSSize(width: max(fitting.width, contentView.bounds.width), height: fitting.height)
        if hostingView.frame.size != size {
            hostingView.setFrameSize(size)
        }
    }
}
