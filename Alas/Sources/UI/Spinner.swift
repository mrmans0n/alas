import SwiftUI

struct Spinner: View {
    var lineWidth: CGFloat = 2
    var duration: Double = 0.8
    var color: Color?

    @State private var angle: Double = 0
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color ?? theme.color("accent"), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .animation(.linear(duration: duration).repeatForever(autoreverses: false), value: angle)
            .onAppear { angle = 360 }
    }
}
