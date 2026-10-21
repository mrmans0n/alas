import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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

    /// `environment` with the login shell's PATH ahead of its own. A process
    /// started by launchd (the app, or `alas-host` as a launch agent) inherits
    /// launchd's minimal PATH, while adapters installed through nvm, fnm, asdf
    /// or mise, and the `node` they run on, are only on the login shell's.
    /// `shellPath` is `ShellEnvResolver`'s, nil until it has resolved.
    public static func baseEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = ShellEnvResolver.shared.resolvedPath
    ) -> [String: String] {
        guard let shellPath, !shellPath.isEmpty else { return environment }
        var env = environment
        let shellEntries = shellPath.split(separator: ":").map(String.init)
        let rest = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { !shellEntries.contains($0) }
        env["PATH"] = (shellEntries + rest).joined(separator: ":")
        return env
    }

    public static func augmented(
        _ environment: [String: String] = baseEnvironment(),
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
