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
    /// tiling layout will place the view at.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        rootView = AnyView(baseRootView.frame(width: width, alignment: .topLeading))
        return intrinsicContentSize.height
    }
}
