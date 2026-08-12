import SwiftUI

enum DialogContainerLayout {
    static let defaultWidth: CGFloat = 480
    static let projectWidth: CGFloat = 640
}

struct DialogContainer<Content: View, HeaderAccessory: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    @ViewBuilder let headerAccessory: () -> HeaderAccessory
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
        @ViewBuilder headerAccessory: @escaping () -> HeaderAccessory,
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
        self.headerAccessory = headerAccessory
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
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12))
                            .foregroundColor(theme.color("fg-dim"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                headerAccessory()
            }
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

extension DialogContainer where HeaderAccessory == EmptyView {
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
        self.init(
            title: title,
            subtitle: subtitle,
            width: width,
            headerAccessory: { EmptyView() },
            content: content,
            cancelTitle: cancelTitle,
            confirmTitle: confirmTitle,
            confirmStyle: confirmStyle,
            onCancel: onCancel,
            onConfirm: onConfirm,
            confirmEnabled: confirmEnabled
        )
    }
}

/// Icon-only affordance rendered in a dialog header's top-right corner.
struct DialogHeaderIconButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 13, color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? theme.color("bg-3") : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(hovering ? theme.color("line") : Color.clear, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        // Pull the 26pt hit target up so the glyph optically centers on the title line.
        .padding(.top, -4)
        .onHover { hovering = $0 }
        .help(tooltip)
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
