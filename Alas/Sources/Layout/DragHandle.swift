import SwiftUI

struct DragHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    /// Per-event delta (not cumulative). Caller adds it to current width and
    /// clamps. Sums to the same total a user expects from their cursor motion.
    let onDrag: (CGFloat) -> Void
    @State private var hovering = false
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.001))
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onContinuousHover { _ in
                switch axis {
                case .horizontal: NSCursor.resizeLeftRight.set()
                case .vertical:   NSCursor.resizeUpDown.set()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        let cumulative = axis == .horizontal ? value.translation.width : value.translation.height
                        let delta = cumulative - lastTranslation
                        lastTranslation = cumulative
                        onDrag(delta)
                    }
                    .onEnded { _ in
                        lastTranslation = 0
                    }
            )
    }

    static func clamp(value: Double, min minVal: Double, max maxVal: Double) -> Double {
        max(minVal, min(maxVal, value))
    }
}
