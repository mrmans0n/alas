import Foundation

enum InstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}

protocol AgentInstaller: Sendable {
    var agent: AgentKind { get }
    func installState() -> InstallState
    func install() async throws
    func uninstall() throws
}

extension Notification.Name {
    static let agentHookInstallStateDidChange = Notification.Name("io.nlopez.alas.agentHookInstallStateDidChange")
}

struct AgentInstallerRegistry: Sendable {
    let installers: [any AgentInstaller]

    init() {
        installers = [
            ClaudeInstaller(),
            CodexInstaller(),
            CursorInstaller(),
            GeminiInstaller(),
            OpenCodeInstaller(),
            PiInstaller(),
        ]
    }

    init(installers: [any AgentInstaller]) {
        self.installers = installers
    }

    var supportedAgents: [AgentKind] {
        installers.map(\.agent)
    }

    func installer(for agent: AgentKind) -> (any AgentInstaller)? {
        installers.first { $0.agent == agent }
    }
}
