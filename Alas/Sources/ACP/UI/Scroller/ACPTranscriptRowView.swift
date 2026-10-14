import AppKit

/// What the transcript scroller needs from a mounted row: size invalidation,
/// width-keyed measurement, and a way to force a re-measure. The SwiftUI
/// hosting view and native (non-SwiftUI) row views both conform.
@MainActor
protocol ACPTranscriptRowView: NSView {
    var onIntrinsicSizeInvalidated: (() -> Void)? { get set }
    var lastMeasuredWidth: CGFloat? { get }
    var needsRemeasure: Bool { get }
    func markNeedsRemeasure()
    func measuredHeight(forWidth width: CGFloat) -> CGFloat
}

/// Builds and updates a native row view in place of a SwiftUI hosting view.
struct ACPTranscriptNativeRow {
    let make: @MainActor () -> any ACPTranscriptRowView
    let configure: @MainActor (any ACPTranscriptRowView) -> Void
}
