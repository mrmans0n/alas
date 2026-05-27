import Foundation

protocol ACPAdapterInstaller {
    var agentID: String { get }
    func installState() async -> ACPSetupResult
    func install() async throws
}

enum ACPInstallError: LocalizedError {
    case nonZeroExit(Int32, stderr: String)
    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let stderr): return "install failed (exit \(code)): \(stderr)"
        }
    }
}

enum ACPInstallerRegistry {
    static func installer(for agentID: String) -> ACPAdapterInstaller? {
        switch agentID {
        case "claude": return ClaudeCodeACPInstaller()
        case "codex":  return CodexACPInstaller()
        case "pi":     return PiACPInstaller()
        default: return nil
        }
    }
}
