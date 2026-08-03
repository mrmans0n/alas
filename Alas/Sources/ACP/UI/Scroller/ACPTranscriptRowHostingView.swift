import AppKit
import SwiftUI

/// NSHostingView wrapper for a single transcript row. Adds:
/// - a callback when SwiftUI invalidates the content's intrinsic size
///   (streaming rows growing), so the tiling controller can re-measure;
/// - fixed-width height measurement for the tiling layout.
@MainActor
final class ACPTranscriptRowHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    /// The row content as originally supplied, before the `.frame(width:)`
    /// wrapper `measuredHeight(forWidth:)` applies for measurement. Kept
    /// separately because `fittingSize`/constraint-based measurement does not
    /// pick up SwiftUI's text-wrapping width dependency reliably; pinning the
    /// width directly on the root view does.
    private let baseRootView: AnyView

    /// The width this view's displayed content is currently pinned to, i.e.
    /// the argument of the last successful `measuredHeight(forWidth:)` call.
    /// `nil` if `measuredHeight(forWidth:)` has never been called with a
    /// positive width. `measuredHeight(forWidth:)` mutates the view's live
    /// `rootView` as a side effect of measuring it (see that method's doc
    /// comment), so callers that place this view at a frame must assert
    /// `lastMeasuredWidth == placementWidth` before trusting the view's
    /// current content/height to match that frame. This is the hook later
    /// tasks (the tiling reconciler) use to catch a stale or mismatched
    /// pin — e.g. a width probed during a binary search that was never
    /// followed by a final `measuredHeight(forWidth:)` call at the width the
    /// view actually ends up placed at.
    private(set) var lastMeasuredWidth: CGFloat?

    required init(rootView: AnyView) {
        baseRootView = rootView
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = false
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }

    /// Height the row wants at `width`. Re-wraps the root view in a
    /// fixed-width frame pinned to `width` and reads the resulting intrinsic
    /// content size, which SwiftUI recomputes synchronously. The pinned-width
    /// wrapper becomes the view's displayed content, matching the frame the
    /// tiling layout will place the view at; `lastMeasuredWidth` is updated to
    /// `width` so callers can later verify the view is still pinned to the
    /// width they expect.
    ///
    /// A non-positive `width` is degenerate (e.g. a transient 0 during a
    /// window resize) and is rejected: this method returns `0` without
    /// touching `rootView` or `lastMeasuredWidth`, leaving the view pinned to
    /// whatever width (if any) it was last successfully measured at, rather
    /// than silently corrupting its displayed content by pinning it to a
    /// zero/negative-width frame.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        rootView = AnyView(baseRootView.frame(width: width, alignment: .topLeading))
        lastMeasuredWidth = width
        return intrinsicContentSize.height
    }
}
