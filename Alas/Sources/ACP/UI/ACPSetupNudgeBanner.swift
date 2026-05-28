import SwiftUI

struct ACPSetupNudgeBanner: View {
    let agentID: String
    let agentDisplayName: String
    let installer: ACPAdapterInstaller
    let onDismiss: () -> Void
    /// Called after a successful install. Lets the parent re-run setup
    /// check + attach so the chat connects without a manual reload.
    let onInstalled: () async -> Void
    @State private var status: Status = .idle
    @Environment(\.theme) private var theme

    enum Status: Equatable { case idle, installing, installed, error(String) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: leadingIcon)
                .font(.system(size: 11))
                .foregroundStyle(leadingTint)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
            Spacer()
            if status == .installing {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 12, height: 12)
            }
            if showsInstallButton {
                Button(installButtonTitle) { runInstall() }
                    .disabled(status == .installing)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(bannerBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    private var leadingIcon: String {
        switch status {
        case .installed: return "checkmark.circle.fill"
        case .error:     return "exclamationmark.triangle.fill"
        default:         return "info.circle"
        }
    }
    private var leadingTint: Color {
        switch status {
        case .installed: return theme.color("add")
        case .error:     return theme.color("del")
        default:         return theme.color("fg-faint")
        }
    }
    private var bannerBg: Color {
        switch status {
        case .installed: return theme.color("add").opacity(0.10)
        case .error:     return theme.color("del").opacity(0.10)
        default:         return theme.color("bg-1").opacity(0.6)
        }
    }
    private var message: String {
        switch status {
        case .idle:                 return "\(agentDisplayName) requires the ACP adapter to be installed."
        case .installing:           return "Installing \(agentDisplayName) adapter…"
        case .installed:            return "\(agentDisplayName) adapter installed — connecting…"
        case .error(let detail):    return "Install failed: \(detail)"
        }
    }
    private var showsInstallButton: Bool {
        switch status {
        case .idle, .error: return true
        default:            return false
        }
    }
    private var installButtonTitle: String {
        if case .error = status { return "Retry" }
        return "Install"
    }

    private func runInstall() {
        status = .installing
        Task {
            do {
                try await installer.install()
                await MainActor.run { status = .installed }
                await onInstalled()
            } catch {
                await MainActor.run { status = .error(error.localizedDescription) }
            }
        }
    }
}
