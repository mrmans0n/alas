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
        AnyView(content.environment(\.self, context.environment))
    }
}

/// The AppKit side of `ACPHorizontalScrollView`.
@MainActor
final class ACPHorizontalNSScrollView: NSScrollView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .automatic
        documentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var contentFittingSize: CGSize { hostingView.fittingSize }

    func setContent(_ view: AnyView) {
        hostingView.rootView = view
        sizeDocumentToContent()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentFittingSize.height)
    }

    override func layout() {
        super.layout()
        sizeDocumentToContent()
    }

    /// True while a phased horizontal gesture (and its momentum) is owned by this view.
    private var latchesHorizontalGesture = false

    /// Keeps horizontal gestures and passes the rest up the responder chain to
    /// the transcript, which scrolls it with AppKit responsive scrolling.
    /// A phased gesture that turns horizontal latches to this view for its whole
    /// lifecycle, including momentum, so no phase event is split between the
    /// table and the transcript. Phaseless (mouse wheel) events route per event.
    override func scrollWheel(with event: NSEvent) {
        let isPhased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            latchesHorizontalGesture = false
        }

        if latchesHorizontalGesture {
            super.scrollWheel(with: event)
        } else if Self.isHorizontalDominant(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
            if isPhased { latchesHorizontalGesture = true }
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }

        if event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
        {
            latchesHorizontalGesture = false
        }
    }

    static func isHorizontalDominant(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaX) > abs(deltaY)
    }

    private func sizeDocumentToContent() {
        let fitting = contentFittingSize
        let size = NSSize(width: max(fitting.width, contentView.bounds.width), height: fitting.height)
        if hostingView.frame.size != size {
            hostingView.setFrameSize(size)
        }
    }
}
