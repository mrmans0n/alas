import SwiftUI
import AppKit

/// Non-blocking banner shown above the editor when the file's language
/// server is blocked by macOS Gatekeeper. Dismissal is per-`realPath` and
/// persisted in `AppConfig.code.dismissedInstallNudges` under the
/// `blocked:<realPath>` namespace, so a `brew upgrade` (different inode,
/// different cache result) re-shows it.
struct BlockedNudgeBanner: View {
    let appState: AppState
    let absolutePath: String

    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let nudge = nudgeData {
                bannerRow(nudge: nudge)
            }
        }
    }

    private func bannerRow(nudge: BlockedNudgeData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundColor(theme.color("fg-dim"))
            Text("\(nudge.displayName) language server blocked by macOS — approve it to enable diagnostics")
                .font(.system(size: 12.5))
            Spacer()
            Button("Open Privacy & Security") {
                openPrivacyAndSecurity()
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.color("fg"))
            Button(action: { dismiss(key: nudge.dismissalKey) }) {
                Image(systemName: "xmark")
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1"))
        .overlay(Rectangle()
            .frame(height: 0.5)
            .foregroundColor(theme.color("line")),
            alignment: .bottom)
    }

    private var nudgeData: BlockedNudgeData? {
        let registry = LanguageServerRegistry(userDefined: appState.config.code.languageServers)
        let resolver = BlockedLanguageServerNudgeResolver(
            registry: registry,
            dismissedKeys: appState.config.code.dismissedInstallNudges
        )
        return resolver.nudgeData(forAbsolutePath: absolutePath)
    }

    private func openPrivacyAndSecurity() {
        // Anchored URL works on Sequoia+. If a future macOS removes the
        // anchor, the bare URL still opens the right pane.
        let anchored = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Allowed_eXecution")!
        let plain = URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        if !NSWorkspace.shared.open(anchored) {
            NSWorkspace.shared.open(plain)
        }
    }

    private func dismiss(key: String) {
        var dismissed = appState.config.code.dismissedInstallNudges
        if !dismissed.contains(key) {
            dismissed.append(key)
            appState.config.code.dismissedInstallNudges = dismissed
            appState.saveConfig()
        }
    }
}
