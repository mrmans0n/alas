import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

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
