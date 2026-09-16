import SwiftUI

struct DragHandle: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// Cumulative translation along `axis` since drag start, measured in the
    /// global coordinate space. Global space stays fixed while the handle
    /// moves under the cursor; measuring in `.local` space fed the handle's
    /// own movement back into the gesture and made dividers oscillate.
    /// Callers anchor on the width captured at drag start:
    /// `width = clamp(startWidth ± translation)`.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    init(
        axis: Axis,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.axis = axis
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    /// Hover or drag draw a slightly thicker, brighter line so the affordance
    /// still reads without inflating the resting hit target.
    private var active: Bool { hovering || dragging }

    /// Total width of the invisible grab zone, centered on the drawn
    /// divider. Wider than the 4pt column the layout actually reserves —
    /// an overlay isn't clipped to its base view's bounds, so it can claim
    /// extra hit-testing room from the neighboring panes without widening
    /// the real divider (which is what made it look thick before).
    private var hitTargetLength: CGFloat { 12 }

    var body: some View {
        // Only a 1-2pt hairline is ever drawn, over a 4pt column filled
        // with the page background — `Color.clear` there let the window's
        // own background show through as a visible gap between the panes.
        ZStack {
            theme.color("bg-1")
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(active ? 0.9 : 0.5))
                .frame(
                    width: axis == .horizontal ? (active ? 2 : 1) : nil,
                    height: axis == .vertical ? (active ? 2 : 1) : nil
                )
        }
        .frame(
            width: axis == .horizontal ? 4 : nil,
            height: axis == .vertical ? 4 : nil
        )
        .overlay(hitTarget)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: active)
        .onDisappear {
            if cursorPushed {
                popCursor()
            }
        }
    }

    // ponytail: the extra reach on the side of the *later*-drawn neighbor
    // (e.g. into a Ghostty terminal hosted in the center pane) wins hit
    // priority here because this handle paints after it; the extra reach
    // into an *earlier* sibling can, in principle, lose that fight to a
    // real AppKit view on top of it. In this three-pane layout the neighbor
    // that could matter (the terminal) is always the sibling drawn before
    // one handle and after the other, so both handles keep working — the
    // one caveat is a live drag always keeps tracking once started, so
    // this only affects where a fresh grab can begin. Revisit with a real
    // NSSplitView-style divider if a terminal edge turns out to eat clicks.
    private var hitTarget: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: axis == .horizontal ? hitTargetLength : nil,
                height: axis == .vertical ? hitTargetLength : nil
            )
            .contentShape(Rectangle())
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    pushCursor()
                } else if !dragging {
                    popCursor()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        let translation = axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        onDragChanged(translation)
                    }
                    .onEnded { _ in
                        dragging = false
                        onDragEnded()
                        if !hovering {
                            popCursor()
                        }
                    }
            )
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        switch axis {
        case .horizontal: NSCursor.resizeLeftRight.push()
        case .vertical:   NSCursor.resizeUpDown.push()
        }
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
