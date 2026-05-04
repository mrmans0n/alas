import SwiftUI

struct AlasToggle: View {
    @Binding var on: Bool
    @Environment(\.theme) var theme

    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? theme.color("accent") : theme.color("bg-4"))
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .animation(.easeInOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
    }
}
