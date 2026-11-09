import SwiftUI

/// Small key-cap pill used in the dialog's footer. Mirrors the design's
/// `.fs-kbd` style: minimum 16px wide, 16px tall, soft border, dim text.
struct SearchKbd: View {
    let label: String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Text(label)
            .font(scale.captionFont)
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, scale.space[1])
            .frame(minWidth: 16, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                    .fill(theme.color("bg-3"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                    .strokeBorder(theme.color("line-soft"), lineWidth: 0.5)
            )
    }
}
