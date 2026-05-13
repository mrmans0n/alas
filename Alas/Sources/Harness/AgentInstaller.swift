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

struct AgentInstallerRegistry: Sendable {
    let installers: [any AgentInstaller]

    init() {
        // Concrete installers added in Tasks 5 and 6.
        installers = []
    }

    init(installers: [any AgentInstaller]) {
        self.installers = installers
    }

    func installer(for agent: AgentKind) -> (any AgentInstaller)? {
        installers.first { $0.agent == agent }
    }
}
