import SwiftUI

struct InAppNotificationStack: View {
    let store: InAppNotificationStore
    let worktreeID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = store.notifications(in: worktreeID)
        let nextExpiry = entries.filter { $0.pausedAt == nil }.compactMap(\.expiresAt).min()
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(entries) { entry in
                InAppNotificationBanner(message: entry.message, detail: entry.detail,
                                        severity: entry.severity,
                                        actionTitle: entry.cancel == nil ? nil : "Cancel",
                                        action: { store.cancel(entry.id) }, dismiss: { store.dismiss(entry.id) })
                    .onHover { store.setPaused($0, id: entry.id) }
                    .onDisappear { store.setPaused(false, id: entry.id) }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: entries.map(\.id))
        .task(id: nextExpiry) {
            guard let nextExpiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, nextExpiry.timeIntervalSinceNow))) } catch { return }
            store.expire()
        }
    }
}

struct InAppNotificationBanner: View {
    let message: String
    var detail: String? = nil
    let severity: InAppNotificationSeverity
    var actionTitle: String? = nil
    var action: () -> Void = {}
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    private var color: Color {
        theme.color(severity == .error ? "del" : severity == .success ? "add" : "accent")
    }

    private var symbol: String {
        switch severity {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .information, .progress: "info.circle.fill"
        }
    }

    private var messageText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(3)
                .help(message)
            if let detail {
                Text(detail)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(2)
                    .help(detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        HStack(spacing: 8) {
            if severity == .progress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            }
            if actionTitle != nil, severity != .progress {
                Button(action: action) { messageText.contentShape(Rectangle()) }
            } else {
                messageText
            }
            if let actionTitle {
                Group {
                    if severity == .progress {
                        Button(actionTitle, action: action).keyboardShortcut(.cancelAction)
                    } else {
                        Button(actionTitle, action: action)
                    }
                }
                .foregroundStyle(theme.color("accent"))
                .font(scale.metaFont)
            }
            if severity != .progress {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(scale.glyphFont)
                        .foregroundStyle(theme.color("fg-muted"))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss notification")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(color.opacity(0.12).background(theme.color("bg-1")))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).stroke(color.opacity(0.3), lineWidth: 0.75))
        .compositingGroup()
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-app-notification-banner")
    }
}
