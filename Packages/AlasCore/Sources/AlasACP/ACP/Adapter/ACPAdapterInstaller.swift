import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public protocol ACPAdapterInstaller {
    var agentID: String { get }
    func installState() async -> ACPSetupResult
    /// Installs over the existing package, so a failed update leaves the
    /// working adapter in place.
    func install() async throws
    /// Uninstalls the package first so npm fetches every dependency again,
    /// then installs. For adapters that are missing or already broken.
    func reinstall() async throws
}

public enum ACPAdapterInstallMode: Sendable {
    /// Install over the existing adapter (the update banner).
    case update
    /// Remove the adapter first (install, repair, Reinstall).
    case reinstall
}

public enum ACPInstallError: LocalizedError, Sendable {
    case unsupportedAgent(String)
    case nonZeroExit(Int32, stderr: String)
    /// npm exited 0, but the setup check still fails.
    case unusableAfterInstall(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedAgent(let agentID): return "No ACP adapter installer is available for \(agentID)."
        case .nonZeroExit(let code, let stderr): return "install failed (exit \(code)): \(stderr)"
        case .unusableAfterInstall(let reason): return "npm finished, but the adapter is still unusable: \(reason)"
        }
    }

    /// Throws unless `state` is ready. Installers call it after npm succeeds,
    /// because npm exits 0 even when it skipped an optional platform package.
    public static func requireReady(_ state: ACPSetupResult) throws {
        switch state {
        case .ready: return
        case .missing(let reason): throw unusableAfterInstall(reason)
        case .error(let message): throw unusableAfterInstall(message)
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
