import Foundation
import AlasPlatform
import AlasRemoteKit

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
        if let root = linuxInstallRoot(executablePath: executablePath) {
            return (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    // MARK: - Linux

    /// Where the Linux tarball was unpacked, when the host at `executablePath`
    /// came from one: `<root>/alas-host/alas-host` beside `<root>/VERSION`.
    public static func linuxInstallRoot(executablePath: String) -> URL? {
        let executable = URL(fileURLWithPath: executablePath)
        guard executable.lastPathComponent == "alas-host",
              executable.deletingLastPathComponent().lastPathComponent == "alas-host" else { return nil }
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("VERSION").path) ? root : nil
    }

    /// The latest release's tarball for this machine's architecture, among a
    /// GitHub release's `assets`.
    static func linuxAsset(in release: Data, architecture: String) -> URL? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let assets: [Asset]
        }
        let suffix = "-linux-\(architecture).tar.gz"
        return (try? JSONDecoder().decode(Release.self, from: release))?.assets
            .first { $0.name.hasPrefix("alas-host-") && $0.name.hasSuffix(suffix) }?.browser_download_url
    }

    /// Replaces the install at `root` with the latest release's, unless it is
    /// that release already: downloads its tarball, unpacks it beside `root`,
    /// and swaps the two folders. The running host sees its executable
    /// replaced and stops; its service starts the new one.
    public static func upgradeLinuxInstall(root: URL) async throws {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let architecture = machine == "arm64" ? "aarch64" : machine
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/latest")!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (release, releaseResponse) = try await boundedFetch(request, maxBytes: 4 << 20)
        guard releaseResponse.statusCode == 200, let asset = linuxAsset(in: release, architecture: architecture) else {
            throw HostError.failed(message: "The latest release has no alas-host for Linux \(architecture).")
        }
        let installed = (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let installed, asset.lastPathComponent == "alas-host-\(installed)-linux-\(architecture).tar.gz" { return }
        let (archive, archiveResponse) = try await boundedFetch(URLRequest(url: asset, timeoutInterval: 600), maxBytes: 512 << 20)
        guard archiveResponse.statusCode == 200 else {
            throw HostError.failed(message: "Couldn't download \(asset.lastPathComponent) (HTTP \(archiveResponse.statusCode)).")
        }
        let parent = root.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".alas-host-update-\(UUID().uuidString)")
        let previous = parent.appendingPathComponent(".alas-host-previous-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tarball = staging.appendingPathComponent("release.tar.gz")
        try archive.write(to: tarball)
        let unpacked = staging.appendingPathComponent("install")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
        let result = try await Process.run("/usr/bin/env", args: ["tar", "-xzf", tarball.path, "-C", unpacked.path], timeout: 300)
        guard result.exitCode == 0,
              FileManager.default.isExecutableFile(atPath: unpacked.appendingPathComponent("alas-host/alas-host").path) else {
            throw HostError.failed(message: "\(asset.lastPathComponent) isn't an alas-host release: " + String(result.stderr.suffix(300)))
        }
        try FileManager.default.moveItem(at: root, to: previous)
        do {
            try FileManager.default.moveItem(at: unpacked, to: root)
        } catch {
            try? FileManager.default.moveItem(at: previous, to: root)
            throw error
        }
        try? FileManager.default.removeItem(at: previous)
    }
}
