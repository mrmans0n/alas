import SwiftUI

enum DialogContainerLayout {
    static let defaultWidth: CGFloat = 480
    static let projectWidth: CGFloat = 640
}

struct DialogContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    let cancelTitle: String
    let confirmTitle: String
    let confirmStyle: AlasButtonStyle
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let confirmEnabled: Bool

    @Environment(\.theme) var theme

    init(
        title: String,
        subtitle: String?,
        width: CGFloat = DialogContainerLayout.defaultWidth,
        @ViewBuilder content: @escaping () -> Content,
        cancelTitle: String,
        confirmTitle: String,
        confirmStyle: AlasButtonStyle,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        confirmEnabled: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.content = content
        self.cancelTitle = cancelTitle
        self.confirmTitle = confirmTitle
        self.confirmStyle = confirmStyle
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.confirmEnabled = confirmEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12))
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: cancelTitle, style: .subtle, action: onCancel)
                AlasButton(title: confirmTitle, style: confirmStyle, action: onConfirm)
                    .disabled(!confirmEnabled)
                    .opacity(confirmEnabled ? 1 : 0.5)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(theme.color("bg-2"))
            .overlay(Divider(), alignment: .top)
        }
        .frame(width: width)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.6), radius: 80, y: 30)
    }
}

struct DialogField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
            content()
        }
    }
}
