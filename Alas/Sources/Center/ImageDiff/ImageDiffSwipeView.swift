import SwiftUI

/// Single canvas. `after` painted full; `before` clipped to the left of a
/// draggable vertical handle. Handle default at 50%, clamped to canvas
/// bounds.
///
/// Both images are placed top-left on a shared "union" canvas sized to
/// `max(beforeW, afterW) × max(beforeH, afterH)` at their natural pixel
/// dimensions, then the union canvas is scaled to fit the viewport. The
/// handle position is in viewport coordinates, so dragging spans the full
/// width including any letter-boxed space around the union canvas.
struct ImageDiffSwipeView: View {
    let before: NSImage
    let after: NSImage
    @State private var handleFraction: CGFloat = 0.5
    @Environment(\.theme) private var theme

    static func clampFraction(_ raw: CGFloat) -> CGFloat {
        min(1.0, max(0.0, raw))
    }

    var body: some View {
        GeometryReader { proxy in
            let geom = UnionCanvasGeometry(
                before: before.size, after: after.size, viewport: proxy.size
            )
            let handleX = handleFraction * proxy.size.width
            // Convert the handle x to union-canvas local coords. The
            // mask clips the `before` image to the strip x ∈ [0, clipX]
            // of the union canvas. Outside the union canvas, the handle
            // is still draggable but the clip has no visual effect.
            let clipX = max(0, min(geom.scaledUnionSize.width, handleX - geom.origin.x))

            ZStack(alignment: .topLeading) {
                ImageCheckerboardBackground()
                ZStack(alignment: .topLeading) {
                    Image(nsImage: after)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: after.size.width * geom.scale,
                            height: after.size.height * geom.scale
                        )
                    Image(nsImage: before)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: before.size.width * geom.scale,
                            height: before.size.height * geom.scale
                        )
                        .mask(
                            Rectangle()
                                .frame(
                                    width: clipX,
                                    height: geom.scaledUnionSize.height
                                )
                                .position(
                                    x: clipX / 2,
                                    y: geom.scaledUnionSize.height / 2
                                )
                        )
                }
                .frame(
                    width: geom.scaledUnionSize.width,
                    height: geom.scaledUnionSize.height,
                    alignment: .topLeading
                )
                .offset(x: geom.origin.x, y: geom.origin.y)

                handle(at: handleX, height: proxy.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleFraction = Self.clampFraction(
                            value.location.x / max(proxy.size.width, 1)
                        )
                    }
            )
            .overlay(alignment: .topLeading) {
                Text("Before")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5))
                    .cornerRadius(3)
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Text("After")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5))
                    .cornerRadius(3)
                    .padding(6)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .shadow(radius: 2)
        }
        .position(x: x, y: height / 2)
    }
}
