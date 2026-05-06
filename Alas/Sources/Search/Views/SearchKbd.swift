import SwiftUI

/// Small key-cap pill used in the dialog's footer. Mirrors the design's
/// `.fs-kbd` style: minimum 16px wide, 16px tall, soft border, dim text.
struct SearchKbd: View {
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 3)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(theme.color("bg-3"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(theme.color("line-soft"), lineWidth: 0.5)
            )
    }
}
