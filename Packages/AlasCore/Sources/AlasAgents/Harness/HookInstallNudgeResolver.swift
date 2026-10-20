import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct HookInstallNudge: Equatable, Sendable {
    public let agent: AgentKind
    public let installState: InstallState
    public let title: String
    public let actionTitle: String

    public init(agent: AgentKind, installState: InstallState, title: String, actionTitle: String) {
        self.agent = agent
        self.installState = installState
        self.title = title
        self.actionTitle = actionTitle
    }
}

public enum HookInstallNudgeResolver: Sendable {
    public static func resolve(
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
