import SwiftUI

/// Single canvas. `before` painted opaque; `after` painted on top with
/// adjustable opacity. Slider labelled "Before … After" so direction is
/// obvious without legends.
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
        ZStack {
            ImageCheckerboardBackground()
            Image(nsImage: before)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
            Image(nsImage: after)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .opacity(opacity)
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
