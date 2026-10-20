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
