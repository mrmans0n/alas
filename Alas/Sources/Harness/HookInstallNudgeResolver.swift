import Foundation

struct HookInstallNudge: Equatable {
    let agent: AgentKind
    let installState: InstallState
    let title: String
    let actionTitle: String
}

enum HookInstallNudgeResolver {
    static func resolve(
        detectedHarnesses: [HarnessKind],
        dismissed: [String],
        installState: (AgentKind) -> InstallState,
        installerExists: (AgentKind) -> Bool = { AgentInstallerRegistry().installer(for: $0) != nil }
    ) -> HookInstallNudge? {
        for harness in detectedHarnesses {
            let agent = harness.asAgentKind
            guard installerExists(agent) else { continue }
            guard !dismissed.contains(agent.rawValue) else { continue }
            let state = installState(agent)
            switch state {
            case .notInstalled, .outdated:
                let actionTitle = state == .outdated ? "Update" : "Install"
                let title = "\(actionTitle) \(agent.displayName) hook for terminal status"
                return HookInstallNudge(agent: agent, installState: state, title: title, actionTitle: actionTitle)
            case .installed:
                continue
            }
        }
        return nil
    }
}
