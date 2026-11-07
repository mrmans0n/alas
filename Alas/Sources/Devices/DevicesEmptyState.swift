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

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(theme.color("fg-faint"))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.color("fg"))
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color(detailTone))
            }
            if let action {
                AlasButton(title: action.title, icon: action.icon, style: .primary, action: action.run)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
