import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

public enum ACPInstallerRegistry: Sendable {
    public static func installer(for agentID: String) -> ACPAdapterInstaller? {
        switch agentID {
        case "claude": return ClaudeCodeACPInstaller()
        case "codex":  return CodexACPInstaller()
        case "pi":     return PiACPInstaller()
        default: return nil
        }
    }

    public static func install(agentID: String, mode: ACPAdapterInstallMode) async throws {
        guard let installer = installer(for: agentID) else {
            throw ACPInstallError.unsupportedAgent(agentID)
        }
        switch mode {
        case .update: try await installer.install()
        case .reinstall: try await installer.reinstall()
        }
    }
}
