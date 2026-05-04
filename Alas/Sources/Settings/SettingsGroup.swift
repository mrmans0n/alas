import SwiftUI

struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 14)
            }
            content()
        }
        .padding(.vertical, 18)
    }
}
