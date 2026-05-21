import SwiftUI

/// Single canvas. `after` painted full; `before` clipped to the left of a
/// draggable vertical handle. Handle default at 50%, clamped to canvas
/// bounds.
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
            let w = proxy.size.width
            let handleX = handleFraction * w

            ZStack(alignment: .topLeading) {
                ImageCheckerboardBackground()
                Image(nsImage: after)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                Image(nsImage: before)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .mask(
                        Rectangle()
                            .frame(width: handleX, height: proxy.size.height)
                            .position(x: handleX / 2, y: proxy.size.height / 2)
                    )
                handle(at: handleX, height: proxy.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleFraction = Self.clampFraction(value.location.x / max(w, 1))
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
