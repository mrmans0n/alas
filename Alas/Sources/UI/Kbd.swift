import SwiftUI

struct Kbd: View {
    let label: String
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Text(label)
            .font(scale.caption.font(weight: .regular, design: .monospaced))
            .padding(.horizontal, scale.space[1])
            .frame(height: 16)
            .background(theme.color("bg-4"))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.small)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .foregroundColor(theme.color("fg-muted"))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
    }
}
