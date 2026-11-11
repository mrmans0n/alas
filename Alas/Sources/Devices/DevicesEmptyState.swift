import SwiftUI

/// The Devices tab's centered message: a symbol (or a spinner), a line, an
/// optional note and an optional button.
struct DevicesEmptyState: View {
    struct Action {
        let title: String
        var icon: String?
        let run: () -> Void
    }

    /// Nil shows a spinner.
    var symbol: String?
    let title: String
    var detail: String?
    var detailTone = "fg-dim"
    var action: Action?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: scale.space[3]) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light)) // design-literal: hero symbol
                    .foregroundStyle(theme.color("fg-faint"))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(LocalizedStringKey(title))
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg"))
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(scale.meta.font)
                    .foregroundStyle(theme.color(detailTone))
            }
            if let action {
                AlasButton(title: action.title, icon: action.icon, style: .primary, action: action.run)
                    .padding(.top, scale.space[1])
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(scale.space[5])
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
