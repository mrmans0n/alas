import AppKit
import SwiftUI

enum DialogContainerLayout {
    static let defaultWidth: CGFloat = 480
    static let projectWidth: CGFloat = 640

    /// Everything a dialog needs on screen besides its body: the header, the
    /// footer, and breathing room at the screen's edges. Deliberately a
    /// slight over-estimate — reserving too much only makes a dialog scroll
    /// a little sooner, while reserving too little is the bug this exists to
    /// prevent.
    static let chromeHeight: CGFloat = 200

    /// The body never shrinks below this, even on a very short screen. A
    /// dialog showing two fields through a letterbox is worse than one that
    /// runs slightly past the edge.
    static let minimumBodyHeight: CGFloat = 240

    /// How tall the scrolling body may get on a screen of `availableHeight`.
    /// Header and footer sit outside it, so they stay reachable no matter
    /// how much the body grows.
    static func bodyMaxHeight(availableHeight: CGFloat) -> CGFloat {
        max(minimumBodyHeight, availableHeight - chromeHeight)
    }

    /// Usable height of the screen the dialog is on. Falls back to a common
    /// laptop height when there is no screen to ask, which is the case in
    /// tests and when running headless.
    @MainActor
    static var availableScreenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? 900
    }
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
    let cancelEnabled: Bool
    /// Quiet status text at the footer's leading edge, opposite the buttons.
    let footerHint: String?

    @Environment(\.theme) var theme
    /// The body's natural height, as last laid out. Drives the cap below;
    /// zero until the first layout pass has measured it.
    @State private var measuredBodyHeight: CGFloat = 0

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
        confirmEnabled: Bool,
        cancelEnabled: Bool = true,
        footerHint: String? = nil
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
        self.cancelEnabled = cancelEnabled
        self.footerHint = footerHint
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

            // The body scrolls rather than growing without limit: a dialog
            // whose content expands (an optional section being opened, a
            // long form) must not push its own footer off the screen.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredBodyHeight = $0 }
            }
            .frame(height: bodyHeight)
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 8) {
                if let footerHint, !footerHint.isEmpty {
                    Text(footerHint)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                AlasButton(title: cancelTitle, style: .subtle, action: onCancel)
                    .disabled(!cancelEnabled)
                    .opacity(cancelEnabled ? 1 : 0.5)
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

    /// The body's height: its own, until that exceeds what the screen can
    /// show. Nil before the first measurement, which leaves the scroll view
    /// to size itself to its content for that pass.
    private var bodyHeight: CGFloat? {
        guard measuredBodyHeight > 0 else { return nil }
        return min(
            measuredBodyHeight,
            DialogContainerLayout.bodyMaxHeight(availableHeight: DialogContainerLayout.availableScreenHeight)
        )
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
        confirmEnabled: Bool,
        footerHint: String? = nil
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
            confirmEnabled: confirmEnabled,
            footerHint: footerHint
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
        .accessibilityLabel(tooltip)
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
