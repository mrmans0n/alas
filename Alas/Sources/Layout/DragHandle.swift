import SwiftUI

struct DragHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let onDrag: (CGFloat) -> Void   // delta
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(
                width: axis == .horizontal ? 4 : nil,
                height: axis == .vertical ? 4 : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onContinuousHover { _ in
                NSCursor.resizeLeftRight.set()
            }
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        onDrag(delta)
                    }
            )
            .background(hovering ? Color.white.opacity(0.05) : Color.clear)
    }

    static func clamp(value: Double, min minVal: Double, max maxVal: Double) -> Double {
        max(minVal, min(maxVal, value))
    }
}
