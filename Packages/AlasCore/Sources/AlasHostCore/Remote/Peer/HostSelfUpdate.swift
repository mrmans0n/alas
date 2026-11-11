import Foundation
import AlasPlatform

/// How a headless host installed from a Homebrew cask tells its version and
/// upgrades itself. Both read where the running executable lives: the
/// `alas-host` cask stages it in `Caskroom/alas-host/<version>/`, and the
/// `alas` cask ships it inside `/Applications/Alas.app`.
public enum HostSelfUpdate {
    static let appHostSuffix = "/Contents/Resources/alas-host/alas-host"

    /// The cask that ships the host at `executablePath` (symlinks resolved),
    /// or nil for a host copied into place or built locally.
    public static func cask(executablePath: String) -> String? {
        if executablePath.contains("/Caskroom/alas-host/") { return "alas-host" }
        if executablePath == "/Applications/Alas.app" + appHostSuffix { return "alas" }
        return nil
    }

    /// The release the host at `executablePath` (symlinks resolved) comes
    /// from: its Caskroom directory's name, or its app's version.
    public static func version(executablePath: String) -> String? {
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        if let index = parts.firstIndex(of: "Caskroom"), index + 2 < parts.count - 1 {
            return String(parts[index + 2])
        }
        guard executablePath.hasSuffix(".app" + appHostSuffix) else { return nil }
        let info = URL(fileURLWithPath: String(executablePath.dropLast(appHostSuffix.count)))
            .appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String)
    }

    /// Runs `brew upgrade --cask <cask>` with the login shell's environment.
    /// An upgrade that replaced the executable stops this host, which its
    /// launch agent then starts on the new version.
    public static func upgrade(cask: String) async throws {
        await ShellEnvResolver.shared.waitUntilResolved()
        var env = ShellEnvResolver.shared.resolvedEnvironment ?? ProcessInfo.processInfo.environment
        // Homebrew's own prefixes, should the shell's PATH lack them.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        // As the SSH setup: its cleanup would prune everything else on the Mac.
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        let result = try await Process.run(
            "/bin/sh", args: ["-c", "brew upgrade --cask \"$1\"", "sh", cask], env: env, timeout: 900
        )
        guard result.exitCode == 0 else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError.failed(message: "Homebrew couldn't upgrade \(cask): " + String(output.suffix(600)))
        }
    }
}
