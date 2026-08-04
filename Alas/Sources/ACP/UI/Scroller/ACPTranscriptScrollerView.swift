import AppKit

/// Flipped document canvas: y = 0 is the top, y grows downward, matching
/// the tiling controller's coordinates.
@MainActor
final class ACPTranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The transcript's NSScrollView. Exposes the one primitive SwiftUI's
/// ScrollView can't provide on macOS 26: synchronous scroll-offset
/// adjustment in the same pass as a content mutation (`applyPrepend`), so
/// older rows graft in with zero visible movement and live trackpad
/// momentum keeps working against the same scroll view.
@MainActor
final class ACPTranscriptScrollerView: NSScrollView {
    let flippedDocumentView = ACPTranscriptDocumentView()
    var onScroll: ((_ previousY: CGFloat?, _ newY: CGFloat, _ viewportHeight: CGFloat, _ contentHeight: CGFloat, _ isProgrammatic: Bool) -> Void)?

    /// Fired from `layout()` whenever `contentView.bounds.width` differs
    /// from the last width reported — including the very first non-zero
    /// width the view ever receives. This is the sole notification path for
    /// "the scroller got a real size with no accompanying SwiftUI model
    /// change": `makeNSView` builds the view at `frame: .zero`, and the
    /// Coordinator's first `update(host:)` therefore always runs against
    /// width 0, which `ACPTranscriptScrollerReconciler.apply` deliberately
    /// defers on. Without this hook, a fully hydrated but otherwise idle
    /// transcript could stay empty until some unrelated SwiftUI update
    /// happened to call `updateNSView` again — see
    /// `ACPTranscriptScroller.Coordinator.reconcileForContentWidthChange`,
    /// the sole subscriber.
    var onContentWidthChange: (() -> Void)?
    private var lastReportedContentWidth: CGFloat?

    /// Fired from `layout()` whenever `contentView.bounds.height` differs
    /// from the last height reported, PROVIDED the width did NOT also
    /// change on this same pass (a combined width+height change is already
    /// fully covered by `onContentWidthChange`'s reconcile, which ends in
    /// its own mount/relayout pass — see `reconcileForContentWidthChange`).
    ///
    /// This closes a distinct gap from the width one above: `boundsDidChange`
    /// (see `reportScroll` below) only reports when the clip view's
    /// y-ORIGIN moves, and `layout()` used to only notify on a width change
    /// — so a HEIGHT-only resize (the window dragged taller/shorter with no
    /// width change) reported through neither path. That matters because
    /// the reconciler's mount band
    /// (`ACPTranscriptScrollerReconciler.performLayoutPass`) is derived from
    /// `viewportHeight`: growing the window revealed space no newly-mounted
    /// row filled, and shrinking it left rows mounted that should have been
    /// released.
    ///
    /// Unlike a width change, a height change never invalidates a row's
    /// MEASURED content — nothing about a row reflows because the viewport
    /// got taller or shorter, only which rows fall inside the band changes.
    /// The coordinator's subscriber (`reconcileForViewportHeightChange`)
    /// responds with the cheap operation for that — a mount/relayout pass —
    /// not the full `update(host:)`/`apply()` re-measure the width path
    /// uses; see that method's doc comment.
    var onViewportHeightChange: (() -> Void)?
    private var lastReportedViewportHeight: CGFloat?

    private var lastReportedY: CGFloat?
    private var programmaticAdjustmentDepth = 0
    private var boundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        automaticallyAdjustsContentInsets = false
        documentView = flippedDocumentView
        flippedDocumentView.frame = NSRect(x: 0, y: 0, width: frameRect.width, height: 0)
        flippedDocumentView.autoresizingMask = [.width]
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportScroll() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    /// Explicitly marks the view as needing a layout pass whenever its own
    /// frame SIZE changes, rather than relying on AppKit to infer that from
    /// a plain (non-Auto-Layout, manually-`.frame`-positioned) view tree.
    /// This is what makes `layout()` below fire reliably both for real
    /// AppKit-driven resizes (SwiftUI placing/resizing the representable,
    /// a window/split-view resize) and for a test directly assigning
    /// `.frame` and then calling `layoutSubtreeIfNeeded()`.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // `super.layout()` runs AppKit's own scroll-view tiling first, so
        // `contentView.bounds` already reflects any scroller-visibility
        // change that layout may have made — reading it before `super.layout()`
        // could observe stale, pre-tile values.
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        let widthChanged = width != lastReportedContentWidth
        let heightChanged = height != lastReportedViewportHeight
        guard widthChanged || heightChanged else { return }
        lastReportedContentWidth = width
        lastReportedViewportHeight = height
        if widthChanged {
            // Subsumes the height-only response: `onContentWidthChange`'s
            // subscriber ends its own reconcile with a full mount/relayout
            // pass, so firing `onViewportHeightChange` too on a combined
            // width+height change would just be a redundant extra pass.
            onContentWidthChange?()
        } else {
            onViewportHeightChange?()
        }
    }

    var scrollY: CGFloat { contentView.bounds.origin.y }
    var viewportHeight: CGFloat { contentView.bounds.height }
    var contentHeight: CGFloat { flippedDocumentView.frame.height }
    var distanceFromBottom: CGFloat {
        max(0, contentHeight - viewportHeight - scrollY)
    }

    func setDocumentHeight(_ height: CGFloat) {
        guard flippedDocumentView.frame.height != height else { return }
        performProgrammatic {
            flippedDocumentView.frame.size.height = height
        }
    }

    /// Grow the document by prepended content and shift the scroll offset by
    /// the same delta, in one pass — the viewport does not move visually.
    ///
    /// The resulting offset is clamped exactly as `setScrollY` clamps, and
    /// against the NEW document height (already installed at that point).
    /// `delta` is not always positive: removal compensation routes a
    /// negative delta through this same primitive, and a removal straddling
    /// the viewport top would otherwise leave the clip view at a negative
    /// bounds origin — parked above the document's own content until the
    /// next user scroll happens to correct it.
    func applyPrepend(delta: CGFloat, newDocumentHeight: CGFloat) {
        performProgrammatic {
            flippedDocumentView.frame.size.height = newDocumentHeight
            let origin = contentView.bounds.origin
            contentView.setBoundsOrigin(NSPoint(x: origin.x, y: clampedScrollY(origin.y + delta)))
            reflectScrolledClipView(contentView)
        }
    }

    func setScrollY(_ y: CGFloat) {
        let clamped = clampedScrollY(y)
        performProgrammatic {
            contentView.setBoundsOrigin(NSPoint(x: contentView.bounds.origin.x, y: clamped))
            reflectScrolledClipView(contentView)
        }
    }

    /// The scrollable range's clamp, shared by every programmatic offset
    /// adjustment so they cannot disagree about what a legal offset is.
    private func clampedScrollY(_ y: CGFloat) -> CGFloat {
        max(0, min(y, max(0, contentHeight - viewportHeight)))
    }

    func scrollToBottom() {
        setScrollY(max(0, contentHeight - viewportHeight))
    }

    private func performProgrammatic(_ body: () -> Void) {
        programmaticAdjustmentDepth += 1
        body()
        programmaticAdjustmentDepth -= 1
    }

    private func reportScroll() {
        let newY = scrollY
        guard newY != lastReportedY else { return }
        let previous = lastReportedY
        lastReportedY = newY
        onScroll?(previous, newY, viewportHeight, contentHeight, programmaticAdjustmentDepth > 0)
    }
}
