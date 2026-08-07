import AppKit

/// Flipped document canvas matching the diff tiler's top-origin coordinates.
@MainActor
final class AppKitDiffScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Native scrolling primitive for virtualized diff rows.
@MainActor
final class AppKitDiffScrollView: NSScrollView {
    #if DEBUG
    typealias AnimatedScrollExecutorForTests = (AppKitDiffScrollView, NSPoint, @escaping () -> Void) -> Void
    var animatedScrollExecutorForTests: AnimatedScrollExecutorForTests?
    #endif

    let flippedDocumentView = AppKitDiffScrollDocumentView()

    /// Called only for user-driven bounds movement. Programmatic adjustments
    /// intentionally do not feed back into row ownership.
    var onUserViewportChange: (() -> Void)?
    /// Called for programmatic animated bounds movement so virtualization can
    /// keep the visible band mounted without publishing active-owner changes.
    var onProgrammaticViewportChange: (() -> Void)?
    /// Called when viewport height changes without a content-width change.
    var onViewportGeometryChange: (() -> Void)?
    /// Called when the first positive usable width arrives or when it changes.
    var onContentWidthChange: (() -> Void)?

    private var boundsObserver: NSObjectProtocol?
    private var lastReportedContentWidth: CGFloat?
    private var lastReportedViewportHeight: CGFloat?
    private var programmaticAdjustmentDepth = 0
    private var programmaticAnimationDepth = 0

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
            MainActor.assumeIsolated {
                guard let self, self.programmaticAdjustmentDepth == 0 else { return }
                if self.programmaticAnimationDepth > 0 {
                    self.onProgrammaticViewportChange?()
                    return
                }
                self.onUserViewportChange?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        let widthChanged = width != lastReportedContentWidth
        let heightChanged = height != lastReportedViewportHeight
        guard widthChanged || heightChanged else { return }
        lastReportedContentWidth = width
        lastReportedViewportHeight = height

        if widthChanged, width > 0 {
            onContentWidthChange?()
        } else if heightChanged {
            onViewportGeometryChange?()
        }
    }

    var scrollY: CGFloat { contentView.bounds.origin.y }
    var viewportHeight: CGFloat { contentView.bounds.height }
    var contentWidth: CGFloat { contentView.bounds.width }
    var contentHeight: CGFloat { flippedDocumentView.frame.height }

    func setDocumentHeight(_ height: CGFloat) {
        let clampedHeight = max(0, height)
        guard flippedDocumentView.frame.height != clampedHeight else { return }
        performProgrammatic {
            flippedDocumentView.frame.size.height = clampedHeight
            setScrollY(scrollY, animated: false)
        }
    }

    func setScrollY(_ y: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        let point = NSPoint(x: contentView.bounds.origin.x, y: clampedScrollY(y))
        guard abs(point.y - scrollY) > 0.01 else {
            completion?()
            return
        }
        performProgrammatic {
            if animated {
                programmaticAnimationDepth += 1
                #if DEBUG
                if let animatedScrollExecutorForTests {
                    animatedScrollExecutorForTests(self, point) { [weak self] in
                        self?.programmaticAnimationDidComplete()
                        completion?()
                    }
                    return
                }
                #endif
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    contentView.animator().setBoundsOrigin(point)
                } completionHandler: { [weak self] in
                    self?.programmaticAnimationDidComplete()
                    completion?()
                }
            } else {
                contentView.setBoundsOrigin(point)
                reflectScrolledClipView(contentView)
                completion?()
            }
        }
    }

    /// Sets the scroll position without clamping to the document height.
    /// Used during plan restructuring when the document height is still
    /// based on estimates and the original viewport position may be beyond
    /// the estimated document — clamping would move the viewport to the
    /// estimated bottom, causing the wrong rows to be measured.
    func setUnclampedScrollY(_ y: CGFloat) {
        let point = NSPoint(x: contentView.bounds.origin.x, y: max(0, y))
        guard abs(point.y - scrollY) > 0.01 else { return }
        performProgrammatic {
            contentView.setBoundsOrigin(point)
        }
    }

    private func clampedScrollY(_ y: CGFloat) -> CGFloat {
        min(max(0, y), max(0, contentHeight - viewportHeight))
    }

    private func performProgrammatic(_ body: () -> Void) {
        programmaticAdjustmentDepth += 1
        body()
        programmaticAdjustmentDepth -= 1
    }

    private func programmaticAnimationDidComplete() {
        programmaticAnimationDepth = max(0, programmaticAnimationDepth - 1)
    }
}
