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
                InAppNotificationBanner(message: entry.message, severity: entry.severity,
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
    let severity: InAppNotificationSeverity
    var actionTitle: String? = nil
    var action: () -> Void = {}
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

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
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.color("fg"))
            .lineLimit(3)
            .help(message)
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
                .font(.system(size: 12))
            }
            if severity != .progress {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss notification")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.12).background(theme.color("bg-1")))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 0.75))
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-app-notification-banner")
    }
}
