import SwiftUI

struct ACPSetupNudgeBanner: View {
    @Environment(\.designScale) private var scale
    let agentDisplayName: String
    var targetHost: String? = nil
    var mode: ACPSetupNudgeMode = .install
    let status: Status
    let onDismiss: () -> Void
    let onInstall: () -> Void

    @Environment(\.theme) private var theme

    enum Status: Equatable { case idle, installing, installed, error(String) }

    var body: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: leadingIcon)
                .font(scale.metaFont)
                .foregroundStyle(leadingTint)
            Text(message)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .textSelection(.enabled)
            Spacer()
            if status == .installing {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 12, height: 12)
            }
            if showsInstallButton {
                Button(installButtonTitle, action: onInstall)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
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
        case .idle:
            return ACPSetupNudgeBannerCopy.idleMessage(
                mode: mode, agentDisplayName: agentDisplayName, targetHost: targetHost)
        case .installing:
            return ACPSetupNudgeBannerCopy.installingMessage(
                mode: mode, agentDisplayName: agentDisplayName, targetHost: targetHost)
        case .installed:
            return ACPSetupNudgeBannerCopy.installedMessage(
                mode: mode, agentDisplayName: agentDisplayName, targetHost: targetHost)
        case .error(let detail):
            return ACPSetupNudgeBannerCopy.errorMessage(mode: mode, detail: detail)
        }
    }
    private var showsInstallButton: Bool {
        switch status {
        case .idle, .error: return true
        default:            return false
        }
    }
    private var isErrored: Bool {
        if case .error = status { return true }
        return false
    }

    private var installButtonTitle: String {
        ACPSetupNudgeBannerCopy.installButtonTitle(mode: mode, errored: isErrored)
    }
}

/// Shared by transcript tabs. The update and its result outlive any banner.
@MainActor @Observable
final class ACPTranscriptAdapterUpdates {
    private struct Update {
        let latest: String
        let status: ACPSetupNudgeBanner.Status
    }

    private var updates: [ACPAdapterUpdateKey: Update] = [:]

    func status(for key: ACPAdapterUpdateKey, latest: String) -> ACPSetupNudgeBanner.Status {
        guard let update = updates[key] else { return .idle }
        if update.status == .installing { return .installing }
        return update.latest == latest ? update.status : .idle
    }

    func installedVersion(for key: ACPAdapterUpdateKey) -> String? {
        guard let update = updates[key], update.status == .installed else { return nil }
        return update.latest
    }

    @discardableResult
    func start(
        key: ACPAdapterUpdateKey,
        latest: String,
        install: @escaping @MainActor () async throws -> Void,
        onInstalled: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard updates[key]?.status != .installing else { return nil }
        updates[key] = Update(latest: latest, status: .installing)
        return Task {
            do {
                try await install()
            } catch {
                updates[key] = Update(latest: latest, status: .error(error.localizedDescription))
                return
            }
            updates[key] = Update(latest: latest, status: .installed)
            await onInstalled()
        }
    }
}
