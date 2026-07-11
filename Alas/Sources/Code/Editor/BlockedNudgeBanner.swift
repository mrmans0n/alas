import SwiftUI
import AppKit

/// Non-blocking banner shown above the editor when the file's language
/// server binary carries `com.apple.quarantine` — the xattr Tahoe's
/// Gatekeeper checks before allowing a GUI-app spawn. Remediation is
/// in-app: the Allow button calls `removexattr` and re-assesses. We
/// never send users to System Settings → Privacy & Security because
/// that pane is only populated once the OS has already logged a
/// rejected spawn; our pre-flight skips the spawn, so the pane is
/// empty when users land there. Dismissal is per-`realPath` and
/// persisted in `AppConfig.code.dismissedInstallNudges` under the
/// `blocked:<realPath>` namespace.
struct BlockedNudgeBanner: View {
    let appState: AppState
    let absolutePath: String

    @Environment(\.theme) var theme
    @State private var remediationState: RemediationState = .idle

    enum RemediationState: Equatable {
        case idle
        case running
        case error(String)
    }

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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(nudge.displayName) language server blocked by macOS Gatekeeper")
                    .font(.system(size: 12.5))
                if case .error(let message) = remediationState {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            Spacer()
            if remediationState == .running {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 12, height: 12)
            } else {
                Button("Allow") {
                    Task { await remediate(nudge: nudge) }
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.color("fg"))
            }
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

    private func remediate(nudge: BlockedNudgeData) async {
        remediationState = .running
        let outcome = await GatekeeperRemediator().remediate(realPath: nudge.realPath)
        switch outcome {
        case .allowed:
            remediationState = .idle
            // Wake up LSP for any open buffers in this language so
            // diagnostics/hover start without a manual reopen.
            appState.lsp.invalidateAvailabilityCache(forLanguage: nudge.language)
            appState.tabs.reopenLSPDocuments(forLanguage: nudge.language)
        case .stillBlocked:
            remediationState = .error("Quarantine removed but \(nudge.displayName) is still blocked. Try reinstalling it.")
        case .failed(let message):
            remediationState = .error(message)
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
