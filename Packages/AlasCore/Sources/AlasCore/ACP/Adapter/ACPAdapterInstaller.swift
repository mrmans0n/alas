import Foundation

public protocol ACPAdapterInstaller {
    var agentID: String { get }
    func installState() async -> ACPSetupResult
    func install() async throws
}

public enum ACPInstallError: LocalizedError, Sendable {
    case unsupportedAgent(String)
    case nonZeroExit(Int32, stderr: String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedAgent(let agentID): return "No ACP adapter installer is available for \(agentID)."
        case .nonZeroExit(let code, let stderr): return "install failed (exit \(code)): \(stderr)"
        }
    }
}

public enum ACPProcessEnvironment: Sendable {
    // Strip env vars that mark this process as running inside another coding
    // agent. Claude-aware tools refuse to start when these leak through.
    public static let agentSessionMarkerKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
    ]

    public static func augmented(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalPathDirectories: [String] = AgentPath.wellKnownDirectories
    ) -> [String: String] {
        var env = environment
        env["PATH"] = AgentPath.augment(
            base: env["PATH"] ?? "",
            wellKnown: additionalPathDirectories)
        return env
    }

    public static func sanitizedForACP(extra: [String: String]) -> [String: String] {
        var env = augmented()
        for key in agentSessionMarkerKeys {
            env.removeValue(forKey: key)
        }
        for (k, v) in extra { env[k] = v }
        return env
    }

    public static func remoteOverridesForACP(extra: [String: String]) -> [String: String] {
        extra.filter { key, _ in
            !agentSessionMarkerKeys.contains(key)
        }
    }
}

public enum ACPInstallerRegistry: Sendable {
    public static func installer(for agentID: String) -> ACPAdapterInstaller? {
        switch agentID {
        case "claude": return ClaudeCodeACPInstaller()
        case "codex":  return CodexACPInstaller()
        case "pi":     return PiACPInstaller()
        default: return nil
        }
    }

    public static func install(agentID: String) async throws {
        guard let installer = installer(for: agentID) else {
            throw ACPInstallError.unsupportedAgent(agentID)
        }
        try await installer.install()
    }
}
