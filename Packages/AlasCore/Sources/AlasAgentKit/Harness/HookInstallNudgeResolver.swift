import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

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
    /// The distinct agents running in local panes, in pane order. The installers
    /// write to this machine, so an agent in an SSH pane can't ask for one.
    public static func localDetectedHarnesses(
        sessionIDs: [String],
        harnessBySession: [String: HarnessKind],
        isLocal: (String) -> Bool
    ) -> [HarnessKind] {
        var seen = Set<HarnessKind>()
        return sessionIDs
            .filter(isLocal)
            .compactMap { harnessBySession[$0] }
            .filter { seen.insert($0).inserted }
    }

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
