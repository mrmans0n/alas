import AppKit

/// What the diff scroller's pool and reconciler need from a mounted row,
/// whether it is a SwiftUI host or a plain AppKit view.
@MainActor
protocol AppKitDiffRowView: NSView {
    var representedRowID: String? { get set }
    var onIntrinsicSizeInvalidated: ((String) -> Void)? { get set }
    var lastMeasuredWidth: CGFloat? { get }
    func measuredHeight(forWidth width: CGFloat) -> CGFloat
    func attach(to documentView: NSView)
    func suppressNextLayoutForStableScroll()
}

/// A row rendered by a plain AppKit view instead of a SwiftUI host.
struct AppKitDiffNativeRow {
    let make: @MainActor () -> any AppKitDiffRowView
    /// Applies the row's content; runs on mount and whenever the row's
    /// equality token changes.
    let configure: @MainActor (any AppKitDiffRowView) -> Void
}
