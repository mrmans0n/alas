import SwiftUI

/// Single canvas. `before` painted opaque; `after` painted on top with
/// adjustable opacity. Slider labelled "Before … After" so direction is
/// obvious without legends.
///
/// Both images are placed top-left on a shared "union" canvas sized to
/// `max(beforeW, afterW) × max(beforeH, afterH)` at their natural pixel
/// dimensions, then the union canvas is scaled to fit the viewport.
/// This way an image that grew or shrank between revisions visibly does
/// so in the overlay, instead of both being silently fit to the same box.
struct ImageDiffOverlayView: View {
    let before: NSImage
    let after: NSImage
    @State private var opacity: Double = 0.5
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            canvas
            slider
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let geom = UnionCanvasGeometry(
                before: before.size, after: after.size, viewport: proxy.size
            )
            ZStack {
                ImageCheckerboardBackground()
                ZStack(alignment: .topLeading) {
                    Image(nsImage: before)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: before.size.width * geom.scale,
                            height: before.size.height * geom.scale
                        )
                    Image(nsImage: after)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: after.size.width * geom.scale,
                            height: after.size.height * geom.scale
                        )
                        .opacity(opacity)
                }
                .frame(
                    width: geom.scaledUnionSize.width,
                    height: geom.scaledUnionSize.height,
                    alignment: .topLeading
                )
                .offset(x: geom.origin.x, y: geom.origin.y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    private var slider: some View {
        HStack(spacing: 8) {
            Text("Before")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Slider(value: $opacity, in: 0...1)
            Text("After")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.4), alignment: .top)
    }
}
