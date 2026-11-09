import SwiftUI

enum SettingsPaneStyle {
    /// The one title style every Settings pane shares.
    static let titleFont = Font.system(size: 18, weight: .semibold) // design-literal: settings pane title
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.designScale) private var scale
    let title: String?
    var verticalPadding: CGFloat = 18
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(scale.caption.font(weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, scale.space[4])
            }
            content()
        }
        .padding(.vertical, verticalPadding)
    }
}
