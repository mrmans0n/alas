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

    /// Keeps only horizontal-dominant events. Everything else, including
    /// vertical gestures and their momentum, continues up the responder chain
    /// to the transcript, which scrolls it with AppKit responsive scrolling.
    override func scrollWheel(with event: NSEvent) {
        if Self.isHorizontalDominant(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
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
