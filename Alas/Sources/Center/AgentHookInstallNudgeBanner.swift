import SwiftUI

/// A lightweight install nudge shown inside an active terminal tab when a
/// supported hook-capable agent is detected and its hook is not installed.
/// Dismissal is per-agent and persisted in `AppConfig.harness.dismissedHookInstallNudges`.
struct AgentHookInstallNudgeBanner: View {
    let appState: AppState
    let terminalTab: TerminalTabState

    @Environment(\.theme) var theme
    @State private var installStatus: String? = nil
    @State private var resolvedNudgeKey: HookInstallNudgeKey?
    @State private var resolvedNudge: HookInstallNudge?

    private var nudgeKey: HookInstallNudgeKey {
        let sessionIds = terminalTab.root.leaves().map(\.sessionId)
        let detected = sessionIds.compactMap { appState.harness.activeHarnessBySession[$0] }
        var seen = Set<HarnessKind>()
        let uniqueDetected = detected.filter { seen.insert($0).inserted }
        return HookInstallNudgeKey(
            detectedHarnesses: uniqueDetected,
            dismissed: appState.config.harness.dismissedHookInstallNudges
        )
    }

    var body: some View {
        let currentNudgeKey = nudgeKey
        Group {
            if resolvedNudgeKey == currentNudgeKey, let nudge = resolvedNudge {
                bannerRow(nudge: nudge)
            }
        }
        .task(id: currentNudgeKey) {
            await refreshNudge(for: currentNudgeKey)
        }
    }

    private func bannerRow(nudge: HookInstallNudge) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(theme.color("fg-dim"))
            Text(nudge.title)
                .font(.system(size: 12.5))
            Spacer()
            if let status = installStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            AlasButton(title: nudge.actionTitle, style: .normal) {
                runInstall(for: nudge.agent)
            }
            Button(action: { dismiss(agent: nudge.agent) }) {
                Image(systemName: "xmark")
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1"))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(theme.color("line")),
            alignment: .bottom
        )
    }

    private func runInstall(for agent: AgentKind) {
        guard let installer = AgentInstallerRegistry().installer(for: agent) else { return }
        installStatus = "Installing..."
        Task {
            do {
                try await installer.install()
                await MainActor.run {
                    installStatus = nil
                    resolvedNudge = nil
                }
            } catch {
                await MainActor.run {
                    installStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func dismiss(agent: AgentKind) {
        var dismissed = appState.config.harness.dismissedHookInstallNudges
        if !dismissed.contains(agent.rawValue) {
            dismissed.append(agent.rawValue)
            appState.config.harness.dismissedHookInstallNudges = dismissed
            appState.saveConfig()
            resolvedNudge = nil
        }
    }

    private func refreshNudge(for key: HookInstallNudgeKey) async {
        guard !key.detectedHarnesses.isEmpty else {
            resolvedNudgeKey = key
            resolvedNudge = nil
            return
        }
        let nudge = await Task.detached(priority: .userInitiated) {
            let registry = AgentInstallerRegistry()
            return HookInstallNudgeResolver.resolve(
                detectedHarnesses: key.detectedHarnesses,
                dismissed: key.dismissed,
                installState: { agent in registry.installer(for: agent)?.installState() ?? .notInstalled }
            )
        }.value
        guard !Task.isCancelled, key == nudgeKey else { return }
        resolvedNudgeKey = key
        resolvedNudge = nudge
    }
}

private struct HookInstallNudgeKey: Hashable, Sendable {
    let detectedHarnesses: [HarnessKind]
    let dismissed: [String]
}
