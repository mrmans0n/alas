import SwiftUI

struct Kbd: View {
    let label: String
    @Environment(\.theme) var theme

    var body: some View {
        Text(label)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(theme.color("bg-4"))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .foregroundColor(theme.color("fg-muted"))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
