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

    init(
        axis: Axis,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping () -> Void = {}
    ) {
        self.axis = axis
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var body: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .vertical ? 6 : nil
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
            .onDisappear {
                if cursorPushed {
                    popCursor()
                }
            }
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
