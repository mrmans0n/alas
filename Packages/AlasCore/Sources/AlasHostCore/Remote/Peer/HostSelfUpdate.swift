import Foundation
import AlasModel
import AlasPlatform
import AlasRemoteKit

/// How a headless host installed from a Homebrew cask tells its version and
/// upgrades itself. Both read where the running executable lives: the
/// `alas-host` cask stages it in `Caskroom/alas-host/<version>/`, and the
/// `alas` cask ships it inside `/Applications/Alas.app`.
public enum HostSelfUpdate {
    static let appHostSuffix = "/Contents/Resources/alas-host/alas-host"

    /// Coordinates file-watch notifications with an install that replaces
    /// the running executable before all of its files are ready.
    @MainActor
    public final class Lifecycle {
        private var isInstalling = false
        private let wasReplaced: () -> Bool
        private let restart: () async throws -> Void
        private let stop: () -> Void

        public init(
            wasReplaced: @escaping () -> Bool,
            restart: @escaping () async throws -> Void,
            stop: @escaping () -> Void
        ) {
            self.wasReplaced = wasReplaced
            self.restart = restart
            self.stop = stop
        }

        public func executableChanged() {
            if !isInstalling, wasReplaced() { stop() }
        }

        public func install(_ operation: () async throws -> Void) async throws {
            guard !isInstalling else {
                throw HostError.failed(message: "A host update is already in progress.")
            }
            isInstalling = true
            defer { isInstalling = false }
            try await operation()
            if wasReplaced() {
                try await restart()
                stop()
            }
        }
    }

    /// Clear only this release's download prompt, after verifying every
    /// executable against the release publisher. The full app is untouched.
    static let prepareStandaloneInstallScript = """
    executable=$1
    verify=${2:-/usr/bin/codesign}
    clear=${3:-/usr/bin/xattr}
    while [ -L "$executable" ]; do
        target=$(/usr/bin/readlink "$executable") || exit $?
        case "$target" in
            /*) executable=$target ;;
            *) executable="$(dirname "$executable")/$target" ;;
        esac
    done
    executable="$(cd "$(dirname "$executable")" && pwd -P)/$(basename "$executable")"
    case "$executable" in
        */Caskroom/alas-host/*/alas-host/alas-host) ;;
        *) echo "Refusing to change quarantine outside the alas-host cask." >&2; exit 1 ;;
    esac
    root=${executable%/alas-host/alas-host}
    for binary in "$executable" "$root/zmx/zmx" "$root/alas-cli/alas"; do
        "$verify" --verify --strict --all-architectures -R \\
            '=anchor apple generic and certificate leaf[subject.OU] = "57WT3F3FAM"' "$binary" || exit $?
    done
    "$clear" -dr com.apple.quarantine "$root"
    """

    #if os(macOS)
    /// Runs outside the host's launchd job, so stopping the host cannot kill
    /// its restart request. PathState can miss Homebrew replacing its symlink.
    public static func restartAfterExit(executable: URL) async throws {
        let agent = HostLaunchAgent(executable: executable)
        let service = "gui/\(getuid())/\(agent.label)"
        let helper = agent.label + ".update." + UUID().uuidString
        let result = try await Process.run(
            "/bin/launchctl",
            args: [
                "submit", "-l", helper, "-o", agent.logURL.path, "-e", agent.logURL.path,
                "--", "/bin/sh", "-c", restartScript, "sh",
                String(getpid()), service, helper, "/bin/launchctl",
            ],
            timeout: 10
        )
        guard result.exitCode == 0 else {
            throw HostError.failed(message: "Couldn't schedule the host restart: " + String(result.stderr.suffix(600)))
        }
    }

    static let restartScript = """
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    "$4" kickstart "$2"
    status=$?
    "$4" remove "$3"
    exit "$status"
    """
    #endif

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

    /// Runs Homebrew with the login shell's environment. The caller must
    /// defer file-watch shutdown until this finishes, then arrange a restart.
    public static func upgrade(cask: String, executable: URL) async throws {
        await ShellEnvResolver.shared.waitUntilResolved()
        var env = ShellEnvResolver.shared.resolvedEnvironment ?? ProcessInfo.processInfo.environment
        // Homebrew's own prefixes, should the shell's PATH lack them.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        // As the SSH setup: its cleanup would prune everything else on the Mac.
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ASK"] = "1"
        let result = try await Process.run(
            "/bin/sh", args: ["-c", "exec brew upgrade --cask \"$1\"", "sh", cask], env: env, timeout: 900
        )
        guard result.exitCode == 0 else {
            let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostError.failed(message: "Homebrew couldn't upgrade \(cask): " + String(output.suffix(600)))
        }
        if cask == "alas-host" {
            let prepared = try await Process.run(
                "/bin/sh", args: ["-c", prepareStandaloneInstallScript, "sh", executable.path], timeout: 30
            )
            guard prepared.exitCode == 0 else {
                throw HostError.failed(message: "Couldn't authorize the installed host: " + String(prepared.stderr.suffix(600)))
            }
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
