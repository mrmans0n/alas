import SwiftUI

struct EmptyState: View {
    let onAddProject: () -> Void
    /// Set when shown from Settings > Debug; adds a button back to the workspace.
    var onExitPreview: (() -> Void)? = nil
    @State private var flock = WelcomeFlock()

    var body: some View {
        ZStack(alignment: .topLeading) {
            WelcomeSky(flock: flock)
            WindowDragHandle()
            // The headline is drawn by WelcomeSky so birds fly over it; the sky
            // lays it out, and the glass, from this button's size and offset.
            Button(action: onAddProject) {
                let shape = RoundedRectangle(cornerRadius: WelcomeFlock.buttonCornerRadius)
                Label("Add a project to start", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { flock.buttonSize = $0 }
                    .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
                    .overlay(BorderBeam(shape: shape))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .offset(y: WelcomeFlock.buttonOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let onExitPreview {
                AlasButton(title: "Exit preview", icon: "xmark", style: .normal, action: onExitPreview)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
                    .padding(.top, 8)
            }

            TrafficLights()
                .padding(.leading, 12)
                .padding(.top, 10)
        }
        .onContinuousHover { phase in
            if case .active(let point) = phase { flock.cursor = point } else { flock.cursor = nil }
        }
    }
}

/// Sunset-colored comet that circles a shape's border, with a soft glow.
private struct BorderBeam<S: InsettableShape>: View {
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let cycleSeconds = 3.2
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
            let beam = gradient(phase: phase)
            ZStack {
                shape.strokeBorder(beam, lineWidth: 3).blur(radius: 4)
                shape.strokeBorder(beam, lineWidth: 1.25)
            }
        }
        .allowsHitTesting(false)
    }

    private func gradient(phase: Double) -> AngularGradient {
        let start = Angle.degrees(phase * 360)
        return AngularGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.60),
                .init(color: Color(red: 0.55, green: 0.40, blue: 1.00).opacity(0.6), location: 0.75),
                .init(color: Color(red: 1.00, green: 0.45, blue: 0.70), location: 0.88),
                .init(color: Color(red: 1.00, green: 0.80, blue: 0.45), location: 0.97),
                .init(color: .clear, location: 1.00)
            ],
            center: .center,
            startAngle: start,
            endAngle: start + .degrees(360)
        )
    }
}
