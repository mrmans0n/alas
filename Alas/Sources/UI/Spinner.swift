import SwiftUI

struct Spinner: View {
    var lineWidth: CGFloat = 2
    var duration: Double = 0.8
    var color: Color?

    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(color ?? theme.color("accent"), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(
                    context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration * 360
                ))
        }
    }
}
