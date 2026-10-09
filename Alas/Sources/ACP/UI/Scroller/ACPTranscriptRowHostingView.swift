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
    /// width directly on the root view does. Mutable so `updateRootView(_:)`
    /// can replace it: callers MUST go through that method rather than
    /// assigning `rootView` directly, or this pristine copy goes stale and
    /// the next `measuredHeight(forWidth:)` call re-pins the OLD content.
    private var baseRootView: AnyView

    /// Whether the pointer is over this row, published to its content as
    /// `\.acpRowHover`. One tracking area per row replaces a hover view per
    /// row element: each platform view inside a row costs a layout pass when
    /// the row mounts, which is on the scroll path.
    let hover = ACPRowHoverState()

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

    /// Set when the pool revives this view from its parked cache. Its content
    /// may have changed size while it was detached, and its callbacks were cut
    /// while it was parked, so the next mount must measure it even though
    /// `lastMeasuredWidth` still matches. `measuredHeight(forWidth:)` clears it.
    private(set) var needsRemeasure = false

    func markNeedsRemeasure() {
        needsRemeasure = true
    }

    /// `translatesAutoresizingMaskIntoConstraints = false` alongside
    /// `sizingOptions = [.intrinsicContentSize]` is NSHostingView's
    /// "the container decides my frame, I only report a size" configuration,
    /// which is exactly the contract the tiling reconciler wants: it reads
    /// `measuredHeight(forWidth:)` and then assigns `frame` directly.
    ///
    /// Opting a view out of the autoresizing bridge normally hands its frame
    /// to the constraint engine, which — with no constraints describing this
    /// view — would be the classic "every row collapses to the origin"
    /// failure. It does not happen here, and not by luck: the entire
    /// ancestor chain (`ACPTranscriptDocumentView`, the clip view, the
    /// scroll view) keeps `translatesAutoresizingMaskIntoConstraints ==
    /// true` and holds no constraints, so nothing ever runs a constraint
    /// solve over this subtree. Measured inside a real key window after
    /// `layoutIfNeeded()`: these views report `hasAmbiguousLayout == false`
    /// and zero constraints, and their assigned frames survive repeated
    /// layout passes untouched. `ACPTranscriptScrollerReconcilerWindowLayoutTests`
    /// pins that down, so a future change that does introduce constraints
    /// into this subtree fails a test instead of silently blanking the
    /// transcript.
    private static func withRowHover(_ view: AnyView, _ hover: ACPRowHoverState) -> AnyView {
        AnyView(view.environment(\.acpRowHover, hover))
    }

    required init(rootView: AnyView) {
        let rootView = Self.withRowHover(rootView, hover)
        baseRootView = rootView
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = false
        sizingOptions = [.intrinsicContentSize]
        // Rows sit inside a scroll view, never against a window edge. With
        // safe-area tracking on, every scroll tick moved each mounted row's
        // window geometry, re-derived its (always empty) insets, and paid a
        // full SwiftUI layout per row per frame.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Added once: an `.inVisibleRect` area follows the view by itself, and
    /// replacing it under the pointer makes AppKit send a fresh exit/enter
    /// pair, which re-rendered the row, which re-ran this, in a loop.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !trackingAreas.contains(where: { $0.owner === hover }) else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: hover
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hover.isHovered = false }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
    }

    /// Replaces the row's content. This is the ONLY correct way to swap in
    /// new SwiftUI content on an already-mounted row: assigning `rootView`
    /// directly (AppKit's own setter) leaves `baseRootView` stale, so the
    /// next `measuredHeight(forWidth:)` call would re-pin the OLD content,
    /// silently reverting the update.
    ///
    /// If the view has already been measured at some width, the new content
    /// is immediately re-pinned to that same width so the displayed view
    /// stays consistent with `lastMeasuredWidth` until the next measurement;
    /// otherwise the new content is shown unpinned.
    func updateRootView(_ newRootView: AnyView) {
        let newRootView = Self.withRowHover(newRootView, hover)
        baseRootView = newRootView
        if let width = lastMeasuredWidth {
            rootView = AnyView(newRootView.frame(width: width, alignment: .topLeading))
        } else {
            rootView = newRootView
        }
    }

    /// Height the row wants at `width`. Only changes the fixed-width wrapper
    /// when the width changes, but always reads the current intrinsic content
    /// size so streaming and image updates still remeasure. The pinned-width
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
        needsRemeasure = false
        if lastMeasuredWidth != width {
            lastMeasuredWidth = width
            rootView = AnyView(baseRootView.frame(width: width, alignment: .topLeading))
        }
        return intrinsicContentSize.height
    }
}

/// Pointer-over state for one transcript row. The tracking area's owner, so
/// it receives `mouseEntered:`/`mouseExited:` without touching the hosting
/// view's own event handling.
@MainActor
final class ACPRowHoverState: NSObject, ObservableObject {
    @Published var isHovered = false

    @objc func mouseEntered(_ event: NSEvent) { isHovered = true }
    @objc func mouseExited(_ event: NSEvent) { isHovered = false }
}

extension EnvironmentValues {
    @Entry var acpRowHover: ACPRowHoverState?
}

extension View {
    /// Hover over the whole transcript row this view sits in, falling back
    /// to the view's own bounds outside a transcript row.
    func acpRowHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ACPRowHoverModifier(action: action))
    }
}

private struct ACPRowHoverModifier: ViewModifier {
    @Environment(\.acpRowHover) private var rowHover
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if let rowHover {
            content.modifier(Observing(hover: rowHover, action: action))
        } else {
            content.acpTrackingHover(action)
        }
    }

    /// Reports changes only. An `onReceive` on `$isHovered` resubscribed on
    /// every render and `@Published` replays its value to each new
    /// subscriber, so a hovered row re-rendered itself forever.
    private struct Observing: ViewModifier {
        @ObservedObject var hover: ACPRowHoverState
        let action: (Bool) -> Void

        func body(content: Content) -> some View {
            content.onChange(of: hover.isHovered, initial: true) { _, inside in action(inside) }
        }
    }
}
