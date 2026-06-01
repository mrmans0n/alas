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

enum ACPProcessEnvironment {
    // Strip env vars that mark this process as running inside another coding
    // agent. Claude-aware tools refuse to start when these leak through.
    static let agentSessionMarkerKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
    ]

    static func augmented(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalPathDirectories: [String] = AgentPath.wellKnownDirectories
    ) -> [String: String] {
        var env = environment
        env["PATH"] = AgentPath.augment(
            base: env["PATH"] ?? "",
            wellKnown: additionalPathDirectories)
        return env
    }

    static func sanitizedForACP(extra: [String: String]) -> [String: String] {
        var env = augmented()
        for key in agentSessionMarkerKeys {
            env.removeValue(forKey: key)
        }
        for (k, v) in extra { env[k] = v }
        return env
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
