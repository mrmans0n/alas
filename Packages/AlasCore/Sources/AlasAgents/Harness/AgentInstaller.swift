import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public enum InstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}

public protocol AgentInstaller: Sendable {
    var agent: AgentKind { get }
    func installState() -> InstallState
    func install() async throws
    func uninstall() throws
}

extension Notification.Name {
    public static let agentHookInstallStateDidChange = Notification.Name("io.nlopez.alas.agentHookInstallStateDidChange")
}

public struct AgentInstallerRegistry: Sendable {
    public let installers: [any AgentInstaller]

    public init() {
        installers = [
            ClaudeInstaller(),
            CodexInstaller(),
            CursorInstaller(),
            GeminiInstaller(),
            OpenCodeInstaller(),
            PiInstaller(),
        ]
    }

    public init(installers: [any AgentInstaller]) {
        self.installers = installers
    }

    public var supportedAgents: [AgentKind] {
        installers.map(\.agent)
    }

    public func installer(for agent: AgentKind) -> (any AgentInstaller)? {
        installers.first { $0.agent == agent }
    }
}
