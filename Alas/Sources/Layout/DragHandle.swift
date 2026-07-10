import SwiftUI

struct DragHandle: View {
    enum Axis { case horizontal, vertical }

    struct DragState {
        let axis: Axis
        private var lastTranslation: CGFloat = 0

        init(axis: Axis) {
            self.axis = axis
        }

        mutating func changed(width: CGFloat, height: CGFloat) -> CGFloat {
            let cumulative = axis == .horizontal ? width : height
            let delta = cumulative - lastTranslation
            lastTranslation = cumulative
            return delta
        }

        mutating func ended() {
            lastTranslation = 0
        }
    }

    let axis: Axis
    /// Per-event delta (not cumulative). Caller adds it to current width and
    /// clamps. Sums to the same total a user expects from their cursor motion.
    let onDrag: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false
    @State private var dragState: DragState

    init(axis: Axis, onDrag: @escaping (CGFloat) -> Void, onEnded: @escaping () -> Void = {}) {
        self.axis = axis
        self.onDrag = onDrag
        self.onEnded = onEnded
        _dragState = State(initialValue: DragState(axis: axis))
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
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        dragging = true
                        let delta = dragState.changed(
                            width: value.translation.width,
                            height: value.translation.height
                        )
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        dragging = false
                        dragState.ended()
                        onEnded()
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

    nonisolated static func clamp(value: Double, min minVal: Double, max maxVal: Double) -> Double {
        max(minVal, min(maxVal, value))
    }
}
