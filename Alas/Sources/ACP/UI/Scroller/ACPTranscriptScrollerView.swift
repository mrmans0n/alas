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
    private var liveScrollObservers: [NSObjectProtocol] = []

    /// True between `willStartLiveScroll` and `didEndLiveScroll`.
    private var isLiveScrolling = false
    /// `systemUptime` at the last `didEndLiveScroll`, or nil if a gesture has
    /// never finished. Same timebase as `ACPUserScrollEvent`.
    private var lastLiveScrollEnd: TimeInterval?

    /// How long after a gesture ends the scroller still counts as
    /// user-driven. Trackpad momentum and the elastic bounce-back keep moving
    /// the viewport after `didEndLiveScroll`, and re-pinning to the tail
    /// during that settle is precisely the rebound jank this guards against.
    /// Matches `ACPUserScrollEvent.freshnessWindow` so the two notions of
    /// "recent enough to be the user" cannot drift apart.
    nonisolated static let userScrollGracePeriod: TimeInterval = ACPUserScrollEvent.freshnessWindow

    /// Whether the user is scrolling right now, or has just stopped.
    ///
    /// This is the authoritative signal for user intent, and it exists
    /// because `NSApp.currentEvent` is not: as the transcript slides under a
    /// stationary cursor, AppKit generates `mouseEntered`/`mouseExited`
    /// tracking events, and one of those — not the scroll wheel event — is
    /// almost always what is current when the clip view posts its
    /// bounds-change notification. A capture of one real gesture classified
    /// 414 of 417 ticks as not-user-driven on that basis, which left
    /// `pauseTailFollow()` unreachable and trapped the reader at the bottom
    /// of the transcript (see `ACPTranscriptScrollerLiveScrollTests`).
    ///
    /// `NSScrollView` posts the live-scroll notifications only for genuine
    /// user-driven scrolling — never for a programmatic `setBoundsOrigin` —
    /// so this cleanly separates the two without inspecting events at all.
    var isUserScrollActive: Bool {
        Self.isUserScrollActive(
            isLiveScrolling: isLiveScrolling,
            lastLiveScrollEnd: lastLiveScrollEnd,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Pure form of `isUserScrollActive`, so the grace-period boundary is
    /// testable without waiting in real time.
    nonisolated static func isUserScrollActive(
        isLiveScrolling: Bool,
        lastLiveScrollEnd: TimeInterval?,
        now: TimeInterval,
        grace: TimeInterval = userScrollGracePeriod
    ) -> Bool {
        if isLiveScrolling { return true }
        guard let lastLiveScrollEnd else { return false }
        return now - lastLiveScrollEnd <= grace
    }

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
        installLiveScrollObservers()
    }

    /// Tracks the scroll view's own live-scroll notifications, which is what
    /// `isUserScrollActive` reports. Registered with `queue: nil` so the
    /// flags are already current by the time the bounds-change notification
    /// for the same gesture runs.
    private func installLiveScrollObservers() {
        let center = NotificationCenter.default
        liveScrollObservers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLiveScrolling = true
            }
        })
        liveScrollObservers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveScrolling = false
                self.lastLiveScrollEnd = ProcessInfo.processInfo.systemUptime
            }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        for observer in liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
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
        if abs(clamped - scrollY) > 0.01 {
        }
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
        let maxY = max(0, contentHeight - viewportHeight)
        onScroll?(previous, newY, viewportHeight, contentHeight, programmaticAdjustmentDepth > 0)
    }
}
